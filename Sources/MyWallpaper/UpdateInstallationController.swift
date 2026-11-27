import Combine
import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

struct UpdateInstallTarget: Equatable, Sendable {
    let version: String
    let build: String
}

struct UpdateInstallFailure: Error, Equatable {
    let message: String
    var detail: String? = nil
}

enum UpdateInstallationState: Equatable {
    case idle
    case checking
    case downloading(received: UInt64, total: UInt64?)
    case extracting(Double?)
    case waitingForApplication
    case restarting
    case cancelled
    case failed(UpdateInstallFailure)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .extracting, .waitingForApplication, .restarting: true
        case .idle, .cancelled, .failed: false
        }
    }

    /// A staged installer can install on quit. Wait until its relaunch receipt
    /// is ready before allowing an unrelated menu Quit to terminate the process.
    var requiresPreparationBeforeQuit: Bool {
        switch self {
        case .extracting, .waitingForApplication: true
        default: false
        }
    }
}

@MainActor
protocol UpdateInstallationService: AnyObject {
    func start() throws
}

/// GitHub discovers releases; Sparkle verifies and installs only after explicit consent.
/// The transport is injectable so lifecycle and consent can be tested without replacing an app.
@MainActor
final class UpdateInstallationController: ObservableObject {
    typealias ServiceFactory = @MainActor (UpdateInstallationController, UUID) throws -> any UpdateInstallationService

    @Published private(set) var state: UpdateInstallationState = .idle
    @Published private(set) var canCancel = false
    @Published private(set) var canRetryRestart = false
    var prepareForRelaunch: (@MainActor (UpdateInstallTarget) async throws -> Void)?
    var installationDidAbort: (@MainActor () -> Void)?
    var openUpdates: (@MainActor () -> Void)?

    var isBusy: Bool { state.isBusy }
    var canInstall: Bool { serviceFactory != nil || Self.isConfiguredBundle }
    private(set) var activeSessionID: UUID?
    private let currentBuild: String
    private let serviceFactory: ServiceFactory?
    private var service: (any UpdateInstallationService)?
    private var requestedRelease: UpdateRelease?
    private var target: UpdateInstallTarget?
    private var cancellation: (() -> Void)?
    private var retryTermination: (() -> Void)?
    private var preparationTask: Task<Void, Never>?

    init(currentBuild: String? = nil, serviceFactory: ServiceFactory? = nil) {
        self.currentBuild = currentBuild ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        self.serviceFactory = serviceFactory
    }

    func start(release: UpdateRelease, currentVersion: String) {
        guard !isBusy else { openUpdates?(); return }
        guard let installed = UpdateVersion(currentVersion), let proposed = UpdateVersion(release.version), proposed > installed else {
            state = .failed(UpdateInstallFailure(message: "Проверь обновления ещё раз: эта версия уже установлена или устарела."))
            return
        }
        guard release.downloadURL != nil else {
            state = .failed(UpdateInstallFailure(message: "DMG пока не прикреплён. Открой страницу релиза, чтобы посмотреть доступные файлы."))
            return
        }
        guard canInstall else {
            state = .failed(UpdateInstallFailure(message: "Обновление внутри приложения доступно в собранном MyWallpaper.app. Можно установить DMG вручную."))
            return
        }
        guard prepareForRelaunch != nil else {
            state = .failed(UpdateInstallFailure(message: "Не удалось подготовить безопасный перезапуск. Перезапусти приложение и попробуй ещё раз."))
            return
        }
        let id = UUID()
        activeSessionID = id
        requestedRelease = release
        target = nil
        cancellation = nil
        retryTermination = nil
        canCancel = false
        canRetryRestart = false
        state = .checking
        do {
            if let serviceFactory {
                service = try serviceFactory(self, id)
            } else {
                #if canImport(Sparkle)
                service = SparkleInstallationDriver(owner: self, sessionID: id)
                #endif
            }
            try service?.start()
        } catch { fail(error, sessionID: id) }
    }

    func cancel() {
        guard canCancel, let cancellation else { return }
        self.cancellation = nil
        canCancel = false
        preparationTask?.cancel()
        preparationTask = nil
        state = .cancelled
        installationDidAbort?()
        cancellation()
    }

    func retryRestart() {
        guard state == .restarting, canRetryRestart else { return }
        retryTermination?()
    }

    func accepts(_ id: UUID) -> Bool {
        activeSessionID == id && state.isBusy
    }

    func checking(cancellation: @escaping () -> Void, sessionID: UUID) {
        guard accepts(sessionID) else { cancellation(); return }
        setCancellation(cancellation)
    }

    func validate(_ proposed: UpdateInstallTarget, downloadURL: URL?, informationOnly: Bool, sessionID: UUID) throws {
        guard accepts(sessionID), let requestedRelease,
              !informationOnly,
              UpdateVersion(proposed.version) == UpdateVersion(requestedRelease.version),
              let build = UInt64(proposed.build), String(build) == proposed.build,
              let installedBuild = UInt64(currentBuild), build > installedBuild,
              let expectedURL = requestedRelease.downloadURL, downloadURL == expectedURL else {
            throw UpdateInstallFailure(message: "Релиз и файл обновления не совпали. Проверь обновления ещё раз или скачай DMG со страницы релиза.")
        }
        target = proposed
    }

    func downloading(cancellation: @escaping () -> Void, sessionID: UUID) {
        guard accepts(sessionID) else { cancellation(); return }
        state = .downloading(received: 0, total: nil)
        setCancellation(cancellation)
    }

    func receivedExpectedLength(_ total: UInt64, sessionID: UUID) {
        guard accepts(sessionID), case .downloading(let received, _) = state else { return }
        state = .downloading(received: received, total: total > 0 ? total : nil)
    }

