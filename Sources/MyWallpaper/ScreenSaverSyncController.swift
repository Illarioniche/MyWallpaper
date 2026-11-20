import AppKit
import AVFoundation
import Combine

/// Publishes media for a separately installed saver. It never changes the
/// system's selected saver or modifies an installed, signed bundle.
@MainActor
final class ScreenSaverSyncController: ObservableObject {
    @Published private(set) var snapshot: ScreenSaverSyncSnapshot?
    @Published private(set) var isWorking = false
    @Published private(set) var isSynchronizing = false
    @Published private(set) var isInstalling = false
    @Published private(set) var installationRequested = false
    @Published private(set) var installedBundleURL: URL?
    @Published private(set) var failure: ScreenSaverSyncError?

    typealias VideoPreparer = @Sendable (URL) async throws -> Data
    typealias InstallationLookup = @Sendable (URL) -> URL?
    private let worker: ScreenSaverSyncWorker
    private let prepareVideo: VideoPreparer
    private let templateURL: URL?
    private let openInstaller: @MainActor (URL) -> Bool
    private var synchronizationTask: Task<Void, Never>?
    private var installationMonitorTask: Task<Void, Never>?
    private var isCheckingInstallation = false
    private var requestID = UUID()
    private var activeOperations = 0
    var hasTemplate: Bool { templateURL != nil }
    var isInstalled: Bool { installedBundleURL != nil }

    init(store: ScreenSaverSyncStore = .init(),
         templateURL: URL? = Bundle.main.builtInPlugInsURL?.appendingPathComponent("MyWallpaper.saver"),
         signer: @escaping ScreenSaverExporter.Signer = ScreenSaverExporter.signAndVerify,
         prepareVideo: VideoPreparer? = nil,
         installationLookup: @escaping InstallationLookup = {
             ScreenSaverSyncInstallation().installedBundleURL(syncRootURL: $0)
         },
         openInstaller: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        worker = ScreenSaverSyncWorker(store: store, signer: signer, installationLookup: installationLookup)
        self.prepareVideo = prepareVideo ?? Self.prepare
        if let templateURL, FileManager.default.fileExists(atPath: templateURL.appendingPathComponent("Contents/Info.plist").path) {
            self.templateURL = templateURL
        } else { self.templateURL = nil }
        self.openInstaller = openInstaller
    }

    deinit { installationMonitorTask?.cancel() }

    func reload() async {
        beginOperation()
        defer { endOperation() }
        do { snapshot = try await worker.snapshot() }
        catch { present(error) }
        await refreshInstallation()
    }

    /// Opening the installer is only a handoff. Check the actual installed
    /// bundle again on return to the app, including after an external deletion.
    func refreshInstallation() async {
        guard !isCheckingInstallation else { return }
        isCheckingInstallation = true
        defer { isCheckingInstallation = false }
        installedBundleURL = await worker.installedBundleURL()
        if isInstalled { installationRequested = false }
    }

