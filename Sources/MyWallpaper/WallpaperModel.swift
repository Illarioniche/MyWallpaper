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
    let wallpaperLibrary: WallpaperLibraryController
    let screenSaverSync: ScreenSaverSyncController
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
    private var isApplyingWallpaperOptions = false
    private var libraryTask: Task<Void, Never>?
    private var libraryActionID = UUID()
    private var libraryActionCount = 0
    private var appliedPowerRules = WallpaperPowerRules()
    @Published private(set) var wallpaperPowerOverride: WallpaperPowerRules?
    @Published private(set) var isTemporarilyAnimating = false
    @Published private(set) var legacyCurrentWallpaperID: UUID?

    @Published private(set) var activeWallpaperID: UUID?
    @Published private(set) var isWorkingWithWallpapers = false

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
            if oldValue != scaling {
                synchronizeSystemWallpaper()
                synchronizeScreenSaver()
            }
        }
    }
    @Published var syncSystemWallpaper: Bool {
        didSet {
            preferences.syncSystemWallpaper = syncSystemWallpaper
            synchronizeSystemWallpaper()
        }
    }
    @Published var syncScreenSaver: Bool {
        didSet {
            preferences.syncScreenSaver = syncScreenSaver
            synchronizeScreenSaver()
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
    // These four controls are the app-wide defaults. Applying a wallpaper only
    // changes its optional override, never these values.
    @Published var pauseInLowPowerMode: Bool { didSet { globalPowerRulesChanged() } }
    @Published var restoreOnLaunch: Bool {
        didSet { preferences.restoreOnLaunch = restoreOnLaunch }
    }
    @Published var pauseWhenCovered: Bool { didSet { globalPowerRulesChanged() } }
    @Published var animateOnExternalPower: Bool { didSet { globalPowerRulesChanged() } }
    @Published var animateOnBattery: Bool { didSet { globalPowerRulesChanged() } }

    var globalPowerRules: WallpaperPowerRules {
        WallpaperPowerRules(animateOnExternalPower: animateOnExternalPower,
            animateOnBattery: animateOnBattery, pauseInLowPowerMode: pauseInLowPowerMode,
            pauseWhenCovered: pauseWhenCovered)
    }
    var effectivePowerRules: WallpaperPowerRules { wallpaperPowerOverride ?? globalPowerRules }
    var activeWallpaperUsesGlobalPowerRules: Bool { wallpaperPowerOverride == nil }
    var hasLegacyCurrentSettings: Bool {
        legacyCurrentWallpaperID != nil && legacyCurrentWallpaperID == activeWallpaperID
    }

    var playbackButtonTitle: String {
        if !hasWallpaper { return localizer.text("Включить") }
        if userPaused { return localizer.text("Продолжить") }
        return policy.animatesOnCurrentPowerSource || isTemporarilyAnimating
            ? localizer.text("Пауза") : localizer.text("Оживить сейчас")
    }

    var playbackButtonSymbol: String {
        hasWallpaper && !userPaused && (policy.animatesOnCurrentPowerSource || isTemporarilyAnimating) ? "pause.fill" : "play.fill"
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
         systemWallpaperSync: (any SystemWallpaperSyncing)? = nil,
         wallpaperLibrary: WallpaperLibraryController? = nil,
         screenSaverSync: ScreenSaverSyncController? = nil) {
        self.preferences = preferences
        let hadGlobalRules = preferences.hasStoredGlobalPowerRules
        let defaults = preferences.globalPowerRules
        let cachedPower = WallpaperPowerRules(animateOnExternalPower: preferences.animateOnExternalPower,
            animateOnBattery: preferences.animateOnBattery, pauseInLowPowerMode: preferences.pauseInLowPowerMode,
            pauseWhenCovered: preferences.pauseWhenCovered)
        // Keep the pre-upgrade current configuration and the saved preset intact.
        // This marker survives relaunch and is cleared only by a deliberate Save
        // or a successful selection, never a failed video load or library write.
        let pendingLegacyID = preferences.legacyCurrentWallpaperID
            ?? (!hadGlobalRules ? preferences.activeWallpaperID : nil)
        legacyCurrentWallpaperID = pendingLegacyID
        preferences.legacyCurrentWallpaperID = pendingLegacyID
        let usesGlobal = preferences.currentWallpaperUsesGlobalPowerRules
            ?? (pendingLegacyID == nil)
        wallpaperPowerOverride = usesGlobal ? nil : cachedPower
        if !hadGlobalRules { preferences.globalPowerRules = defaults }
        self.systemWallpaperSync = systemWallpaperSync ?? SystemWallpaperSync()
        self.loginItems = loginItems ?? LoginItemController()
        self.updates = updates ?? UpdateController()
        self.screenSaver = screenSaver ?? ScreenSaverController()
        self.wallpaperLibrary = wallpaperLibrary ?? WallpaperLibraryController()
        self.screenSaverSync = screenSaverSync ?? ScreenSaverSyncController()
        activeWallpaperID = preferences.activeWallpaperID
        language = preferences.language
        let monitor = powerMonitor ?? PowerSourceMonitor()
        self.powerMonitor = monitor
        powerSource = monitor.source
        target = preferences.target
        scaling = preferences.scaling
        syncSystemWallpaper = preferences.syncSystemWallpaper
        syncScreenSaver = preferences.syncScreenSaver
        isMuted = preferences.isMuted
        volume = preferences.volume
        pauseInLowPowerMode = defaults.pauseInLowPowerMode
        pauseWhenCovered = defaults.pauseWhenCovered
        restoreOnLaunch = preferences.restoreOnLaunch
        animateOnExternalPower = defaults.animateOnExternalPower
        animateOnBattery = defaults.animateOnBattery
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
        self.wallpaperLibrary.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        monitor.sourcePublisher
            .removeDuplicates()
            .sink { [weak self] source in
                guard let self else { return }
                if self.powerSource != source { self.setTemporaryAnimation(false) }
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
        refreshEffectivePowerRules()
        observeSystem()
        updatePlayback()
    }

    func restore(afterUpdate snapshot: UpdatePlaybackSnapshot? = nil) {
        // A restart requested by the updater resumes this session even when the
        // user disabled restoration on ordinary launches. A stopped session stays stopped.
        let shouldPlay = snapshot?.wallpaperWasActive
            ?? (preferences.restoreOnLaunch && preferences.wallpaperEnabled)
        let temporarilyAnimate = snapshot?.temporarilyAnimating == true
            && snapshot?.powerSource == powerSource.rawValue
        if let snapshot {
            userPaused = snapshot.userPaused
            policy.userPaused = snapshot.userPaused
            preferences.userPaused = snapshot.userPaused
        }
        guard let id = preferences.activeWallpaperID else {
            restoreExternalVideo(shouldPlay: shouldPlay, temporarilyAnimate: temporarilyAnimate)
            return
        }
        libraryTask?.cancel()
        let actionID = UUID()
        libraryActionID = actionID
        libraryTask = Task { [weak self] in
            guard let self else { return }
            self.beginLibraryAction()
            defer { self.endLibraryAction() }
            await self.wallpaperLibrary.reload()
            guard !Task.isCancelled, self.libraryActionID == actionID else { return }
            guard let entry = self.wallpaperLibrary.entries.first(where: { $0.id == id }) else {
                // Never fall back to an unrelated bookmark when a managed record is missing.
                self.reportError("Сохранённые обои недоступны. Выбери другую запись или добавь видео заново.")
                return
            }
            do {
                let url = try self.wallpaperLibrary.videoURL(for: entry)
                if !self.hasLegacyCurrentSettings { self.applyOptions(entry.options) }
                if shouldPlay {
                    self.selectVideo(url, preservePause: true, libraryEntry: entry, applySavedOptions: false,
                                     temporarilyAnimate: temporarilyAnimate && snapshot?.powerSource == self.powerSource.rawValue)
                } else {
                    self.selectedURL = url
                    self.thumbnail = self.wallpaperLibrary.thumbnails[id]
                    self.synchronizeScreenSaver()
                }
            } catch { self.reportLibraryError(error) }
        }
    }

    private func restoreExternalVideo(shouldPlay: Bool, temporarilyAnimate: Bool) {
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
            if shouldPlay {
                selectVideo(url, preservePause: true, applySavedOptions: false, temporarilyAnimate: temporarilyAnimate)
            } else {
                selectedURL = url
                synchronizeScreenSaver()
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
        addWallpaperVideo()
    }

    func addWallpaperVideo() {
        guard !isWorkingWithWallpapers else { return }
        let panel = NSOpenPanel()
        panel.title = localizer.text("Выбери живые обои")
        panel.prompt = localizer.text("Добавить видео")
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = selectedURL?.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.importWallpaper(url) }
        }
    }

    func selectVideo(_ url: URL, preservePause: Bool = false,
                     libraryEntry: WallpaperLibraryEntry? = nil, applySavedOptions: Bool = true,
                     temporarilyAnimate: Bool = false) {
        guard url.isFileURL else {
            reportError("Выбери видео, сохранённое на этом Mac.")
            return
        }
        libraryActionID = UUID()
        loadingTask?.cancel()
        cancelSystemWallpaperSync()
        screenSaverSync.cancelSynchronization()
        let requestID = UUID()
        let temporaryAnimationSource = powerSource
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
                try await self.engine.load(url: url, beforeCommit: { [weak self] in
                    // A newly selected entry must not briefly play with the old entry's audio settings.
                    self?.engine.setPlaybackEnabled(false)
                })
                try Task.checkCancellation()
                guard self.loadID == requestID else { return }
                self.releaseScope()
                if acquiredScope { self.scopedURL = url; retainedScope = true }
                self.selectedURL = url
                self.activeWallpaperID = libraryEntry?.id
                self.preferences.activeWallpaperID = libraryEntry?.id
                self.thumbnail = self.engine.posterImage.map { NSImage(cgImage: $0, size: .zero) }
                self.preferences.videoBookmark = bookmark
                self.preferences.wallpaperEnabled = true
                if let libraryEntry, applySavedOptions {
                    let latest = self.wallpaperLibrary.entries.first { $0.id == libraryEntry.id } ?? libraryEntry
                    self.applyOptions(latest.options)
                }
                if libraryEntry == nil, applySavedOptions {
                    self.wallpaperPowerOverride = nil
                    self.refreshEffectivePowerRules()
                }
                self.setTemporaryAnimation(temporarilyAnimate && temporaryAnimationSource == self.powerSource
                                           && !self.permanentAnimationIsAllowed)
                if applySavedOptions { self.clearLegacyCurrentSettings() }
                if !preservePause {
                    self.userPaused = false
                    self.policy.userPaused = false
                    self.preferences.userPaused = false
                }
                self.updatePlayback()
                self.isLoading = false
                self.synchronizeSystemWallpaper()
                self.synchronizeScreenSaver()
            } catch is CancellationError {
                // A later selection or Stop owns the state now.
            } catch {
                guard self.loadID == requestID else { return }
                self.reportError("Не удалось открыть видео. %@", detail: error.localizedDescription)
                self.isLoading = false
                self.synchronizeScreenSaver()
            }
        }
    }

    func togglePlayback() {
        if !hasWallpaper {
            if let selectedURL {
                let entry = activeWallpaperID.flatMap { id in wallpaperLibrary.entries.first { $0.id == id } }
                selectVideo(selectedURL, libraryEntry: entry, applySavedOptions: false, temporarilyAnimate: true)
            } else { chooseVideo() }
            return
        }
        if userPaused || (!policy.animatesOnCurrentPowerSource && !isTemporarilyAnimating) {
            setTemporaryAnimation(!permanentAnimationIsAllowed)
            userPaused = false
        } else {
            userPaused = true
        }
        policy.userPaused = userPaused
        preferences.userPaused = userPaused
        updatePlayback()
    }

    private var permanentAnimationIsAllowed: Bool {
        powerSource == .battery ? effectivePowerRules.animateOnBattery : effectivePowerRules.animateOnExternalPower
    }

    private func setTemporaryAnimation(_ enabled: Bool) {
        isTemporarilyAnimating = enabled
        policy.temporaryAnimationOverride = enabled
    }

    func stop() {
        setTemporaryAnimation(false)
        let wasLoading = isLoading
        libraryActionID = UUID()
        loadingTask?.cancel()
        cancelSystemWallpaperSync()
        loadID = UUID()
        isLoading = false
        engine.stop()
        preferences.wallpaperEnabled = false
        releaseScope()
        if wasLoading { synchronizeScreenSaver() }
    }

    func shutDown() {
        screenSaverSync.cancelSynchronization()
        libraryTask?.cancel()
        loadingTask?.cancel()
        cancelSystemWallpaperSync()
        engine.stop()
        releaseScope()
    }

    func revealVideo() {
        if let selectedURL { NSWorkspace.shared.activateFileViewerSelecting([selectedURL]) }
    }

    var selectedWallpaperName: String? {
        activeWallpaperID.flatMap { id in wallpaperLibrary.entries.first { $0.id == id }?.name }
    }

    var currentWallpaperOptions: WallpaperLibraryOptions {
        let rules = effectivePowerRules
        return WallpaperLibraryOptions(target: target, scaling: scaling, isMuted: isMuted, volume: volume,
            animateOnExternalPower: rules.animateOnExternalPower, animateOnBattery: rules.animateOnBattery,
            pauseInLowPowerMode: rules.pauseInLowPowerMode, pauseWhenCovered: rules.pauseWhenCovered,
            syncSystemWallpaper: syncSystemWallpaper, usesGlobalPowerRules: activeWallpaperUsesGlobalPowerRules)
    }

    func editorOptions(for entry: WallpaperLibraryEntry) -> WallpaperLibraryOptions {
        activeWallpaperID == entry.id ? currentWallpaperOptions
            : (wallpaperLibrary.entries.first { $0.id == entry.id }?.options ?? entry.options)
    }

    func importWallpaper(_ url: URL) {
        guard !isWorkingWithWallpapers, !isLoading else { return }
        libraryTask?.cancel()
        let actionID = UUID()
        libraryActionID = actionID
        // Import starts from predictable video defaults and inherits the app's
        // power policy instead of copying the previous wallpaper's exceptions.
        let options = WallpaperLibraryOptions()
        beginLibraryAction()
        libraryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.endLibraryAction() }
            if let entry = await self.wallpaperLibrary.addVideo(url, options: options),
               !Task.isCancelled, self.libraryActionID == actionID {
                self.applyWallpaper(entry)
            }
        }
    }

    func saveCurrentWallpaperToLibrary() async {
        guard !isWorkingWithWallpapers, !isLoading, activeWallpaperID == nil, let source = selectedURL else { return }
        let generation = loadID
        let actionID = libraryActionID
        beginLibraryAction()
        defer { endLibraryAction() }
        guard let entry = await wallpaperLibrary.addVideo(source, options: currentWallpaperOptions),
              !Task.isCancelled, loadID == generation, libraryActionID == actionID, selectedURL == source else { return }
        do {
            let url = try wallpaperLibrary.videoURL(for: entry)
            if hasWallpaper {
                selectVideo(url, preservePause: true, libraryEntry: entry, applySavedOptions: false)
            } else {
                let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                releaseScope()
                selectedURL = url
                activeWallpaperID = entry.id
                preferences.activeWallpaperID = entry.id
                preferences.videoBookmark = bookmark
                thumbnail = wallpaperLibrary.thumbnails[entry.id]
                synchronizeScreenSaver()
            }
        } catch { reportLibraryError(error) }
    }

    func applyWallpaper(_ entry: WallpaperLibraryEntry) {
        do {
            let url = try wallpaperLibrary.videoURL(for: entry)
            selectVideo(url, libraryEntry: entry)
        } catch { reportLibraryError(error) }
    }

    @discardableResult
    func renameWallpaper(_ entry: WallpaperLibraryEntry, name: String) async -> Bool {
        beginLibraryAction()
        defer { endLibraryAction() }
        guard await wallpaperLibrary.rename(entry, name: name) != nil else { return false }
        if activeWallpaperID == entry.id { synchronizeScreenSaver() }
        return true
    }

    @discardableResult
    func updateWallpaper(_ entry: WallpaperLibraryEntry, options: WallpaperLibraryOptions,
                         originalOptions: WallpaperLibraryOptions? = nil) async -> Bool {
        guard !isLoading else { return false }
        let latest = editorOptions(for: entry)
        let merged = originalOptions.map { Self.mergeEditedOptions(options, original: $0, latest: latest) } ?? options
        beginLibraryAction()
        defer { endLibraryAction() }
        guard let updated = await wallpaperLibrary.updateOptions(entry, options: merged) else { return false }
        if activeWallpaperID == entry.id {
            applyEditedOptions(updated.options)
        }
        return true
    }

    @discardableResult
    func updateCurrentWallpaper(options: WallpaperLibraryOptions,
                                originalOptions: WallpaperLibraryOptions? = nil,
                                expectedURL: URL? = nil) async -> Bool {
        guard selectedURL != nil, !isLoading else { return false }
        if let expectedURL, selectedURL != expectedURL { return false }
        if let id = activeWallpaperID {
            guard let entry = wallpaperLibrary.entries.first(where: { $0.id == id }) else { return false }
            return await updateWallpaper(entry, options: options, originalOptions: originalOptions)
        }
        let merged = originalOptions.map {
            Self.mergeEditedOptions(options, original: $0, latest: currentWallpaperOptions)
        } ?? options
        applyEditedOptions(merged)
        return true
    }

    func toggleCurrentWallpaperMute() async {
        guard !isWorkingWithWallpapers, !wallpaperLibrary.isWorking, !isLoading else { return }
        // Until the legacy current settings are explicitly saved, quick actions
        // keep using that cache without overwriting the separately saved preset.
        if hasLegacyCurrentSettings {
            isMuted.toggle()
            return
        }
        var options = currentWallpaperOptions
        options.isMuted.toggle()
        _ = await updateCurrentWallpaper(options: options)
    }

    /// Only edited fields replace the latest values. A tray action or a global
    /// rule change while a sheet is open must not be undone by saving its draft.
    private static func mergeEditedOptions(_ edited: WallpaperLibraryOptions,
                                           original: WallpaperLibraryOptions,
                                           latest: WallpaperLibraryOptions) -> WallpaperLibraryOptions {
        var result = latest
        if edited.target != original.target { result.target = edited.target }
        if edited.scaling != original.scaling { result.scaling = edited.scaling }
        if edited.isMuted != original.isMuted { result.isMuted = edited.isMuted }
        if Float(edited.volume) != Float(original.volume) { result.volume = edited.volume }
        if edited.syncSystemWallpaper != original.syncSystemWallpaper { result.syncSystemWallpaper = edited.syncSystemWallpaper }
        if edited.usesGlobalPowerRules != original.usesGlobalPowerRules || edited.powerRules != original.powerRules {
            result.usesGlobalPowerRules = edited.usesGlobalPowerRules
            result.powerRules = edited.powerRules
        }
        return result
    }

    @discardableResult
    func deleteWallpaper(_ entry: WallpaperLibraryEntry) async -> Bool {
        guard !isLoading else { return false }
        beginLibraryAction()
        defer { endLibraryAction() }
        guard await wallpaperLibrary.delete(entry) else { return false }
        if activeWallpaperID == entry.id {
            screenSaverSync.cancelSynchronization()
            screenSaverSync.dismissFailure()
            stop()
            activeWallpaperID = nil
            preferences.activeWallpaperID = nil
            preferences.videoBookmark = nil
            clearLegacyCurrentSettings()
            selectedURL = nil
            thumbnail = nil
            wallpaperPowerOverride = nil
            refreshEffectivePowerRules()
        }
        return true
    }

    private func applyOptions(_ options: WallpaperLibraryOptions) {
        let newOverride = options.usesGlobalPowerRules ? nil : options.powerRules
        // An explicit change of power policy ends Animate Now. Unrelated edits
        // such as volume and scaling leave the temporary playback choice alone.
        if wallpaperPowerOverride != newOverride { setTemporaryAnimation(false) }
        isApplyingWallpaperOptions = true
        target = options.target
        scaling = options.scaling
        isMuted = options.isMuted
        volume = options.volume
        wallpaperPowerOverride = newOverride
        syncSystemWallpaper = options.syncSystemWallpaper
        isApplyingWallpaperOptions = false
        refreshEffectivePowerRules()
    }

    private func applyEditedOptions(_ options: WallpaperLibraryOptions) {
        let previous = currentWallpaperOptions
        applyOptions(options)
        clearLegacyCurrentSettings()
        let current = currentWallpaperOptions
        // Audio edits must not rewrite the system background or regenerate the
        // linked saver. Each integration observes only the settings it uses.
        if previous.target != current.target || previous.scaling != current.scaling
            || previous.syncSystemWallpaper != current.syncSystemWallpaper {
            synchronizeSystemWallpaper()
        }
        if previous.scaling != current.scaling
            || previous.animateOnExternalPower != current.animateOnExternalPower
            || previous.animateOnBattery != current.animateOnBattery
            || previous.pauseInLowPowerMode != current.pauseInLowPowerMode {
            synchronizeScreenSaver()
        }
    }

    private func clearLegacyCurrentSettings() {
        legacyCurrentWallpaperID = nil
        preferences.legacyCurrentWallpaperID = nil
    }

    private func globalPowerRulesChanged() {
        guard !isApplyingWallpaperOptions else { return }
        preferences.globalPowerRules = globalPowerRules
        let previous = appliedPowerRules
        let current = effectivePowerRules
        if previous != current { setTemporaryAnimation(false) }
        refreshEffectivePowerRules()
        // Desktop coverage does not affect the system screen saver.
        if previous.animateOnExternalPower != current.animateOnExternalPower
            || previous.animateOnBattery != current.animateOnBattery
            || previous.pauseInLowPowerMode != current.pauseInLowPowerMode {
            synchronizeScreenSaver()
        }
    }

    private func refreshEffectivePowerRules() {
        let rules = effectivePowerRules
        appliedPowerRules = rules
        policy.animateOnExternalPower = rules.animateOnExternalPower
        policy.animateOnBattery = rules.animateOnBattery
        policy.pauseInLowPowerMode = rules.pauseInLowPowerMode
        preferences.animateOnExternalPower = rules.animateOnExternalPower
        preferences.animateOnBattery = rules.animateOnBattery
        preferences.pauseInLowPowerMode = rules.pauseInLowPowerMode
        preferences.pauseWhenCovered = rules.pauseWhenCovered
        preferences.currentWallpaperUsesGlobalPowerRules = activeWallpaperUsesGlobalPowerRules
        configureEngine()
        updatePlayback()
    }

    private func beginLibraryAction() {
        libraryActionCount += 1
        isWorkingWithWallpapers = true
    }

    private func endLibraryAction() {
        libraryActionCount -= 1
        isWorkingWithWallpapers = libraryActionCount > 0
    }

    private func reportLibraryError(_ error: Error) {
        if let failure = error as? WallpaperLibraryError {
            renderError = { localizer in
                localizer.text(failure.ruKey) + (failure.detail.map { "\n\n" + $0 } ?? "")
            }
            errorMessage = renderError?(localizer)
        } else {
            reportError("Не удалось открыть видео. %@", detail: error.localizedDescription)
        }
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
        guard !isApplyingWallpaperOptions else { return }
        engine.configure(target: target, scaling: scaling, isMuted: isMuted,
                         pauseWhenCovered: effectivePowerRules.pauseWhenCovered, volume: Float(volume))
    }

    func synchronizeScreenSaver() {
        guard !isApplyingWallpaperOptions else { return }
        guard syncScreenSaver else {
            screenSaverSync.cancelSynchronization()
            screenSaverSync.dismissFailure()
            return
        }
        guard !isLoading, let selectedURL else { return }
        let name = selectedWallpaperName ?? selectedURL.deletingPathExtension().lastPathComponent
        let rules = effectivePowerRules
        screenSaverSync.synchronize(videoURL: selectedURL, name: String(name.prefix(80)),
            options: ScreenSaverExportOptions(scaling: scaling == .fill ? .fill : .fit,
                animateOnBattery: rules.animateOnBattery, animateOnExternalPower: rules.animateOnExternalPower,
                pauseInLowPowerMode: rules.pauseInLowPowerMode))
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
        guard !isApplyingWallpaperOptions else { return }
        cancelSystemWallpaperSync()
        guard syncSystemWallpaper, !isLoading, engine.hasWallpaper,
              let image = engine.posterImage, let selectedURL else {
            synchronizedScreenIDs = []
            return
        }
        synchronizedScreenIDs = selectedSystemScreenIDs
        let requestID = systemWallpaperRequestID
        let service = systemWallpaperSync
        let name = selectedWallpaperName ?? selectedURL.deletingPathExtension().lastPathComponent
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
        guard !isApplyingWallpaperOptions else { return }
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
