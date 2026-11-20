import AppKit
import AVFoundation
import Combine
import ImageIO
import UniformTypeIdentifiers

/// Owns the library UI independently of desktop playback. Opening an installer
/// is a handoff to macOS, not confirmation of successful installation.
@MainActor
final class ScreenSaverController: ObservableObject {
    @Published private(set) var entries: [ScreenSaverLibraryEntry] = []
    @Published private(set) var selectedEntryID: UUID?
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    @Published private(set) var libraryWarnings: [ScreenSaverLibraryError] = []
    @Published private(set) var hasLoadedLibrary = false
    @Published private(set) var installationRequestedName: String?
    @Published private(set) var lastCreatedID: UUID?
    @Published private(set) var selectedURL: URL?
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var isPreparing = false
    @Published private(set) var isWorking = false
    @Published private(set) var isSaving = false
    @Published private(set) var isCreating = false
    @Published private(set) var failure: ScreenSaverExportError?
    @Published var name = ""
    @Published var scaling: VideoScaling = .fill
    @Published var animateOnBattery = false
    @Published var animateOnExternalPower = true
    @Published var pauseInLowPowerMode = true

    private var posterJPEG: Data?
    private var preparation: Task<Void, Never>?
    private var generation = UUID()
    private let templateURL: URL?
    private let library: ScreenSaverLibrary
    private let openInstaller: @MainActor (URL) -> Bool
    private let installerSigner: ScreenSaverExporter.Signer

    var isBusy: Bool { isPreparing || isWorking }
    var canSave: Bool {
        selectedURL != nil && posterJPEG != nil && templateURL != nil && !isBusy
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var hasTemplate: Bool { templateURL != nil }

    init(templateURL: URL? = Bundle.main.builtInPlugInsURL?.appendingPathComponent("MyWallpaper.saver"),
         library: ScreenSaverLibrary = .init(),
         installerSigner: @escaping ScreenSaverExporter.Signer = ScreenSaverExporter.signAndVerify,
         openInstaller: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        if let templateURL, FileManager.default.fileExists(atPath: templateURL.appendingPathComponent("Contents/Info.plist").path) {
            self.templateURL = templateURL
        } else {
            self.templateURL = nil
        }
        self.library = library
        self.openInstaller = openInstaller
        self.installerSigner = installerSigner
    }

    func reloadLibrary() async {
        guard !isWorking else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false; hasLoadedLibrary = true }
        do {
            let library = self.library
            let snapshot = try await Task.detached(priority: .userInitiated) {
                let listing = try library.list()
                var previews: [UUID: Data] = [:]
                for entry in listing.entries {
                    if let url = try? library.thumbnailURL(for: entry.id),
                       let data = Self.smallPreview(at: url) { previews[entry.id] = data }
                }
                return LibrarySnapshot(listing: listing, previews: previews)
            }.value
            entries = snapshot.listing.entries
            libraryWarnings = snapshot.listing.warnings
            thumbnails = snapshot.previews.compactMapValues { NSImage(data: $0) }
            if !entries.contains(where: { $0.id == selectedEntryID }) { selectedEntryID = entries.first?.id }
        } catch { present(error, fallback: "Не удалось загрузить библиотеку заставок.") }
    }

    func selectEntry(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        selectedEntryID = id
    }

    func resetDraft() {
        guard !isWorking else { return }
        preparation?.cancel()
        preparation = nil
        generation = UUID()
        isPreparing = false
        isCreating = false
        selectedURL = nil
        thumbnail = nil
        posterJPEG = nil
        name = ""
        scaling = .fill
        animateOnBattery = false
        animateOnExternalPower = true
        pauseInLowPowerMode = true
        failure = nil
    }

    func beginCreating() {
        guard !isBusy else { return }
        resetDraft()
        isCreating = true
    }

    func chooseVideo(localizer: AppLocalizer) {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.title = localizer.text("Видео для заставки")
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { selectVideo(url) }
    }