    func synchronize(videoURL: URL, name: String, options: ScreenSaverExportOptions) {
        cancelSynchronization()
        let id = requestID
        let prepare = prepareVideo
        let worker = worker
        failure = nil
        isSynchronizing = true
        beginOperation()
        synchronizationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.endOperation()
                if self.requestID == id {
                    self.isSynchronizing = false
                    self.synchronizationTask = nil
                }
            }
            let scope = videoURL.startAccessingSecurityScopedResource()
            defer { if scope { videoURL.stopAccessingSecurityScopedResource() } }
            do {
                let preparation = Task.detached(priority: .utility) { try await prepare(videoURL) }
                let poster = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: { preparation.cancel() }
                try Task.checkCancellation()
                let updated = try await worker.publish(videoURL: videoURL, posterJPEG: poster,
                                                       options: options, name: name)
                guard !Task.isCancelled, self.requestID == id else { return }
                self.snapshot = updated
            } catch is CancellationError {
                // The latest request owns the UI; the store preserves a complete snapshot.
            } catch {
                guard !Task.isCancelled, self.requestID == id else { return }
                self.present(error)
            }
        }
    }

    func cancelSynchronization() {
        requestID = UUID()
        synchronizationTask?.cancel()
        synchronizationTask = nil
        isSynchronizing = false
    }

    func waitForSynchronization() async { await synchronizationTask?.value }

    func install() async {
        guard !isInstalling, let templateURL else { return }
        isInstalling = true
        installationRequested = false
        beginOperation()
        defer { isInstalling = false; endOperation() }
        await waitForSynchronization()
        guard failure == nil, !Task.isCancelled else { return }
        do {
            let installer = try await worker.prepareInstaller(templateURL: templateURL)
            guard !Task.isCancelled else { return }
            guard openInstaller(installer) else {
                throw ScreenSaverSyncError(ruKey: "Не удалось открыть установку связанной заставки.")
            }
            installationRequested = true
            await refreshInstallation()
            if !isInstalled { monitorInstallation() }
        } catch { present(error) }
    }

    func dismissFailure() { failure = nil }

    private func monitorInstallation() {
        installationMonitorTask?.cancel()
        // Observe the system handoff briefly even when our window is inactive.
        // Later changes are checked on activation; no permanent polling timer.
        installationMonitorTask = Task { [weak self] in
            for _ in 0..<120 {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.refreshInstallation()
                if self.isInstalled { return }
            }
        }
    }

    private func beginOperation() { activeOperations += 1; isWorking = true }
    private func endOperation() { activeOperations -= 1; isWorking = activeOperations > 0 }

    private func present(_ error: Error) {
        if error is CancellationError { return }
        if let error = error as? ScreenSaverSyncError { failure = error }
        else if let error = error as? ScreenSaverExportError {
            failure = ScreenSaverSyncError(ruKey: error.ruKey, detail: error.detail)
        } else {
            failure = ScreenSaverSyncError(ruKey: "Не удалось синхронизировать заставку с обоями.", detail: error.localizedDescription)
        }
    }

    private nonisolated static func prepare(_ url: URL) async throws -> Data {
        guard url.isFileURL, ["mp4", "mov"].contains(url.pathExtension.lowercased()) else {
            throw ScreenSaverSyncError(ruKey: "Для синхронизации заставки выбери обои в формате MP4 или MOV.")
        }
        let asset = AVURLAsset(url: url)
        async let playable = asset.load(.isPlayable)
        async let tracks = asset.loadTracks(withMediaType: .video)
        async let duration = asset.load(.duration)
        let (canPlay, videoTracks, length) = try await (playable, tracks, duration)
        guard canPlay, !videoTracks.isEmpty, length.isNumeric, length.seconds.isFinite, length.seconds > 0 else {
            throw ScreenSaverSyncError(ruKey: "Это видео нельзя использовать как заставку.")
        }
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 3840, height: 2160)
        let image = try await generator.image(at: .zero).image
        try Task.checkCancellation()
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw ScreenSaverSyncError(ruKey: "Не удалось подготовить кадр заставки.")
        }
        return data
    }
}

/// Synchronous filesystem work is serialized off the main actor, including
/// cancelled requests that may still be finishing a copy or atomic rename.
private actor ScreenSaverSyncWorker {
    let store: ScreenSaverSyncStore
    let signer: ScreenSaverExporter.Signer
    let installationLookup: ScreenSaverSyncController.InstallationLookup
    init(store: ScreenSaverSyncStore, signer: @escaping ScreenSaverExporter.Signer,
         installationLookup: @escaping ScreenSaverSyncController.InstallationLookup) {
        self.store = store; self.signer = signer; self.installationLookup = installationLookup
    }
    func installedBundleURL() -> URL? { installationLookup(store.rootURL) }
    func snapshot() throws -> ScreenSaverSyncSnapshot? { try store.snapshot() }
    func publish(videoURL: URL, posterJPEG: Data, options: ScreenSaverExportOptions,
                 name: String) throws -> ScreenSaverSyncSnapshot {
        try store.publish(videoURL: videoURL, posterJPEG: posterJPEG, options: options, name: name)
    }
    func prepareInstaller(templateURL: URL) throws -> URL {
        try store.prepareInstaller(templateURL: templateURL, signer: signer)
    }
}
