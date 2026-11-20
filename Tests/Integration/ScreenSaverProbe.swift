import AppKit
@preconcurrency import AVFoundation
import ScreenSaver

/// Loads one exported bundle per process. Never installs a saver, starts the
/// system screen-saver engine, locks the Mac, or orders a window onscreen.
@main
enum ScreenSaverProbe {
    @MainActor
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3,
                  let mode = ProbeMode(rawValue: CommandLine.arguments[2]) else {
                throw ProbeFailure(message: "Usage: screensaver-probe <exported.saver> <animated|static|invalid>")
            }
            _ = NSApplication.shared
            let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            try await verify(bundleURL: url, mode: mode)
            print("PASS: \(mode.rawValue) saver, simultaneous preview/full-size instances, stop/restart, silent playback, no visible windows")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    private static func verify(bundleURL: URL, mode: ProbeMode) async throws {
        try verifyPolicyFixture(bundleURL: bundleURL, mode: mode)
        guard let bundle = Bundle(url: bundleURL), bundle.load(),
              let type = bundle.principalClass as? ScreenSaverView.Type else {
            throw ProbeFailure(message: "Could not load the exported bundle's ScreenSaverView principal class.")
        }
        let cases: [(NSSize, Bool)] = [(NSSize(width: 360, height: 240), true),
                                     (NSSize(width: 640, height: 360), false)]
        var views: [ScreenSaverView] = []
        var windows: [NSWindow] = []
        defer {
            views.forEach { $0.stopAnimation() }
            windows.forEach { $0.close() }
            // Objective-C classes from a loaded bundle remain registered; do not
            // unload it or load another export with the same class in this process.
            withExtendedLifetime(bundle) {}
        }
        for (size, preview) in cases {
            let frame = NSRect(origin: .zero, size: size)
            guard let view = type.init(frame: frame, isPreview: preview) else {
                throw ProbeFailure(message: "Could not initialize a saver view.")
            }
            try require(view.isPreview == preview, "The system preview flag was not preserved.")
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            views.append(view)
            windows.append(window)
        }
        try require(windows.allSatisfy { !$0.isVisible }, "A test window unexpectedly became visible.")
        let layers = try views.map(playerLayer)
        try require(layers.allSatisfy { $0.player == nil }, "Initializing a view started a player before startAnimation.")

        // Exercise cancellation while validation is still awaiting AVFoundation.
        views.forEach { $0.startAnimation(); $0.stopAnimation() }
        try await Task.sleep(for: .milliseconds(350))
        try require(layers.allSatisfy { $0.player == nil }, "A canceled initial load resurrected a player.")

        views.forEach { $0.startAnimation() }
        if mode == .invalid {
            try await eventually("Invalid media/configuration did not show a useful fallback.") {
                views.allSatisfy { hasFallback($0) } && layers.allSatisfy { $0.player == nil }
            }
        } else {
            try await waitForPlayers(layers, mode: mode)
            try verifyAudio(layers)
            if mode == .static {
                try require(views.allSatisfy { hasVisiblePoster($0) }, "Static policy did not retain the exported poster.")
                // Exercise the same path as ScreenSaver's five-second policy timer.
                views.forEach { $0.animateOneFrame() }
                try await Task.sleep(for: .milliseconds(200))
                try require(layers.allSatisfy { $0.player?.rate == 0 }, "Static policy started playback on a timer tick.")
            }
        }

        let firstPlayers = layers.compactMap(\.player)
        views.forEach { $0.startAnimation() }
        try require(zip(firstPlayers, layers).allSatisfy { $0 === $1.player }, "Repeated startAnimation replaced an active player.")
        views.forEach { $0.stopAnimation() }
        try verifyStopped(views: views, layers: layers, oldPlayers: firstPlayers)
        try await Task.sleep(for: .milliseconds(350))
        try verifyStopped(views: views, layers: layers, oldPlayers: firstPlayers)

        // Both instances must restart independently after full teardown.
        views.forEach { $0.startAnimation() }
        if mode == .invalid {
            try await eventually("Invalid saver did not retain its fallback after restart.") {
                views.allSatisfy { hasFallback($0) } && layers.allSatisfy { $0.player == nil }
            }
        } else {
            try await waitForPlayers(layers, mode: mode)
            try verifyAudio(layers)
            try require(zip(firstPlayers, layers).allSatisfy { $0 !== $1.player }, "Restart reused a torn-down player.")
            views[0].stopAnimation()
            try require(layers[0].player == nil && layers[1].player != nil,
                        "Stopping preview also stopped the separate full-size instance.")
        }
        let lastPlayers = layers.compactMap(\.player)
        views.forEach { $0.stopAnimation(); $0.animateOneFrame() }
        try await Task.sleep(for: .milliseconds(350))
        try verifyStopped(views: views, layers: layers, oldPlayers: firstPlayers + lastPlayers)
        try require(windows.allSatisfy { !$0.isVisible }, "A test window became visible during playback.")
    }

