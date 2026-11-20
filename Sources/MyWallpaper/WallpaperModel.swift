import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class WallpaperModel: ObservableObject {
    let engine = WallpaperEngine()
    let loginItems: LoginItemController
    let updates: UpdateController
    let screenSaver: ScreenSaverController
    private let powerMonitor: any PowerSourceMonitoring
    private let preferences: WallpaperPreferences
    private let systemWallpaperSync: any SystemWallpaperSyncing
    private var policy = PlaybackPolicy()
    private var subscriptions = Set<AnyCancellable>()
    private var loadingTask: Task<Void, Never>?
    private var loadID = UUID()
    private var systemWallpaperTask: Task<Void, Never>?
    private var systemWallpaperRequestID = UUID()
    private var synchronizedScreenIDs: [UInt32] = []
    private var scopedURL: URL?
    private var forwardedLoginError: String?
    private var renderError: ((AppLocalizer) -> String)?
    private var isChangingLanguage = false

    @Published private(set) var selectedURL: URL?
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var isLoading = false
    @Published private(set) var isSyncingSystemWallpaper = false
    @Published private(set) var hasWallpaper = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isPausedForOcclusion = false
    @Published private(set) var occludedDisplayCount = 0
    @Published private(set) var displayCount = 0
    @Published private(set) var userPaused: Bool
    @Published private(set) var pauseReason: String?
    @Published private(set) var powerSource: PowerSource
    @Published var errorMessage: String? {
        didSet { if errorMessage == nil { renderError = nil } }
    }

    @Published var language: AppLanguage {
        didSet {
            preferences.language = language
            applyLocalization()
        }
    }
    var localizer: AppLocalizer { AppLocalizer(language: language) }

    @Published var target: DisplayTarget {
        didSet {
            preferences.target = target
            configureEngine()
            if oldValue != target { synchronizeSystemWallpaper() }
        }
    }
    @Published var scaling: VideoScaling {
        didSet {
            preferences.scaling = scaling
            configureEngine()
            if oldValue != scaling { synchronizeSystemWallpaper() }
        }
    }
    @Published var syncSystemWallpaper: Bool {
        didSet {
            preferences.syncSystemWallpaper = syncSystemWallpaper
            synchronizeSystemWallpaper()
        }
    }
    @Published var isMuted: Bool {
        didSet { preferences.isMuted = isMuted; configureEngine() }
    }
    @Published var volume: Double {
        didSet {
            let normalized = Double(WallpaperAudioSettings.normalizedVolume(Float(volume)))
            if volume != normalized {
                volume = normalized
                return
            }
            preferences.volume = volume
            configureEngine()
        }
    }
    @Published var pauseInLowPowerMode: Bool {
        didSet {
            preferences.pauseInLowPowerMode = pauseInLowPowerMode
            policy.pauseInLowPowerMode = pauseInLowPowerMode
            updatePlayback()
        }
    }
    @Published var restoreOnLaunch: Bool {
        didSet { preferences.restoreOnLaunch = restoreOnLaunch }
    }
    @Published var pauseWhenCovered: Bool {
        didSet { preferences.pauseWhenCovered = pauseWhenCovered; configureEngine() }
    }
    @Published var animateOnExternalPower: Bool {
        didSet {
            preferences.animateOnExternalPower = animateOnExternalPower
            policy.animateOnExternalPower = animateOnExternalPower
            updatePlayback()
        }
    }
    @Published var animateOnBattery: Bool {
        didSet {
            preferences.animateOnBattery = animateOnBattery
            policy.animateOnBattery = animateOnBattery
            updatePlayback()
        }
    }

    var playbackButtonTitle: String {
        if !hasWallpaper { return localizer.text("Включить") }
        if userPaused { return localizer.text("Продолжить") }
        return policy.animatesOnCurrentPowerSource ? localizer.text("Пауза") : localizer.text("Оживить")
    }

    var playbackButtonSymbol: String {
        hasWallpaper && !userPaused && policy.animatesOnCurrentPowerSource ? "pause.fill" : "play.fill"
    }

    var status: String {
        if isLoading { return localizer.text("Загружаем видео…") }
        if !hasWallpaper { return selectedURL == nil ? localizer.text("Выбери своё настроение") : localizer.text("Обои выключены") }
        if let pauseReason { return pauseReason }
        if isPausedForOcclusion { return localizer.text("Пауза: рабочий стол скрыт") }
        if isPlaying && occludedDisplayCount > 0 {
            return localizer.format("Воспроизведение: %@ из %@ экранов", String(displayCount - occludedDisplayCount), String(displayCount))
        }
        return isPlaying ? localizer.text("Обои воспроизводятся") : localizer.text("Подготовка видео…")
    }

    init(preferences: WallpaperPreferences = WallpaperPreferences(),
         loginItems: LoginItemController? = nil,
         powerMonitor: (any PowerSourceMonitoring)? = nil,
         updates: UpdateController? = nil,
         screenSaver: ScreenSaverController? = nil,
         systemWallpaperSync: (any SystemWallpaperSyncing)? = nil) {
        self.preferences = preferences
        self.systemWallpaperSync = systemWallpaperSync ?? SystemWallpaperSync()
        self.loginItems = loginItems ?? LoginItemController()
        self.updates = updates ?? UpdateController()
        self.screenSaver = screenSaver ?? ScreenSaverController()
        language = preferences.language
        let monitor = powerMonitor ?? PowerSourceMonitor()
        self.powerMonitor = monitor
        powerSource = monitor.source
        target = preferences.target
        scaling = preferences.scaling
        syncSystemWallpaper = preferences.syncSystemWallpaper
        isMuted = preferences.isMuted
        volume = preferences.volume
        pauseInLowPowerMode = preferences.pauseInLowPowerMode
        pauseWhenCovered = preferences.pauseWhenCovered
        restoreOnLaunch = preferences.restoreOnLaunch
        animateOnExternalPower = preferences.animateOnExternalPower
        animateOnBattery = preferences.animateOnBattery
        userPaused = preferences.userPaused
        policy.userPaused = preferences.userPaused
        policy.pauseInLowPowerMode = preferences.pauseInLowPowerMode
        policy.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        policy.powerSource = monitor.source
        policy.animateOnExternalPower = preferences.animateOnExternalPower
        policy.animateOnBattery = preferences.animateOnBattery
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            policy.sessionInactive = !(session[kCGSessionOnConsoleKey as String] as? Bool ?? true)
        }
        applyLocalization()

        engine.$hasWallpaper.assign(to: &$hasWallpaper)
        engine.$isPlaying.assign(to: &$isPlaying)
        engine.$isPausedForOcclusion.assign(to: &$isPausedForOcclusion)
        engine.$occludedDisplayCount.assign(to: &$occludedDisplayCount)
        engine.$displayCount.assign(to: &$displayCount)
        monitor.sourcePublisher
            .removeDuplicates()
            .sink { [weak self] source in
                guard let self else { return }
                self.powerSource = source
                self.policy.powerSource = source
                self.updatePlayback()
            }
            .store(in: &subscriptions)
        self.loginItems.$errorMessage
            .sink { [weak self] message in
                guard let self else { return }
                if let message, !self.isChangingLanguage || self.errorMessage == self.forwardedLoginError {
                    self.renderError = nil
                    self.errorMessage = message
                } else if self.errorMessage == self.forwardedLoginError {
                    self.errorMessage = nil
                }
                self.forwardedLoginError = message
            }
            .store(in: &subscriptions)
        engine.onPlaybackError = { [weak self] message, detail in
            guard let self else { return }
            self.cancelSystemWallpaperSync()
            self.renderError = { localizer in
                let message = localizer.text(message)
                if let detail, !detail.isEmpty { return message + "\n\n" + detail }
                return message
            }
            self.errorMessage = self.renderError?(self.localizer)
            self.preferences.wallpaperEnabled = false
        }
        configureEngine()
        observeSystem()
        updatePlayback()
    }

    func restore() {
        guard let bookmark = preferences.videoBookmark else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: [.withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            let acquiredScope = url.startAccessingSecurityScopedResource()
            var retainedScope = false
            defer {
                if acquiredScope && !retainedScope { url.stopAccessingSecurityScopedResource() }
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            if stale {
                preferences.videoBookmark = try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            if preferences.restoreOnLaunch && preferences.wallpaperEnabled {
                selectVideo(url, preservePause: true)
            } else {
                selectedURL = url
                if acquiredScope { scopedURL = url; retainedScope = true }
                loadingTask = Task { [weak self] in
                    let image = await Self.makeThumbnail(url)
                    guard !Task.isCancelled else { return }
                    self?.thumbnail = image
                }
            }
        } catch {
            reportError("Не удалось найти сохранённое видео. Возможно, файл перемещён или диск отключён. Выбери его заново.")
        }
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = localizer.text("Выбери живые обои")
        panel.prompt = localizer.text("Установить обои")
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = selectedURL?.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.selectVideo(url) }
        }
    }

    func selectVideo(_ url: URL, preservePause: Bool = false) {
        guard url.isFileURL else {
            reportError("Выбери видео, сохранённое на этом Mac.")
            return
        }
        loadingTask?.cancel()
        cancelSystemWallpaperSync()
        let requestID = UUID()
        loadID = requestID
        isLoading = true
        errorMessage = nil
        loadingTask = Task { [weak self] in
            guard let self else { return }
            let acquiredScope = url.startAccessingSecurityScopedResource()
            var retainedScope = false
            defer {
                if acquiredScope && !retainedScope { url.stopAccessingSecurityScopedResource() }
                if self.loadID == requestID { self.isLoading = false }
            }
            do {
                // Prepare the bookmark before changing playback, preserving the previous file on failure.
                // This local app is not App Sandbox-enabled; regular bookmarks track moved files
                // without requiring the security-scoped bookmark service.
                let bookmark = try url.bookmarkData(options: [],
                                                    includingResourceValuesForKeys: nil, relativeTo: nil)
                try await self.engine.load(url: url)
                try Task.checkCancellation()
                guard self.loadID == requestID else { return }
                self.releaseScope()
                if acquiredScope { self.scopedURL = url; retainedScope = true }
                self.selectedURL = url
                self.thumbnail = self.engine.posterImage.map { NSImage(cgImage: $0, size: .zero) }
                self.preferences.videoBookmark = bookmark
                self.preferences.wallpaperEnabled = true
                if !preservePause {
                    self.userPaused = false
                    self.policy.userPaused = false
                    self.preferences.userPaused = false
                }
                self.updatePlayback()
                self.isLoading = false
                self.synchronizeSystemWallpaper()
            } catch is CancellationError {
                // A later selection or Stop owns the state now.
            } catch {
                guard self.loadID == requestID else { return }
                self.reportError("Не удалось открыть видео. %@", detail: error.localizedDescription)
            }
        }
    }

    func togglePlayback() {
        if !hasWallpaper {
            if let selectedURL {
                enableAnimationForCurrentPowerSource()
                selectVideo(selectedURL)
            } else { chooseVideo() }
            return
        }
        if userPaused || !policy.animatesOnCurrentPowerSource {
            // An explicit Play also opts this source into animation. Changing
            // the source later still uses its own saved setting.
            enableAnimationForCurrentPowerSource()
            userPaused = false
        } else {
            userPaused = true
        }
        policy.userPaused = userPaused
        preferences.userPaused = userPaused
        updatePlayback()
    }

    private func enableAnimationForCurrentPowerSource() {
        if powerSource == .battery { animateOnBattery = true }
        else { animateOnExternalPower = true }
    }

    func stop() {
        loadingTask?.cancel()
        cancelSystemWallpaperSync()
        loadID = UUID()
        isLoading = false
        engine.stop()
        preferences.wallpaperEnabled = false
        releaseScope()
    }

    func shutDown() {
        loadingTask?.cancel()
        cancelSystemWallpaperSync()
        engine.stop()
        releaseScope()
    }

    func revealVideo() {
        if let selectedURL { NSWorkspace.shared.activateFileViewerSelecting([selectedURL]) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItems.setEnabled(enabled)
        if enabled && (loginItems.status == .enabled || loginItems.status == .requiresApproval) {
            restoreOnLaunch = true
        }
    }

    private func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    private func configureEngine() {
        engine.configure(target: target, scaling: scaling, isMuted: isMuted,
                         pauseWhenCovered: pauseWhenCovered, volume: Float(volume))
    }

    private var selectedSystemScreenIDs: [UInt32] {
        let screens = target == .main ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
        return screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
    }

    private func cancelSystemWallpaperSync() {
        systemWallpaperRequestID = UUID()
        systemWallpaperTask?.cancel()
        systemWallpaperTask = nil
        isSyncingSystemWallpaper = false
    }

    private func synchronizeSystemWallpaper() {
        cancelSystemWallpaperSync()
        guard syncSystemWallpaper, !isLoading, engine.hasWallpaper,
              let image = engine.posterImage, let selectedURL else {
            synchronizedScreenIDs = []
            return
        }
        synchronizedScreenIDs = selectedSystemScreenIDs
        let requestID = systemWallpaperRequestID
        let service = systemWallpaperSync
        let name = selectedURL.deletingPathExtension().lastPathComponent
        let target = self.target
        let scaling = self.scaling
        isSyncingSystemWallpaper = true
        systemWallpaperTask = Task { [weak self] in
            defer {
                if let self, self.systemWallpaperRequestID == requestID {
                    self.isSyncingSystemWallpaper = false
                    self.systemWallpaperTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                try await service.synchronize(image: image, name: name, target: target, scaling: scaling)
            } catch is CancellationError {
                // A newer video, disabled sync, or Stop owns the state now.
            } catch {
                guard let self, !Task.isCancelled, self.systemWallpaperRequestID == requestID else { return }
                if let failure = error as? SystemWallpaperSyncError {
                    self.renderError = { localizer in
                        let message = localizer.text(failure.ruKey)
                        return failure.detail.map { message + "\n\n" + $0 } ?? message
                    }
                    self.errorMessage = self.renderError?(self.localizer)
                } else {
                    self.reportError("Не удалось обновить системные обои. %@", detail: error.localizedDescription)
                }
            }
        }
    }

    private func updatePlayback() {
        pauseReason = policy.pauseReason.map { localizer.text($0) }
        engine.setPlaybackEnabled(policy.shouldPlay)
    }

    private func reportError(_ key: String, detail: String? = nil) {
        renderError = { localizer in
            if let detail { return localizer.format(key, localizer.text(detail)) }
            return localizer.text(key)
        }
        errorMessage = renderError?(localizer)
    }

    private func applyLocalization() {
        isChangingLanguage = true
        defer { isChangingLanguage = false }
        loginItems.localizer = localizer
        updates.localizer = localizer
        pauseReason = policy.pauseReason.map { localizer.text($0) }
        if let renderError { errorMessage = renderError(localizer) }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.policy.systemSleeping = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.policy.systemSleeping = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.policy.screensSleeping = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.policy.screensSleeping = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.policy.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.policy.sessionInactive = false }
        observe(.default, .NSProcessInfoPowerStateDidChange) {
            $0.policy.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) {
            // Dock/window geometry changes can also send this notification.
            // Only a changed set/order of target displays needs a new sync.
            if $0.syncSystemWallpaper && $0.synchronizedScreenIDs != $0.selectedSystemScreenIDs {
                $0.synchronizeSystemWallpaper()
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         change: @escaping @MainActor (WallpaperModel) -> Void) {
        center.publisher(for: name)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    change(self)
                    self.updatePlayback()
                }
            }
            .store(in: &subscriptions)
    }

    private static func makeThumbnail(_ url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_280, height: 720)
        guard let result = try? await generator.image(at: .zero), !Task.isCancelled else { return nil }
        return NSImage(cgImage: result.image, size: .zero)
    }
}
