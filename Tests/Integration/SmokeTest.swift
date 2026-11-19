import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Runs against the real AppKit/AVFoundation stack with isolated app preferences.
/// This temporarily displays the supplied video on the desktop and then removes it.
@main
enum SmokeTest {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count >= 2 else {
            print("Usage: smoke-test <local-video> [output-directory]")
            exit(2)
        }
        let app = NSApplication.shared
        let delegate = SmokeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private struct SmokeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private final class SmokeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await runChecks()
                print("PASS: native playback, desktop windows, pause policy, occlusion, restoration, invalid input, cancellation, settings, cleanup and UI rendering")
                exit(0)
            } catch {
                print("FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    private func runChecks() async throws {
        let video = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 2
                         ? CommandLine.arguments[2] : ".build/verification", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try require(FileManager.default.fileExists(atPath: video.path), "Video file does not exist: \(video.path)")
        try require(!NSScreen.screens.isEmpty, "This smoke test needs an active macOS graphical session.")

        let domain = "MyWallpaperSmokeTest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw SmokeFailure(message: "Unable to create isolated preferences.")
        }
        let model = WallpaperModel(preferences: WallpaperPreferences(defaults: defaults),
                                   powerMonitor: SmokePowerMonitor(.external))
        try require(model.pauseWhenCovered, "Smart pause should be enabled by default.")
        model.pauseInLowPowerMode = false
        // Exercise ordinary playback independently of the user's currently open windows.
        // Actual WindowServer occlusion is checked separately below.
        model.pauseWhenCovered = false
        defer {
            model.shutDown()
            defaults.removePersistentDomain(forName: domain)
        }

        try await capture(model, to: output.appendingPathComponent("empty.png"))
        model.selectVideo(video)
        try await wait("video playback and thumbnail; \(video.lastPathComponent)") {
            model.hasWallpaper && model.isPlaying && model.thumbnail != nil && !model.isLoading
        }
        try require(model.errorMessage == nil, model.errorMessage ?? "Unexpected playback error.")
        try require(model.selectedURL == video, "Selected video did not become active.")
        try require(desktopWindows.count == NSScreen.screens.count, "Expected one wallpaper window per screen.")
        for window in desktopWindows {
            try require(window.ignoresMouseEvents, "Wallpaper intercepts desktop mouse events.")
            try require(!window.canBecomeKey && !window.canBecomeMain, "Wallpaper can steal keyboard focus.")
            try require(window.collectionBehavior.contains(.canJoinAllSpaces), "Wallpaper is not configured for Spaces.")
            try require(player(in: window)?.isMuted == true,
                        "Wallpaper must start without audio.")
        }
        guard let window = desktopWindows.first, let queue = player(in: window) else {
            throw SmokeFailure(message: "Desktop window has no AVPlayerLayer/player.")
        }
        let initialTime = queue.currentTime().seconds
        try await wait("advancing video frames", timeout: 5) {
            let current = queue.currentTime().seconds
            return current.isFinite && abs(current - initialTime) > 0.15
        }
        try await capture(model, to: output.appendingPathComponent("loaded.png"))
        print("PASS: real video advances, thumbnail is ready, all screen windows are interactive-safe")
        try await checkScreenChangesAndMinimization(model)

        model.togglePlayback()
        try await wait("manual pause") { !model.isPlaying }
        postWorkspace(NSWorkspace.screensDidSleepNotification)
        try await settle()
        postWorkspace(NSWorkspace.screensDidWakeNotification)
        try await settle()
        try require(model.userPaused && !model.isPlaying, "Screen wake undid the user's manual pause.")
        model.togglePlayback()
        try await wait("manual resume") { model.isPlaying }

        postWorkspace(NSWorkspace.screensDidSleepNotification)
        try await wait("automatic display-sleep pause") { !model.isPlaying }
        postWorkspace(NSWorkspace.screensDidWakeNotification)
        try await wait("automatic display-wake resume") { model.isPlaying }
        print("PASS: display sleep pauses playback and wake preserves manual intent")

        let invalid = output.appendingPathComponent("invalid-video.txt")
        try Data("This is text, not a video.".utf8).write(to: invalid)
        model.selectVideo(invalid)
        try await wait("invalid file rejection") { !model.isLoading && model.errorMessage != nil }
        try require(model.hasWallpaper && model.selectedURL == video && model.isPlaying,
                    "An invalid replacement disrupted the previously valid wallpaper.")
        model.errorMessage = nil

        model.selectVideo(video)
        await Task.yield()
        model.stop()
        try await settle()
        try require(!model.hasWallpaper && !model.isLoading && wallpaperWindows.isEmpty,
                    "Stop during loading allowed stale playback/windows to return.")
        model.togglePlayback()
        try await wait("restart after stop") { model.hasWallpaper && model.isPlaying }
        print("PASS: invalid files preserve playback; cancellation and restart work")

        model.togglePlayback()
        try await wait("pause before reconfiguration") { !model.isPlaying }
        model.target = .main
        model.scaling = .fit
        try await settle()
        try require(desktopWindows.count == 1, "Primary-screen mode should create exactly one wallpaper window.")
        try require(desktopWindows.first.flatMap { videoLayer(in: $0) }?.videoGravity == .resizeAspect,
                    "Fit scaling was not applied to the player layer.")
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try await settle()
        try require(!model.isPlaying && model.userPaused, "Display reconfiguration undid manual pause.")
        model.target = .all
        model.scaling = .fill
        model.togglePlayback()
        try await wait("resume after display reconfiguration") {
            model.isPlaying && self.desktopWindows.count == NSScreen.screens.count
        }
        for window in desktopWindows {
            try require(videoLayer(in: window)?.videoGravity == .resizeAspectFill,
                        "Fill scaling was not applied to every screen.")
        }
        try await checkOcclusion(model)
        model.shutDown()
        try await settle()
        try require(!model.hasWallpaper && !model.isPlaying && wallpaperWindows.isEmpty,
                    "Shutdown left wallpaper windows or playback active.")
        try await checkRestoration(video: video, defaults: defaults)
        try await checkPowerProfiles(video: video)
    }

    private var desktopWindows: [NSWindow] {
        let level = Int(CGWindowLevelForKey(.desktopWindow)) + 1
        return NSApp.windows.filter {
            $0.isVisible && $0.level.rawValue == level && videoLayer(in: $0) != nil
        }
    }

    /// Includes any non-interactive visibility tracking windows, but only in this test process.
    private var wallpaperWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.level.rawValue < NSWindow.Level.normal.rawValue }
    }

    private func checkScreenChangesAndMinimization(_ model: WallpaperModel) async throws {
        model.togglePlayback()
        try await wait("pause before screen-change regression") { !model.isPlaying }
        let windows = desktopWindows
        let windowIDs = Set(wallpaperWindows.map(ObjectIdentifier.init))
        var snapshots: [(window: NSWindow, player: AVPlayer, item: AVPlayerItem, position: Double)] = []
        for window in windows {
            guard let player = player(in: window), let item = player.currentItem else {
                throw SmokeFailure(message: "Missing player before screen-change regression.")
            }
            let duration = try await item.asset.load(.duration)
            // A position inside the supplied clip detects a reset without requiring
            // a long fixture or confusing a normal loop boundary with a restart.
            let finished = await player.seek(to: CMTimeMultiplyByFloat64(duration, multiplier: 0.5),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
            try require(finished, "Could not seek before screen-change regression.")
            snapshots.append((window, player, item, player.currentTime().seconds))
        }

        func checkPreserved(_ description: String, paused: Bool) throws {
            try require(Set(wallpaperWindows.map(ObjectIdentifier.init)) == windowIDs,
                        "Wallpaper windows were replaced during \(description).")
            for snapshot in snapshots {
                try require(player(in: snapshot.window) === snapshot.player,
                            "Wallpaper player was replaced during \(description).")
                try require(snapshot.player.isMuted, "Screen changes unexpectedly enabled audio.")
                if paused {
                    try require(snapshot.player.currentItem === snapshot.item
                                && snapshot.position.isFinite
                                && abs(snapshot.player.currentTime().seconds - snapshot.position) < 0.025,
                                "Paused playback position was reset during \(description).")
                    try require(snapshot.player.rate == 0 && model.userPaused && !model.isPlaying,
                                "Manual pause was lost during \(description).")
                }
            }
        }

        for _ in 0..<3 {
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
            try await settle()
            try checkPreserved("repeated screen notifications", paused: true)
        }

        let screen = NSScreen.screens[0]
        let control = NSWindow(
            contentRect: NSRect(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.maxY - 200,
                                width: 280, height: 160),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        control.title = "MyWallpaper — проверка сворачивания"
        control.isReleasedWhenClosed = false
        control.ignoresMouseEvents = true
        defer { control.orderOut(nil); control.close() }
        control.orderFrontRegardless()

        for paused in [true, false] {
            if !paused {
                model.togglePlayback()
                try await wait("resume before minimizing") { model.isPlaying }
                NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
                try await settle()
                try checkPreserved("screen notification while playing", paused: false)
            }
            control.performMiniaturize(nil)
            try await wait("native window minimization", timeout: 5) { control.isMiniaturized }
            try await settle()
            try checkPreserved("native window minimization", paused: paused)

            control.deminiaturize(nil)
            try await wait("native window restoration", timeout: 5) { !control.isMiniaturized && control.isVisible }
            try await settle()
            try checkPreserved("native window restoration", paused: paused)
        }

        let resumedPlayer = snapshots[0].player
        let time = resumedPlayer.currentTime()
        let item = resumedPlayer.currentItem
        try await wait("continued playback after restoring the window", timeout: 5) {
            resumedPlayer.currentItem !== item || CMTimeCompare(resumedPlayer.currentTime(), time) != 0
        }
        try require(model.isPlaying, "Restoring a window stopped active playback.")
        print("PASS: screen notifications and native minimize/restore preserve players, position and manual pause")
    }

    private func checkOcclusion(_ model: WallpaperModel) async throws {
        let screens = NSScreen.screens
        var covers: [NSWindow] = []
        defer {
            covers.forEach { $0.orderOut(nil); $0.close() }
            model.pauseWhenCovered = false
        }

        // Another MyWallpaper process may be running. Reorder only this test's own
        // surfaces within their existing levels; leave the user's app and settings alone.
        for window in wallpaperWindows.sorted(by: { $0.level.rawValue < $1.level.rawValue }) {
            window.orderFrontRegardless()
        }
        model.pauseWhenCovered = true
        try await wait("uncovered test wallpaper (other apps must leave some desktop visible)", timeout: 8) {
            model.isPlaying && !model.isPausedForOcclusion
        }

        // Neither partial window fills a screen. Their overlapping union does.
        let leftCovers = screens.map { screen in
            var frame = screen.visibleFrame
            frame.size.width *= 0.6
            return makeCover(frame: frame)
        }
        covers += leftCovers
        leftCovers.forEach { $0.orderFrontRegardless() }
        try await settle()
        try require(model.isPlaying && !model.isPausedForOcclusion,
                    "A partial cover paused every display; check for another fully covering app window.")

        let rightCovers = screens.map { screen in
            var frame = screen.visibleFrame
            frame.origin.x += frame.width * 0.4
            frame.size.width *= 0.6
            return makeCover(frame: frame)
        }
        covers += rightCovers
        rightCovers.forEach { $0.orderFrontRegardless() }
        try await wait("pause under the union of overlapping opaque windows", timeout: 8) {
            model.isPausedForOcclusion && !model.isPlaying
        }
        try require(desktopWindows.allSatisfy { self.player(in: $0)?.rate == 0 },
                    "A covered display continues decoding/playing.")

        model.pauseWhenCovered = false
        try await wait("playback with smart pause disabled while still covered") {
            model.isPlaying && !model.isPausedForOcclusion
        }
        model.pauseWhenCovered = true
        try await wait("smart pause re-enabled while still covered") {
            model.isPausedForOcclusion && !model.isPlaying
        }

        model.togglePlayback()
        try require(model.userPaused, "Manual pause did not record the user's intent while covered.")
        leftCovers.forEach { $0.orderOut(nil) }
        rightCovers.forEach { $0.orderOut(nil) }
        try await settle()
        try require(!model.isPlaying && model.userPaused && !model.isPausedForOcclusion,
                    "Uncovering a wallpaper undid manual pause or reported the wrong pause reason.")
        model.togglePlayback()
        try await wait("manual resume after uncovering") { model.isPlaying }

        // Cover only the usable desktop (the geometry of a normal maximized window),
        // leaving the menu bar and Dock outside the cover.
        // A titled window with rounded/translucent system chrome is the actual
        // regression: AppKit can keep reporting the desktop tracker as visible.
        let fullCovers = screens.map { makeCover(frame: $0.visibleFrame, titled: true) }
        covers += fullCovers
        fullCovers.forEach { $0.orderFrontRegardless() }
        try await wait("pause under maximized opaque windows", timeout: 8) {
            model.isPausedForOcclusion && !model.isPlaying
        }
        if screens.count > 1 {
            fullCovers[0].orderOut(nil)
            try await wait("independent playback on the uncovered display") {
                model.isPlaying && !model.isPausedForOcclusion
                    && model.occludedDisplayCount == screens.count - 1
            }
            try require(model.status == "Воспроизведение: 1 из \(screens.count) экранов",
                        "Mixed display playback must not claim that every wallpaper is playing.")
            for window in desktopWindows where window.frame != screens[0].frame {
                try require(player(in: window)?.rate == 0, "Uncovering one screen resumed another covered screen.")
            }
        }
        fullCovers.forEach { $0.orderOut(nil) }
        try await wait("resume after removing all opaque covers") {
            !model.isPausedForOcclusion && self.desktopWindows.allSatisfy {
                self.player(in: $0)?.timeControlStatus == .playing
            }
        }
        print("PASS: partial/combined/maximized covers, setting off and manual pause preservation (\(screens.count) display(s))")
    }

    private func checkRestoration(video: URL, defaults: UserDefaults) async throws {
        let preferences = WallpaperPreferences(defaults: defaults)
        try require(preferences.wallpaperEnabled && preferences.restoreOnLaunch,
                    "Quitting should preserve the enabled wallpaper for the next launch.")

        do {
            let restored = WallpaperModel(preferences: preferences, powerMonitor: SmokePowerMonitor(.external))
            defer { restored.shutDown() }
            restored.restore()
            try await wait("automatic playback restored from the saved bookmark") {
                restored.hasWallpaper && restored.isPlaying && restored.thumbnail != nil && !restored.isLoading
            }
            try require(restored.selectedURL?.standardizedFileURL == video,
                        "Restoration selected a different video.")
            try require(!restored.pauseWhenCovered, "Restoration lost the disabled smart-pause preference.")
            restored.togglePlayback()
            try await wait("pause before simulated quit") { !restored.isPlaying && restored.userPaused }
        }
        try require(wallpaperWindows.isEmpty, "A restored model left wallpaper windows on shutdown.")

        do {
            let paused = WallpaperModel(preferences: preferences, powerMonitor: SmokePowerMonitor(.external))
            defer { paused.shutDown() }
            paused.restore()
            try await wait("restore of a manually paused wallpaper") {
                paused.hasWallpaper && paused.thumbnail != nil && !paused.isLoading
            }
            try require(paused.userPaused && !paused.isPlaying,
                        "Restoration resumed a manually paused wallpaper.")
            paused.stop()
        }

        do {
            let stopped = WallpaperModel(preferences: preferences, powerMonitor: SmokePowerMonitor(.external))
            defer { stopped.shutDown() }
            stopped.restore()
            try await wait("remembered video after Stop") { stopped.thumbnail != nil }
            try require(stopped.selectedURL?.standardizedFileURL == video && !stopped.hasWallpaper
                        && !stopped.isPlaying && wallpaperWindows.isEmpty,
                        "Restarting after Stop should remember the file without enabling it.")
        }

        preferences.wallpaperEnabled = true
        preferences.userPaused = false
        preferences.restoreOnLaunch = false
        do {
            let disabled = WallpaperModel(preferences: preferences, powerMonitor: SmokePowerMonitor(.external))
            defer { disabled.shutDown() }
            disabled.restore()
            try await wait("remembered video with launch restoration disabled") { disabled.thumbnail != nil }
            try require(disabled.selectedURL?.standardizedFileURL == video && !disabled.hasWallpaper
                        && !disabled.isPlaying && wallpaperWindows.isEmpty,
                        "Disabling launch restoration still created a wallpaper.")
        }
        print("PASS: bookmark restore, preserved manual pause, stopped state and restoration disabled")
    }

    private func player(in window: NSWindow) -> AVPlayer? {
        videoLayer(in: window)?.player
    }

    private func videoLayer(in window: NSWindow) -> AVPlayerLayer? {
        namedLayer("wallpaper.video", in: window.contentView?.layer) as? AVPlayerLayer
    }

    private func namedLayer(_ name: String, in layer: CALayer?) -> CALayer? {
        guard let layer else { return nil }
        if layer.name == name { return layer }
        for child in layer.sublayers ?? [] {
            if let match = namedLayer(name, in: child) { return match }
        }
        return nil
    }

    private func checkPowerProfiles(video: URL) async throws {
        let domain = "MyWallpaperPowerSmokeTest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw SmokeFailure(message: "Unable to create power-test preferences.")
        }
        let preferences = WallpaperPreferences(defaults: defaults)
        preferences.pauseInLowPowerMode = false
        preferences.pauseWhenCovered = false
        let monitor = SmokePowerMonitor(.battery)
        let model = WallpaperModel(preferences: preferences, powerMonitor: monitor)
        defer {
            model.shutDown()
            defaults.removePersistentDomain(forName: domain)
        }

        // No initial play/then-pause priming: a cold battery launch must already
        // contain a real video poster while all players remain stopped.
        model.selectVideo(video)
        try await wait("cold battery wallpaper and poster") {
            model.hasWallpaper && model.thumbnail != nil && !model.isLoading
        }
        try require(!model.isPlaying && !model.userPaused && !model.animateOnBattery,
                    "Selecting a file on battery must preserve the default static profile.")
        try require(model.engine.posterImage != nil, "Cold static wallpaper has no decoded poster frame.")
        try require(desktopWindows.count == NSScreen.screens.count, "Cold static wallpaper is missing a screen.")
        for window in desktopWindows {
            guard let videoLayer = videoLayer(in: window),
                  let poster = namedLayer("wallpaper.poster", in: window.contentView?.layer) else {
                throw SmokeFailure(message: "The static/video compositor is missing a named layer.")
            }
            try require(poster.contents != nil, "A static wallpaper has no poster image contents.")
            try require((!poster.isHidden || videoLayer.isReadyForDisplay) && videoLayer.player?.rate == 0,
                        "Cold static mode either hides both frames or starts playing.")
        }
        try await requireStationaryPlayers("cold static wallpaper")

        let windowIDs = Set(desktopWindows.map(\.windowNumber))
        guard let first = desktopWindows.first, let queue = player(in: first) else {
            throw SmokeFailure(message: "Power test has no player.")
        }
        monitor.send(.external)
        try await wait("automatic animation after connecting external power") { model.isPlaying }
        let initialTime = queue.currentTime().seconds
        try await wait("advancing frame on external power", timeout: 5) {
            abs(queue.currentTime().seconds - initialTime) > 0.15
        }
        let beforeDisconnect = queue.currentTime().seconds
        monitor.send(.battery)
        try await wait("static frame after disconnecting external power") { !model.isPlaying }
        try require(Set(desktopWindows.map(\.windowNumber)) == windowIDs,
                    "Power changes rebuilt wallpaper windows instead of pausing existing players.")
        try require(abs(queue.currentTime().seconds - beforeDisconnect) < 0.1,
                    "Switching to battery reset the current video frame.")
        try await requireStationaryPlayers("last frame after switching to battery")

        model.togglePlayback()
        try await wait("explicit battery animation override") { model.isPlaying }
        try require(model.animateOnBattery && preferences.animateOnBattery && !model.userPaused,
                    "Explicit Play did not persist the battery-animation override.")
        model.animateOnExternalPower = false
        monitor.send(.external)
        try await wait("user-selected static mode on external power") { !model.isPlaying }
        monitor.send(.battery)
        try await wait("saved battery animation preference") { model.isPlaying }
        monitor.send(.unknown)
        try await wait("unknown source follows static external profile") { !model.isPlaying }

        model.togglePlayback()
        try await wait("explicit Play updates the external fallback profile") { model.isPlaying }
        try require(model.animateOnExternalPower && preferences.animateOnExternalPower,
                    "Explicit Play on an unknown source did not update the external profile.")
        model.togglePlayback()
        monitor.send(.battery)
        monitor.send(.external)
        try await settle()
        try require(model.userPaused && !model.isPlaying && preferences.userPaused,
                    "A power-source event cleared manual pause.")

        model.stop()
        model.animateOnBattery = false
        monitor.send(.battery)
        model.togglePlayback()
        try await wait("explicit Play of a stopped wallpaper on battery") { model.hasWallpaper && model.isPlaying }
        try require(model.animateOnBattery && preferences.animateOnBattery && !model.userPaused,
                    "Restarting a stopped wallpaper failed to opt the current profile into animation.")
        print("PASS: cold battery still frame, AC resume, last-frame retention, saved overrides and manual pause")
    }

    private func requireStationaryPlayers(_ description: String) async throws {
        let players = desktopWindows.compactMap { player(in: $0) }
        let positions = players.map { $0.currentTime().seconds }
        try await Task.sleep(for: .milliseconds(450))
        for (player, position) in zip(players, positions) {
            try require(position.isFinite && player.rate == 0
                        && abs(player.currentTime().seconds - position) < 0.025,
                        "Video time advanced during \(description).")
        }
    }

    private func makeCover(frame: NSRect, titled: Bool = false) -> NSWindow {
        let style: NSWindow.StyleMask = titled
            ? [.titled, .closable, .resizable, .fullSizeContentView] : .borderless
        let window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        if titled {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        window.setFrame(frame, display: false)
        window.level = .normal
        window.isOpaque = true
        window.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        return window
    }

    private func postWorkspace(_ name: Notification.Name) {
        NSWorkspace.shared.notificationCenter.post(name: name, object: NSWorkspace.shared)
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SmokeFailure(message: message) }
    }

    private func wait(_ description: String, timeout: TimeInterval = 20,
                      condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw SmokeFailure(message: "Timed out waiting for \(description).") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    private func capture(_ model: WallpaperModel, to url: URL) async throws {
        let bounds = NSRect(x: 0, y: 0, width: 940, height: 696)
        let hosting = NSHostingView(rootView: ControlView(model: model))
        hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Cache only this app's own view; never capture the user's screen or other applications.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        try await settle()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SmokeFailure(message: "Could not allocate a bitmap for \(url.lastPathComponent).")
        }
        hosting.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SmokeFailure(message: "Could not encode \(url.lastPathComponent).")
        }
        try data.write(to: url)
    }
}

@MainActor
private final class SmokePowerMonitor: PowerSourceMonitoring {
    private let subject: CurrentValueSubject<PowerSource, Never>
    var source: PowerSource { subject.value }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { subject.eraseToAnyPublisher() }

    init(_ source: PowerSource) { subject = CurrentValueSubject(source) }
    func send(_ source: PowerSource) { subject.send(source) }
}