    private static func verifyPolicyFixture(bundleURL: URL, mode: ProbeMode) throws {
        guard mode != .invalid else { return }
        let path = bundleURL.appendingPathComponent("Contents/Resources/configuration.json")
        guard let values = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else {
            throw ProbeFailure(message: "The fixture has no configuration object.")
        }
        let battery = values["animateOnBattery"] as? Bool ?? false
        let external = values["animateOnExternalPower"] as? Bool ?? true
        let lowPower = values["pauseInLowPowerMode"] as? Bool ?? true
        switch mode {
        case .animated:
            try require(battery && external && !lowPower,
                        "An animated fixture must explicitly enable both power sources and disable low-power pause.")
        case .static:
            try require(!battery && !external, "A static fixture must disable animation on both power sources.")
        case .invalid: break
        }
        print("Fixture policy: battery=\(battery), external=\(external), lowPowerPause=\(lowPower)")
    }

    @MainActor
    private static func playerLayer(_ view: ScreenSaverView) throws -> AVPlayerLayer {
        let layers = view.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer } ?? []
        try require(layers.count == 1, "Expected exactly one AVPlayerLayer per view.")
        return layers[0]
    }

    @MainActor
    private static func hasFallback(_ view: ScreenSaverView) -> Bool {
        (view.layer?.sublayers ?? []).contains { layer in
            guard let text = layer as? CATextLayer, !text.isHidden else { return false }
            if let value = text.string as? NSAttributedString { return !value.string.isEmpty }
            return !(text.string as? String ?? "").isEmpty
        }
    }

    @MainActor
    private static func hasVisiblePoster(_ view: ScreenSaverView) -> Bool {
        (view.layer?.sublayers ?? []).contains { !($0 is AVPlayerLayer) && !($0 is CATextLayer) && !$0.isHidden && $0.contents != nil }
    }

    @MainActor
    private static func waitForPlayers(_ layers: [AVPlayerLayer], mode: ProbeMode) async throws {
        try await eventually("Players did not reach the expected \(mode.rawValue) state.") {
            layers.allSatisfy { layer in
                guard let player = layer.player, player.status == .readyToPlay,
                      player.currentItem?.status == .readyToPlay else { return false }
                return mode == .animated ? player.rate > 0 && player.timeControlStatus == .playing : player.rate == 0
            }
        }
    }

    @MainActor
    private static func verifyAudio(_ layers: [AVPlayerLayer]) throws {
        for layer in layers {
            guard let player = layer.player else { throw ProbeFailure(message: "Missing player.") }
            try require(player.isMuted && player.volume == 0, "A saver player can emit audio.")
            try require(!player.preventsDisplaySleepDuringVideoPlayback, "A saver prevents display sleep.")
        }
        try require(layers[0].player !== layers[1].player, "Instances unexpectedly share a player.")
    }

    @MainActor
    private static func verifyStopped(views: [ScreenSaverView], layers: [AVPlayerLayer], oldPlayers: [AVPlayer]) throws {
        try require(views.allSatisfy { !$0.isAnimating }, "A stopped saver still owns an animation timer.")
        try require(layers.allSatisfy { $0.player == nil }, "A stopped layer retains a player.")
        for player in oldPlayers {
            try require(player.rate == 0 && player.currentItem == nil, "A stopped player retains or plays media.")
            if let queue = player as? AVQueuePlayer {
                try require(queue.items().isEmpty, "A stopped queue retains looping items.")
            }
        }
    }

    @MainActor
    private static func eventually(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { throw ProbeFailure(message: message) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
    }
}

private enum ProbeMode: String {
    case animated, `static`, invalid
}

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