    func receivedData(_ length: UInt64, sessionID: UUID) {
        guard accepts(sessionID), case .downloading(let received, let total) = state else { return }
        let (sum, overflow) = received.addingReportingOverflow(length)
        state = .downloading(received: overflow ? .max : sum, total: total)
    }

    func extracting(progress: Double? = nil, sessionID: UUID) {
        guard accepts(sessionID) else { return }
        setCancellation(nil)
        let finiteProgress = progress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        state = .extracting(finiteProgress)
    }

    func readyToInstall(sessionID: UUID, reply: @escaping (Bool) -> Void) {
        guard accepts(sessionID), let target, let prepareForRelaunch else { reply(false); return }
        state = .waitingForApplication
        setCancellation { reply(false) }
        preparationTask = Task { [weak self] in
            do {
                try await prepareForRelaunch(target)
                try Task.checkCancellation()
                guard let self, self.accepts(sessionID) else { return }
                self.setCancellation(nil)
                self.state = .restarting
                self.preparationTask = nil
                reply(true)
            } catch {
                guard let self, self.accepts(sessionID) else { return }
                self.fail(error, sessionID: sessionID)
                reply(false)
            }
        }
    }

    func installing(applicationTerminated: Bool, retry: @escaping () -> Void, sessionID: UUID) {
        guard accepts(sessionID) else { return }
        setCancellation(nil)
        state = .restarting
        retryTermination = applicationTerminated ? nil : retry
        canRetryRestart = !applicationTerminated
    }

    func fail(_ error: Error, sessionID: UUID) {
        guard accepts(sessionID) else { return }
        preparationTask?.cancel()
        preparationTask = nil
        setCancellation(nil)
        retryTermination = nil
        canRetryRestart = false
        let failure = error as? UpdateInstallFailure ?? UpdateInstallFailure(
            message: "Не удалось установить обновление. Текущая версия продолжает работать.",
            detail: error.localizedDescription)
        state = .failed(failure)
        installationDidAbort?()
    }

    func dismissed(sessionID: UUID) {
        guard accepts(sessionID), state != .restarting else { return }
        setCancellation(nil)
        state = .idle
        installationDidAbort?()
    }

    private func setCancellation(_ callback: (() -> Void)?) {
        cancellation = callback
        canCancel = callback != nil
    }

    private static var isConfiguredBundle: Bool {
        #if canImport(Sparkle)
        guard Bundle.main.bundleURL.pathExtension == "app",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https" else { return false }
        return true
        #else
        return false
        #endif
    }
}

#if canImport(Sparkle)
@MainActor
private final class SparkleInstallationDriver: NSObject, UpdateInstallationService, SPUUserDriver, SPUUpdaterDelegate {
    private weak var owner: UpdateInstallationController?
    private let sessionID: UUID
    private var updater: SPUUpdater?

    init(owner: UpdateInstallationController, sessionID: UUID) {
        self.owner = owner
        self.sessionID = sessionID
    }

    func start() throws {
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        self.updater = updater
        // Discovery is already scheduled by UpdateController. Installation always needs consent.
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        do { try updater.start() }
        catch {
            self.updater = nil
            throw error
        }
        updater.checkForUpdates()
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        owner?.checking(cancellation: cancellation, sessionID: sessionID)
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let owner else { throw CancellationError() }
        try owner.validate(UpdateInstallTarget(version: item.displayVersionString, build: item.versionString),
                           downloadURL: item.fileURL, informationOnly: item.isInformationOnlyUpdate, sessionID: sessionID)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let owner, owner.accepts(sessionID) else {
            reply(state.stage == .installing ? .skip : .dismiss)
            return
        }
        do {
            try owner.validate(UpdateInstallTarget(version: appcastItem.displayVersionString, build: appcastItem.versionString),
                               downloadURL: appcastItem.fileURL, informationOnly: appcastItem.isInformationOnlyUpdate, sessionID: sessionID)
            if state.stage == .installing {
                owner.readyToInstall(sessionID: sessionID) { reply($0 ? .install : .skip) }
            } else {
                reply(.install)
            }
        } catch {
            owner.fail(error, sessionID: sessionID)
            reply(state.stage == .installing ? .skip : .dismiss)
        }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.fail(UpdateInstallFailure(message: "Подписанное обновление пока недоступно для этого Mac. Попробуй позже или установи DMG вручную.", detail: error.localizedDescription), sessionID: sessionID)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.fail(error, sessionID: sessionID)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        owner?.downloading(cancellation: cancellation, sessionID: sessionID)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        owner?.receivedExpectedLength(expectedContentLength, sessionID: sessionID)
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        owner?.receivedData(length, sessionID: sessionID)
    }
    func showDownloadDidStartExtractingUpdate() { owner?.extracting(sessionID: sessionID) }
    func showExtractionReceivedProgress(_ progress: Double) { owner?.extracting(progress: progress, sessionID: sessionID) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let owner else { reply(.skip); return }
        owner.readyToInstall(sessionID: sessionID) { reply($0 ? .install : .skip) }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        owner?.installing(applicationTerminated: applicationTerminated, retry: retryTerminatingApplication, sessionID: sessionID)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        owner?.dismissed(sessionID: sessionID)
        // SPUUpdater retains its user driver. Release it after this callback has
        // unwound so a cancelled/failed attempt does not retain a second updater.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.owner?.activeSessionID == self.sessionID, self.owner?.state == .restarting { return }
            self.updater = nil
        }
    }
    func showUpdateInFocus() { owner?.openUpdates?() }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { owner?.fail(error, sessionID: sessionID) }
}
#endif
