import AppKit
import AVFoundation
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
                print("PASS: native playback, desktop windows, pause policy, invalid input, cancellation, settings, cleanup and UI rendering")
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
        let model = WallpaperModel(preferences: WallpaperPreferences(defaults: defaults))
        model.pauseInLowPowerMode = false
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
            try require((window.contentView?.layer as? AVPlayerLayer)?.player?.isMuted == true,
                        "Wallpaper must start without audio.")
        }
        guard let player = desktopWindows.first?.contentView?.layer as? AVPlayerLayer,
              let queue = player.player else {
            throw SmokeFailure(message: "Desktop window has no AVPlayerLayer/player.")
        }
        let initialTime = queue.currentTime().seconds
        try await wait("advancing video frames", timeout: 5) {
            let current = queue.currentTime().seconds
            return current.isFinite && abs(current - initialTime) > 0.15
        }
        try await capture(model, to: output.appendingPathComponent("loaded.png"))
        print("PASS: real video advances, thumbnail is ready, all screen windows are interactive-safe")

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
        try require(!model.hasWallpaper && !model.isLoading && desktopWindows.isEmpty,
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
        try require((desktopWindows.first?.contentView?.layer as? AVPlayerLayer)?.videoGravity == .resizeAspect,
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
            try require((window.contentView?.layer as? AVPlayerLayer)?.videoGravity == .resizeAspectFill,
                        "Fill scaling was not applied to every screen.")
        }
        model.shutDown()
        try await settle()
        try require(!model.hasWallpaper && !model.isPlaying && desktopWindows.isEmpty,
                    "Shutdown left wallpaper windows or playback active.")
    }

    private var desktopWindows: [NSWindow] {
        let level = Int(CGWindowLevelForKey(.desktopWindow)) + 1
        return NSApp.windows.filter { $0.isVisible && $0.level.rawValue == level }
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
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 720)
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