    func selectVideo(_ url: URL) {
        guard !isWorking else { return }
        isCreating = true
        preparation?.cancel()
        generation = UUID()
        let currentGeneration = generation
        let oldDefaultName = selectedURL?.deletingPathExtension().lastPathComponent
        failure = nil
        isPreparing = true
        preparation = Task { [weak self] in
            let acquired = url.startAccessingSecurityScopedResource()
            defer { if acquired { url.stopAccessingSecurityScopedResource() } }
            do {
                guard url.isFileURL, ["mp4", "mov"].contains(url.pathExtension.lowercased()) else {
                    throw ScreenSaverExportError(ruKey: "Для заставки выбери видео MP4 или MOV.")
                }
                let asset = AVURLAsset(url: url)
                async let playable = asset.load(.isPlayable)
                async let tracks = asset.loadTracks(withMediaType: .video)
                async let duration = asset.load(.duration)
                let (isPlayable, videoTracks, length) = try await (playable, tracks, duration)
                guard isPlayable, !videoTracks.isEmpty, length.isNumeric,
                      length.seconds.isFinite, length.seconds > 0 else {
                    throw ScreenSaverExportError(ruKey: "Это видео нельзя использовать как заставку.")
                }
                try Task.checkCancellation()
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 3840, height: 2160)
                let image = try await generator.image(at: .zero).image
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                    throw ScreenSaverExportError(ruKey: "Не удалось подготовить кадр заставки.")
                }
                try Task.checkCancellation()
                guard let self, self.generation == currentGeneration else { return }
                if self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.name == oldDefaultName {
                    self.name = String(url.deletingPathExtension().lastPathComponent.prefix(80))
                }
                self.selectedURL = url
                self.thumbnail = NSImage(cgImage: image, size: .zero)
                self.posterJPEG = data
                self.isPreparing = false
                self.preparation = nil
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.isPreparing = false
                self.preparation = nil
                if !(error is CancellationError) { self.present(error, fallback: "Не удалось открыть видео для заставки.") }
            }
        }
    }

    func saveToLibrary() async {
        guard canSave, let selectedURL, let posterJPEG, let templateURL else { return }
        isWorking = true
        isSaving = true
        failure = nil
        let acquired = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if acquired { selectedURL.stopAccessingSecurityScopedResource() }
            isSaving = false
            isWorking = false
        }
        let options = ScreenSaverExportOptions(scaling: scaling == .fill ? .fill : .fit,
                                              animateOnBattery: animateOnBattery,
                                              animateOnExternalPower: animateOnExternalPower,
                                              pauseInLowPowerMode: pauseInLowPowerMode)
        let library = self.library
        let name = self.name
        do {
            let (entry, preview) = try await Task.detached(priority: .userInitiated) {
                let entry = try library.create(videoURL: selectedURL, posterJPEG: posterJPEG, templateURL: templateURL,
                                               name: name, options: options)
                let preview = try? library.thumbnailURL(for: entry.id)
                return (entry, preview.flatMap { Self.smallPreview(at: $0) })
            }.value
            entries.insert(entry, at: 0)
            if let preview { thumbnails[entry.id] = NSImage(data: preview) }
            selectedEntryID = entry.id
            lastCreatedID = entry.id
            isCreating = false
            hasLoadedLibrary = true
        } catch { present(error, fallback: "Не удалось сохранить заставку в библиотеку.") }
    }

    func rename(id: UUID, name: String) async {
        guard !isBusy else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        let library = self.library
        do {
            let changed = try await Task.detached(priority: .userInitiated) { try library.rename(id: id, name: name) }.value
            if let index = entries.firstIndex(where: { $0.id == id }) { entries[index] = changed }
        } catch { present(error, fallback: "Не удалось переименовать заставку.") }
    }

    func delete(id: UUID) async {
        guard !isBusy else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        let library = self.library
        do {
            try await Task.detached(priority: .userInitiated) { try library.delete(id: id) }.value
            entries.removeAll { $0.id == id }
            thumbnails[id] = nil
            if selectedEntryID == id { selectedEntryID = entries.first?.id }
            if lastCreatedID == id { lastCreatedID = nil }
            installationRequestedName = nil
        } catch { present(error, fallback: "Не удалось удалить заставку из библиотеки.") }
    }

    func install(id: UUID) async {
        guard !isBusy, let entry = entries.first(where: { $0.id == id }) else { return }
        isWorking = true
        failure = nil
        installationRequestedName = nil
        defer { isWorking = false }
        let library = self.library
        let templateURL = self.templateURL
        let signer = installerSigner
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try library.prepareInstallation(id: id, templateURL: templateURL, signer: signer)
            }.value
            guard openInstaller(url) else {
                throw ScreenSaverExportError(ruKey: "Не удалось открыть установку заставки. Попробуй ещё раз.")
            }
            selectedEntryID = id
            installationRequestedName = entry.name
        } catch { present(error, fallback: "Не удалось открыть установку заставки. Попробуй ещё раз.") }
    }

    func dismissFailure() { failure = nil }

    func openSystemSettings() {
        let pane = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            ? "com.apple.Wallpaper-Settings.extension" : "com.apple.ScreenSaver-Settings.extension"
        guard let url = URL(string: "x-apple.systempreferences:\(pane)"), NSWorkspace.shared.open(url) else {
            failure = ScreenSaverExportError(ruKey: "Не удалось открыть настройки заставки.")
            return
        }
    }

    private func present(_ error: Error, fallback: String) {
        if let error = error as? ScreenSaverExportError { failure = error }
        else if let error = error as? ScreenSaverLibraryError {
            failure = ScreenSaverExportError(ruKey: error.ruKey, detail: error.detail)
        } else { failure = ScreenSaverExportError(ruKey: fallback, detail: error.localizedDescription) }
    }

    private nonisolated static func smallPreview(at url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

private struct LibrarySnapshot: Sendable {
    let listing: ScreenSaverLibraryListing
    let previews: [UUID: Data]
}
