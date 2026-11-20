import AppKit
@preconcurrency import AVFoundation
import ScreenSaver

/// Loads both exports into one process. Windows remain unordered; this never
/// installs a saver, starts ScreenSaverEngine, or changes system preferences.
@main
enum TwoScreenSaverProbe {
    @MainActor
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw PairProbeFailure("Usage: screensaver-pair-probe <static.saver> <animated.saver>")
            }
            _ = NSApplication.shared
            let first = try Fixture(path: CommandLine.arguments[1], animated: false)
            let second = try Fixture(path: CommandLine.arguments[2], animated: true)
            try require(first.url != second.url, "Provide two distinct exported bundles.")
            try require(first.bundle.bundleIdentifier != second.bundle.bundleIdentifier,
                        "The variants still share a bundle identifier.")
            try require(ObjectIdentifier(first.type) != ObjectIdentifier(second.type),
                        "The variants resolved to the same principal class.")
            try require(first.configuration.scaling != second.configuration.scaling,
                        "Use different scaling settings (fit/fill) to detect shared configuration.")
            try require(first.posterPixels != second.posterPixels,
                        "Use visibly different poster images to detect shared resource lookup.")
            try await verify([first, second])
            print("PASS: two distinct saver classes, own video/poster/configuration, four independent views, stop/restart isolation, silent playback, no visible windows")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    private static func verify(_ fixtures: [Fixture]) async throws {
        var instances: [Instance] = []
        defer {
            instances.forEach { $0.view.stopAnimation() }
            instances.forEach { $0.window.close() }
            // Registered Objective-C classes remain live for the process lifetime.
            // Never unload either image while its method implementations exist.
            withExtendedLifetime(fixtures) {}
        }
        for index in fixtures.indices {
            for preview in [true, false] {
                let instance = try Instance(fixture: fixtures[index], fixtureIndex: index, preview: preview)
                instances.append(instance)
                try require(instance.video.player == nil, "Initializing a view started playback before startAnimation.")
                try verifyResources(instance, fixture: fixtures[index])
                try require(!instance.poster.isHidden, "Cold initialization did not display this variant's poster.")
            }
        }
        try require(instances.allSatisfy { !$0.window.isVisible }, "A test window unexpectedly became visible.")

        // Cancel the first async asset load in every instance before restarting.
        instances.forEach { $0.view.startAnimation(); $0.view.stopAnimation() }
        try await Task.sleep(for: .milliseconds(350))
        try require(instances.allSatisfy { $0.video.player == nil }, "A cancelled load resurrected a player.")
        instances.forEach { $0.view.startAnimation() }
        try await waitForPlayback(instances, fixtures: fixtures)
        try verifyAll(instances, fixtures: fixtures)
        let initialPlayers = try players(instances)
        try require(Set(initialPlayers.map(ObjectIdentifier.init)).count == 4, "The four views share one or more players.")
        try await verifyProgress(instances.filter { $0.fixtureIndex == 1 })

        instances.forEach { $0.view.startAnimation() }
        try require(zip(initialPlayers, instances).allSatisfy { $0 === $1.video.player },
                    "Repeated startAnimation replaced an active player.")

        let a = instances.filter { $0.fixtureIndex == 0 }
        let b = instances.filter { $0.fixtureIndex == 1 }
        let aPlayers = try players(a)
        let bPlayers = try players(b)
        a.forEach { $0.view.stopAnimation(); $0.view.animateOneFrame() }
        try await Task.sleep(for: .milliseconds(350))
        try verifyStopped(a, oldPlayers: aPlayers)
        try require(zip(bPlayers, b).allSatisfy { $0 === $1.video.player && $1.view.isAnimating },
                    "Stopping variant A replaced or stopped a variant B player.")
        try await verifyProgress(b)
        for instance in b { try verifyResources(instance, fixture: fixtures[1]) }

        a.forEach { $0.view.startAnimation() }
        try await waitForPlayback(instances, fixtures: fixtures)
        try require(zip(aPlayers, a).allSatisfy { $0 !== $1.video.player }, "Restarted A reused its torn-down players.")
        let restartedA = try players(a)
        b.forEach { $0.view.stopAnimation(); $0.view.animateOneFrame() }
        try await Task.sleep(for: .milliseconds(350))
        try verifyStopped(b, oldPlayers: bPlayers)
        try require(zip(restartedA, a).allSatisfy { $0 === $1.video.player && $1.view.isAnimating },
                    "Stopping variant B replaced or stopped a variant A player.")
        for instance in a {
            try verifyResources(instance, fixture: fixtures[0])
            try require(instance.video.player?.rate == 0 && !instance.poster.isHidden,
                        "Variant A lost its static policy when variant B stopped.")
        }

        b.forEach { $0.view.startAnimation() }
        try await waitForPlayback(instances, fixtures: fixtures)
        try verifyAll(instances, fixtures: fixtures)
        let restartedPlayers = try players(instances)
        instances.forEach { $0.view.stopAnimation(); $0.view.animateOneFrame() }
        try await Task.sleep(for: .milliseconds(350))
        try verifyStopped(instances, oldPlayers: initialPlayers + restartedPlayers)
        try require(instances.allSatisfy { !$0.window.isVisible }, "A test window became visible during the probe.")
    }

    @MainActor
    private static func verifyAll(_ instances: [Instance], fixtures: [Fixture]) throws {
        for instance in instances {
            let fixture = fixtures[instance.fixtureIndex]
            try verifyResources(instance, fixture: fixture)
            guard let player = instance.video.player,
                  let asset = player.currentItem?.asset as? AVURLAsset else {
                throw PairProbeFailure("A running saver does not expose its local AVURLAsset.")
            }
            try require(asset.url.resolvingSymlinksInPath().standardizedFileURL == fixture.videoURL,
                        "\(fixture.name) loaded another variant's video: \(asset.url.path)")
            if let queue = player as? AVQueuePlayer {
                for item in queue.items() {
                    guard let asset = item.asset as? AVURLAsset else { throw PairProbeFailure("A queued item lost its local asset.") }
                    try require(asset.url.resolvingSymlinksInPath().standardizedFileURL == fixture.videoURL,
                                "A looping item belongs to another variant.")
                }
            }
            try require(player.isMuted && player.volume == 0, "A saver can emit sound.")
            try require(!player.preventsDisplaySleepDuringVideoPlayback, "A saver prevents display sleep.")
            if !fixture.animated {
                try require(player.rate == 0 && !instance.poster.isHidden, "A static variant is animating or hiding its poster.")
            }
            try require(!hasFallback(instance.view), "A valid fixture displayed an error message.")
        }
    }

    @MainActor
    private static func verifyResources(_ instance: Instance, fixture: Fixture) throws {
        let gravity: AVLayerVideoGravity = fixture.configuration.scaling == "fit" ? .resizeAspect : .resizeAspectFill
        let posterGravity: CALayerContentsGravity = fixture.configuration.scaling == "fit" ? .resizeAspect : .resizeAspectFill
        try require(instance.video.videoGravity == gravity && instance.poster.contentsGravity == posterGravity,
                    "\(fixture.name) uses another variant's scaling configuration.")
        guard let contents = instance.poster.contents,
              CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else {
            throw PairProbeFailure("\(fixture.name) has no decoded poster image.")
        }
        let pixels = try normalizedPixels(contents as! CGImage)
        try require(pixels == fixture.posterPixels, "\(fixture.name) displays another variant's poster.")
    }

    @MainActor
    private static func waitForPlayback(_ instances: [Instance], fixtures: [Fixture]) async throws {
        try await eventually("The four views did not reach their independent static/animated states.") {
            instances.allSatisfy { instance in
                guard let player = instance.video.player, player.status == .readyToPlay,
                      player.currentItem?.status == .readyToPlay else { return false }
                return fixtures[instance.fixtureIndex].animated
                    ? player.rate > 0 && player.timeControlStatus == .playing
                    : player.rate == 0
            }
        }
        instances.forEach { $0.view.animateOneFrame() }
    }

    @MainActor
    private static func verifyProgress(_ instances: [Instance]) async throws {
        let oldPlayers = try players(instances)
        let initialTimes = oldPlayers.map { $0.currentTime().seconds }
        try await eventually("Variant B's playback stopped progressing while another variant changed state.") {
            zip(oldPlayers, initialTimes).allSatisfy { player, previous in
                let current = player.currentTime().seconds
                return player.timeControlStatus == .playing && current.isFinite && previous.isFinite
                    && abs(current - previous) > 0.02
            }
        }
    }

    @MainActor
    private static func players(_ instances: [Instance]) throws -> [AVPlayer] {
        try instances.map {
            guard let player = $0.video.player else { throw PairProbeFailure("A saver has no player.") }
            return player
        }
    }

    @MainActor
    private static func verifyStopped(_ instances: [Instance], oldPlayers: [AVPlayer]) throws {
        try require(instances.allSatisfy { !$0.view.isAnimating && $0.video.player == nil },
                    "A stopped view retains an animation timer or attached player.")
        for player in oldPlayers {
            try require(player.rate == 0 && player.currentItem == nil, "A stopped player retains or plays media.")
            if let queue = player as? AVQueuePlayer { try require(queue.items().isEmpty, "A stopped loop still owns items.") }
        }
    }

    @MainActor
    private static func hasFallback(_ view: ScreenSaverView) -> Bool {
        (view.layer?.sublayers ?? []).contains {
            guard let text = $0 as? CATextLayer, !text.isHidden else { return false }
            if let string = text.string as? NSAttributedString { return !string.string.isEmpty }
            return !(text.string as? String ?? "").isEmpty
        }
    }

    @MainActor
    private static func normalizedPixels(_ image: CGImage) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32,
                                          bitsPerComponent: 8, bytesPerRow: 128,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        try require(success, "Could not normalize the fixture poster for comparison.")
        return Data(pixels)
    }

    @MainActor
    private static func eventually(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { throw PairProbeFailure(message) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw PairProbeFailure(message) }
    }

    @MainActor
    private struct Fixture {
        let url: URL
        let bundle: Bundle
        let type: ScreenSaverView.Type
        let configuration: Configuration
        let videoURL: URL
        let posterPixels: Data
        let animated: Bool
        var name: String { url.lastPathComponent }

        init(path: String, animated: Bool) throws {
            url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier, !identifier.isEmpty,
                  let declaredClass = bundle.infoDictionary?["NSPrincipalClass"] as? String,
                  let type = bundle.principalClass as? ScreenSaverView.Type,
                  NSStringFromClass(type) == declaredClass else {
                throw PairProbeFailure("Could not load the declared ScreenSaverView principal class: \(path)")
            }
            self.bundle = bundle
            self.type = type
            self.animated = animated
            let resources = url.appendingPathComponent("Contents/Resources")
            configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: resources.appendingPathComponent("configuration.json")))
            try require(configuration.version == 1 && ["video.mp4", "video.mov"].contains(configuration.videoFileName)
                        && ["fill", "fit"].contains(configuration.scaling), "The fixture has an unsupported configuration.")
            try require(configuration.animateOnBattery == animated && configuration.animateOnExternalPower == animated,
                        "The first fixture must disable both power sources; the second must enable both.")
            if animated { try require(!configuration.pauseInLowPowerMode, "Disable low-power pause in the animated fixture.") }
            videoURL = resources.appendingPathComponent(configuration.videoFileName).resolvingSymlinksInPath().standardizedFileURL
            guard let image = NSImage(contentsOf: resources.appendingPathComponent("poster.jpg")),
                  let decoded = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw PairProbeFailure("The fixture poster cannot be decoded.")
            }
            posterPixels = try normalizedPixels(decoded)
            print("Loaded \(identifier): principalClass=\(declaredClass), classNamed=\(bundle.classNamed(declaredClass).map(NSStringFromClass) ?? "nil"), animated=\(animated), scaling=\(configuration.scaling)")
        }
    }

    @MainActor
    private struct Instance {
        let fixtureIndex: Int
        let view: ScreenSaverView
        let window: NSWindow
        let video: AVPlayerLayer
        let poster: CALayer

        init(fixture: Fixture, fixtureIndex: Int, preview: Bool) throws {
            self.fixtureIndex = fixtureIndex
            let size = preview ? NSSize(width: 360, height: 240) : NSSize(width: 640, height: 360)
            let frame = NSRect(origin: .zero, size: size)
            guard let view = fixture.type.init(frame: frame, isPreview: preview) else {
                throw PairProbeFailure("Could not instantiate \(fixture.name).")
            }
            self.view = view
            try require(view.isPreview == preview, "The ScreenSaver framework preview flag was not preserved.")
            window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let layers = view.layer?.sublayers ?? []
            guard let video = layers.first(where: { $0.name == "MyWallpaper.video" }) as? AVPlayerLayer,
                  let poster = layers.first(where: { $0.name == "MyWallpaper.poster" }) else {
                window.close()
                throw PairProbeFailure("The view is missing its named video/poster layers.")
            }
            self.video = video
            self.poster = poster
        }
    }

    private struct Configuration: Decodable {
        let version: Int
        let videoFileName: String
        let scaling: String
        let animateOnBattery: Bool
        let animateOnExternalPower: Bool
        let pauseInLowPowerMode: Bool
    }
}

private struct PairProbeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
