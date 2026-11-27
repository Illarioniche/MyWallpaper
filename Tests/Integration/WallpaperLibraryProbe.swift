import AppKit
import AVFoundation
import Combine

@main
enum WallpaperLibraryProbe {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: wallpaper-library-probe <local-video> <output-directory>"); exit(2)
        }
        let app = NSApplication.shared
        let delegate = LibraryProbeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private final class LibraryProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await run()
                print("PASS: native library import, apply, per-entry settings, failure preservation, stopped restoration and deletion")
                exit(0)
            } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
    }

    private func run() async throws {
        let video = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try require(!NSScreen.screens.isEmpty, "An active graphical macOS session is required.")
        try require(FileManager.default.fileExists(atPath: video.path), "Missing input video.")
        let scratch = output.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let domain = "WallpaperLibraryProbe.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { throw ProbeFailure(message: "Isolated preferences unavailable.") }
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = WallpaperPreferences(defaults: defaults)
        let storage = WallpaperLibrary(rootURL: scratch.appendingPathComponent("Library"))
        let library = WallpaperLibraryController(library: storage)
        let spy = ProbeSync()
        let login = ProbeLogin()
        func makeModel(_ controller: WallpaperLibraryController) -> WallpaperModel {
            WallpaperModel(preferences: preferences,
                loginItems: LoginItemController(service: login, notificationCenter: NotificationCenter()),
                powerMonitor: ProbePower(),
                updates: UpdateController(currentVersion: "0.7.0", defaults: defaults, transport: { _ in throw URLError(.cancelled) }),
                systemWallpaperSync: spy, wallpaperLibrary: controller)
        }
        let model = makeModel(library)
        defer { model.shutDown() }
        model.pauseWhenCovered = false
        model.pauseInLowPowerMode = false
        let globalRules = model.globalPowerRules
        let aOptions = WallpaperLibraryOptions(target: .all, scaling: .fill, isMuted: true, volume: 0.25,
            animateOnExternalPower: true, animateOnBattery: false, pauseInLowPowerMode: false,
            pauseWhenCovered: false, syncSystemWallpaper: true)
        let bOptions = WallpaperLibraryOptions(target: .main, scaling: .fit, isMuted: true, volume: 0.5,
            animateOnExternalPower: false, animateOnBattery: true, pauseInLowPowerMode: false,
            pauseWhenCovered: false, syncSystemWallpaper: false, usesGlobalPowerRules: false)
        guard let a = await library.addVideo(video, options: aOptions),
              let b = await library.addVideo(video, options: bOptions) else {
            throw ProbeFailure(message: "Real media import failed: \(library.failure?.ruKey ?? "unknown")")
        }
        let aURL = try library.videoURL(for: a)
        let bURL = try library.videoURL(for: b)
        try require(aURL != video && bURL != video && aURL != bURL, "Imports must own independent media copies.")
        try require(library.thumbnails[a.id] != nil && library.thumbnails[b.id] != nil, "Imported previews are missing.")
        model.applyWallpaper(a)
        try await wait("A playback") { !model.isLoading && model.hasWallpaper && model.isPlaying && spy.calls > 0 }
        try require(model.activeWallpaperID == a.id && preferences.activeWallpaperID == a.id, "A identity was not persisted.")
        try require(model.selectedURL == aURL && preferences.videoBookmark != nil, "A managed URL/bookmark was not selected.")
        try require(model.currentWallpaperOptions == aOptions, "A settings were not applied.")
        try require(desktopWindows.count == NSScreen.screens.count, "A should use every display.")
        try require(desktopWindows.allSatisfy { player($0)?.isMuted == true }, "Imported wallpaper unexpectedly enabled audio.")
        model.animateOnExternalPower = false
        try await wait("global rules pause inherited wallpaper") { !model.isPlaying }
        model.animateOnExternalPower = true
        try await wait("global rules resume inherited wallpaper") { model.isPlaying }
        print("PASS: imported two real videos, selected managed A with saved settings and safe system-sync spy")

        model.applyWallpaper(b)
        try await wait("B still mode") { !model.isLoading && model.activeWallpaperID == b.id && model.hasWallpaper && !model.isPlaying }
        let stillDiagnostics = model.diagnosticSnapshot
        try require(model.currentPauseCause == .externalPowerRule && stillDiagnostics.playback == .paused
                    && stillDiagnostics.pauseCause == .externalPowerRule && !stillDiagnostics.usesGlobalPowerRules,
                    "B's actual static playback was not explained as an individual external-power rule.")
        try require(model.playbackExplanation?.contains("This wallpaper is set to stay still on external power.") == true
                    && model.playbackExplanation?.contains("The individual rules in this wallpaper’s editor apply.") == true,
                    "B's pause explanation was not localized in the default English interface.")
        try require(model.currentWallpaperOptions == bOptions, "B settings were not restored.")
        try require(model.globalPowerRules == globalRules && preferences.globalPowerRules == globalRules,
                    "Selecting an exception overwrote common power rules.")
        try require(model.selectedURL == bURL && desktopWindows.count == 1, "B should use its own copy on the main display.")
        try require(desktopWindows.first.flatMap(layer)?.videoGravity == .resizeAspect, "B Fit scaling did not reach AVPlayerLayer.")
        model.togglePlayback()
        try await wait("temporary animation of B") { model.isPlaying }
        try require(model.globalPowerRules == globalRules && model.currentWallpaperOptions == bOptions,
                    "Animate Now changed persistent common rules or the saved exception.")
        model.togglePlayback()
        try await wait("manual pause during temporary animation") { model.userPaused && !model.isPlaying }
        let manualDiagnostics = model.diagnosticSnapshot
        try require(model.currentPauseCause == .manual && manualDiagnostics.pauseCause == .manual
                    && manualDiagnostics.userPaused && manualDiagnostics.playback == .paused,
                    "Manual pause did not take priority in the real playback diagnostic state.")
        model.togglePlayback()
        try await wait("resume temporary animation without changing rules") { !model.userPaused && model.isPlaying }
        try require(model.currentPauseCause == nil && model.playbackExplanation == nil
                    && model.diagnosticSnapshot.playback == .playing,
                    "Resumed temporary playback retained a stale pause explanation or diagnostic state.")
        try require(model.isTemporarilyAnimating && model.currentWallpaperOptions == bOptions,
                    "Pause/Resume discarded temporary playback or rewrote the exception.")
        var audioEdit = model.currentWallpaperOptions
        audioEdit.volume = 0.2
        let savedAudio = await model.updateWallpaper(b, options: audioEdit, originalOptions: model.currentWallpaperOptions)
        try require(savedAudio && model.isTemporarilyAnimating && model.isPlaying,
                    "Saving audio settings interrupted temporary playback.")
        var powerEdit = model.currentWallpaperOptions
        powerEdit.animateOnBattery = false
        let savedPower = await model.updateWallpaper(b, options: powerEdit, originalOptions: model.currentWallpaperOptions)
        try await wait("explicit power edit cancels temporary animation") { !model.isPlaying }
        try require(savedPower && !model.isTemporarilyAnimating && model.globalPowerRules == globalRules,
                    "Saving a power exception did not reset temporary playback independently of shared rules.")
        model.applyWallpaper(a)
        try await wait("A selected again") { !model.isLoading && model.activeWallpaperID == a.id && model.isPlaying }
        try require(model.currentWallpaperOptions == aOptions, "Switching back lost A's saved settings.")
        try Data("Invalid movie, used only by the integration probe.".utf8).write(to: bURL, options: .atomic)
        model.applyWallpaper(b)
        try await wait("invalid B rejected") { !model.isLoading && model.errorMessage != nil }
        try require(model.activeWallpaperID == a.id && model.selectedURL == aURL && model.isPlaying,
                    "Invalid replacement disrupted the active wallpaper.")
        try require(model.currentWallpaperOptions == aOptions && preferences.activeWallpaperID == a.id,
                    "Invalid replacement changed A settings or identity.")
        model.errorMessage = nil
        print("PASS: B uses its own power/scaling profile; invalid B leaves A intact")

        let original = model.editorOptions(for: a)
        var edited = original
        edited.volume = 0.125
        let backgroundUpdates = spy.calls
        let saved = await model.updateWallpaper(a, options: edited, originalOptions: original)
        try require(saved, "Unified editor could not save current wallpaper settings.")
        try await Task.sleep(for: .milliseconds(200))
        try require(spy.calls == backgroundUpdates, "Saving audio unnecessarily changed the macOS wallpaper.")
        let stoppedOptions = model.currentWallpaperOptions
        model.stop()
        try require(model.currentPauseCause == nil && model.playbackExplanation == nil
                    && model.diagnosticSnapshot.playback == .stopped,
                    "Stopping real playback retained a stale pause explanation or diagnostic state.")
        model.shutDown()
        try require(wallpaperWindows.isEmpty && !preferences.wallpaperEnabled, "Stop left wallpaper windows or enabled state.")
        let restoredLibrary = WallpaperLibraryController(library: storage)
        let restored = makeModel(restoredLibrary)
        defer { restored.shutDown() }
        restored.restore()
        try await wait("stopped selection restored") { !restored.isWorkingWithWallpapers && restored.selectedURL != nil }
        try require(restored.activeWallpaperID == a.id && restored.selectedURL == aURL && !restored.hasWallpaper,
                    "Stopped restart lost the selected library entry or started playback.")
        try require(restored.currentWallpaperOptions == stoppedOptions, "Stopped restart lost current settings.")
        restored.togglePlayback()
        try await wait("restored A resumed") { !restored.isLoading && restored.hasWallpaper && restored.isPlaying }
        try require(restored.currentWallpaperOptions == stoppedOptions, "Resume overwrote the unified editor's saved settings.")
        let windowIDs = Set(wallpaperWindows.map(\.windowNumber))
        let removedB = await restored.deleteWallpaper(b)
        try require(removedB && restored.activeWallpaperID == a.id && restored.isPlaying, "Deleting inactive B disrupted A.")
        try require(Set(wallpaperWindows.map(\.windowNumber)) == windowIDs, "Deleting inactive B rebuilt desktop windows.")
        let removedA = await restored.deleteWallpaper(a)
        try require(removedA && restored.activeWallpaperID == nil && restored.selectedURL == nil,
                    "Deleting active A left its identity or media selected.")
        try require(preferences.activeWallpaperID == nil && preferences.videoBookmark == nil && !preferences.wallpaperEnabled,
                    "Deleting active A left restoration metadata.")
        try require(!restored.hasWallpaper && wallpaperWindows.isEmpty && restoredLibrary.entries.isEmpty,
                    "Deleting active A left playback, windows or library records.")
        try require(FileManager.default.fileExists(atPath: video.path) && login.calls == 0,
                    "Probe modified the original file or contacted login items.")
        restored.importWallpaper(video)
        let reload = Task { await restoredLibrary.reload() }
        await reload.value
        try await wait("import action applies its saved record") {
            !restored.isWorkingWithWallpapers && !restored.isLoading && restored.hasWallpaper
                && restored.activeWallpaperID != nil
        }
        guard let imported = restoredLibrary.entries.first else { throw ProbeFailure(message: "Import action lost its entry.") }
        try require(restoredLibrary.entries.count == 1 && restored.activeWallpaperID == imported.id,
                    "Import and queued collection reload did not agree on the active entry.")
        try require(imported.options.usesGlobalPowerRules && restored.globalPowerRules == globalRules,
                    "New imports must inherit common rules without copying an earlier exception.")
        let removedImport = await restored.deleteWallpaper(imported)
        try require(removedImport && wallpaperWindows.isEmpty, "Imported wallpaper did not clean up.")
        print("PASS: stopped restart, resume and active/inactive deletion preserve ownership and clean up native windows")

        restored.selectVideo(video)
        try await wait("external video selected") { !restored.isLoading && restored.hasWallpaper && restored.isPlaying }
        var externalOptions = restored.currentWallpaperOptions
        externalOptions.usesGlobalPowerRules = false
        externalOptions.animateOnExternalPower = false
        let savedExternal = await restored.updateCurrentWallpaper(options: externalOptions, expectedURL: video)
        try await wait("external override becomes static") { !restored.isPlaying }
        try require(savedExternal && preferences.wallpaperEnabled && restored.activeWallpaperID == nil,
                    "The external custom policy was not saved for enabled wallpaper.")
        restored.shutDown()
        let externalRestart = makeModel(WallpaperLibraryController(library: storage))
        defer { externalRestart.shutDown() }
        externalRestart.restore()
        try await wait("enabled external wallpaper restored") { !externalRestart.isLoading && externalRestart.hasWallpaper }
        try require(!externalRestart.isPlaying && externalRestart.currentWallpaperOptions == externalOptions
                    && externalRestart.globalPowerRules == globalRules,
                    "Enabled external restore lost its individual power settings.")
        print("PASS: an external wallpaper keeps its saved exception across an enabled restart")

        // An updater restart preserves a live session independently of ordinary launch settings.
        preferences.restoreOnLaunch = false
        externalRestart.togglePlayback()
        try await wait("temporary animation before updater restart") { externalRestart.isPlaying }
        externalRestart.togglePlayback()
        let pausedSnapshot = UpdatePlaybackSnapshot(wallpaperWasActive: externalRestart.hasWallpaper,
            userPaused: externalRestart.userPaused, temporarilyAnimating: externalRestart.isTemporarilyAnimating,
            powerSource: externalRestart.powerSource.rawValue, windowWasVisible: false)
        externalRestart.shutDown()
        let updateRestart = makeModel(WallpaperLibraryController(library: storage))
        defer { updateRestart.shutDown() }
        updateRestart.restore(afterUpdate: pausedSnapshot)
        try await wait("paused wallpaper restored by updater") { !updateRestart.isLoading && updateRestart.hasWallpaper }
        try require(updateRestart.userPaused && !updateRestart.isPlaying && updateRestart.isTemporarilyAnimating,
                    "Updater restart lost the manual pause or temporary animation choice.")
        try require(!preferences.restoreOnLaunch && updateRestart.currentWallpaperOptions == externalOptions,
                    "Updater restart changed the launch preference or wallpaper settings.")
        updateRestart.togglePlayback()
        try await wait("resuming updater-restored wallpaper") { updateRestart.isPlaying }
        updateRestart.stop()
        let stoppedSnapshot = UpdatePlaybackSnapshot(wallpaperWasActive: false, userPaused: false,
            temporarilyAnimating: false, powerSource: "external", windowWasVisible: false)
        updateRestart.shutDown()
        let stoppedUpdateRestart = makeModel(WallpaperLibraryController(library: storage))
        defer { stoppedUpdateRestart.shutDown() }
        stoppedUpdateRestart.restore(afterUpdate: stoppedSnapshot)
        try await wait("stopped updater session selection") { stoppedUpdateRestart.selectedURL != nil }
        try require(!stoppedUpdateRestart.hasWallpaper && !preferences.restoreOnLaunch,
                    "Updater restart unexpectedly enabled stopped wallpaper.")
        print("PASS: updater restart preserves pause, temporary animation, settings and stopped state")
    }

    private var wallpaperWindows: [NSWindow] { NSApp.windows.filter { $0.isVisible && $0.level.rawValue < NSWindow.Level.normal.rawValue } }
    private var desktopWindows: [NSWindow] { wallpaperWindows.filter { layer($0) != nil } }
    private func layer(_ window: NSWindow) -> AVPlayerLayer? { window.contentView?.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first }
    private func player(_ window: NSWindow) -> AVPlayer? { layer(window)?.player }
    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ProbeFailure(message: message) }
    }
    private func wait(_ description: String, condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() {
            guard Date() < deadline else { throw ProbeFailure(message: "Timed out: \(description)") }
            try await Task.sleep(for: .milliseconds(80))
        }
    }
}

@MainActor private final class ProbePower: PowerSourceMonitoring {
    var source: PowerSource { .external }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { Just(.external).eraseToAnyPublisher() }
}
@MainActor private final class ProbeSync: SystemWallpaperSyncing {
    private(set) var calls = 0
    func synchronize(image: CGImage, name: String, target: DisplayTarget, scaling: VideoScaling) async throws { calls += 1 }
}
@MainActor private final class ProbeLogin: LoginItemServicing {
    private(set) var calls = 0
    var status: LoginItemStatus { .disabled }
    func register() throws { calls += 1; throw ProbeFailure(message: "Unexpected login registration") }
    func unregister() throws { calls += 1; throw ProbeFailure(message: "Unexpected login unregistration") }
    func openSystemSettings() { calls += 1 }
}
