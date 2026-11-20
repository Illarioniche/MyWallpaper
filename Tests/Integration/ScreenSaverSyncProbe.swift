import AppKit
@preconcurrency import AVFoundation
import ScreenSaver

/// Runs the real plug-in in unordered windows. No installation, screen locking,
/// system preferences, or user-owned library is touched.
@main
enum ScreenSaverSyncProbe {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 4 else {
                throw SyncProbeFailure("Usage: screensaver-sync-probe <local-video> <template.saver> <output-directory>")
            }
            _ = NSApplication.shared
            try await run()
            print("PASS: linked saver follows atomic media/settings updates, retains players for settings, recovers from missing feed, rejects unsafe manifests, preserves static exports, and stays silent")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor private static func run() async throws {
        let video = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let template = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
            .appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScreenSaverSyncStore(rootURL: root.appendingPathComponent("Feed", isDirectory: true))
        let staticOptions = ScreenSaverExportOptions(scaling: .fit, animateOnBattery: false,
            animateOnExternalPower: false, pauseInLowPowerMode: true)
        let animatedOptions = ScreenSaverExportOptions(scaling: .fill, animateOnBattery: true,
            animateOnExternalPower: true, pauseInLowPowerMode: false)
        let first = try store.publish(videoURL: video, posterJPEG: poster(.blue), options: staticOptions, name: "First")
        let linkedURL = try store.prepareInstaller(templateURL: template)
        let staticURL = try ScreenSaverExporter.export(videoURL: video, posterJPEG: poster(.green),
            templateURL: template, destinationURL: root.appendingPathComponent("Static.saver"),
            options: staticOptions, identity: ScreenSaverInstallationIdentity(id: UUID(), name: "Static"))
        try require(!FileManager.default.fileExists(atPath: linkedURL.appendingPathComponent("Contents/Resources/video.mp4").path)
            && !FileManager.default.fileExists(atPath: linkedURL.appendingPathComponent("Contents/Resources/video.mov").path),
            "Linked installer unexpectedly bundles a stale video copy.")
        let linked = try Instance(url: linkedURL, preview: true)
        let ordinary = try Instance(url: staticURL, preview: false)
        defer {
            linked.view.stopAnimation(); ordinary.view.stopAnimation()
            linked.window.close(); ordinary.window.close()
            withExtendedLifetime([linked.bundle, ordinary.bundle]) {}
        }
        linked.view.startAnimation(); ordinary.view.startAnimation()
        try await wait("cold static players", instances: [linked, ordinary]) {
            ready(linked) && ready(ordinary) && linked.player?.rate == 0 && ordinary.player?.rate == 0
        }
        try require(linked.assetURL == (try store.videoURL(for: first)).resolvingSymlinksInPath(), "Linked saver ignored the shared feed.")
        try require(linked.video.videoGravity == .resizeAspect, "Initial linked scaling was not applied.")
        guard let originalPlayer = linked.player, let staticPlayer = ordinary.player else { throw SyncProbeFailure("Missing players.") }

        let edited = try store.publish(videoURL: video, posterJPEG: poster(.blue), options: animatedOptions, name: "Edited")
        try require(edited.revision == first.revision, "A settings edit copied the media again.")
        try await wait("settings update without replacing player", instances: [linked, ordinary]) {
            linked.player?.rate ?? 0 > 0 && linked.video.videoGravity == .resizeAspectFill
        }
        try require(linked.player === originalPlayer, "A settings-only update reset the player.")
        let oldTime = originalPlayer.currentTime().seconds
        try await wait("linked video advances", instances: [linked]) {
            let time = originalPlayer.currentTime().seconds
            return time.isFinite && oldTime.isFinite && abs(time - oldTime) > 0.05
        }

        let secondVideo = root.appendingPathComponent("Second.\(video.pathExtension)")
        try FileManager.default.copyItem(at: video, to: secondVideo)
        let second = try store.publish(videoURL: secondVideo, posterJPEG: poster(.red), options: animatedOptions, name: "Second")
        try require(second.revision != first.revision, "A different source did not publish a new media revision.")
        let secondURL = try store.videoURL(for: second).resolvingSymlinksInPath()
        try await wait("new media revision", instances: [linked, ordinary]) {
            ready(linked) && linked.assetURL == secondURL && linked.player !== originalPlayer && linked.player?.rate ?? 0 > 0
        }
        guard let secondPlayer = linked.player else { throw SyncProbeFailure("Missing replacement player.") }
        try require(ordinary.player === staticPlayer && ordinary.player?.rate == 0,
                    "Updating linked content affected an ordinary exported saver.")
        try require(ordinary.assetURL?.path.hasPrefix(staticURL.path + "/") == true,
                    "The ordinary saver lost its bundled video.")

        let manifest = store.rootURL.appendingPathComponent("current.json")
        let goodManifest = try Data(contentsOf: manifest)
        var unsafe = try JSONSerialization.jsonObject(with: goodManifest) as! [String: Any]
        unsafe["revision"] = "../escape"
        try JSONSerialization.data(withJSONObject: unsafe).write(to: manifest, options: .atomic)
        linked.view.animateOneFrame()
        try require(linked.player === secondPlayer && !linked.hasFailure, "An unsafe update displaced the valid active video.")
        try Data("incomplete manifest".utf8).write(to: manifest, options: .atomic)
        linked.view.animateOneFrame()
        try require(linked.player === secondPlayer && !linked.hasFailure, "A broken update displaced the valid active video.")
        linked.view.stopAnimation(); linked.view.startAnimation()
        try require(linked.player == nil && linked.hasFailure, "A cold missing feed silently fell back to stale bundled content.")
        try goodManifest.write(to: manifest, options: .atomic)
        try await wait("recovery after feed becomes valid", instances: [linked]) {
            ready(linked) && linked.assetURL == secondURL && !linked.hasFailure
        }
        guard let recovered = linked.player else { throw SyncProbeFailure("Missing recovered player.") }
        try require(recovered.isMuted && recovered.volume == 0 && !recovered.preventsDisplaySleepDuringVideoPlayback,
                    "The linked saver changed silence or display-sleep policy.")
        linked.view.stopAnimation(); linked.view.animateOneFrame()
        try await Task.sleep(for: .milliseconds(250))
        try require(linked.player == nil && recovered.rate == 0, "A late update resurrected playback after stop.")
        try require(!linked.window.isVisible && !ordinary.window.isVisible, "A probe window became visible.")
    }

    @MainActor private struct Instance {
        let bundle: Bundle
        let view: ScreenSaverView
        let window: NSWindow
        let video: AVPlayerLayer
        var player: AVPlayer? { video.player }
        var assetURL: URL? { (player?.currentItem?.asset as? AVURLAsset)?.url.resolvingSymlinksInPath() }
        var hasFailure: Bool {
            view.layer?.sublayers?.contains { $0.name == "MyWallpaper.message" && !$0.isHidden } ?? true
        }
        init(url: URL, preview: Bool) throws {
            guard let bundle = Bundle(url: url), let type = bundle.principalClass as? ScreenSaverView.Type,
                  let view = type.init(frame: NSRect(x: 0, y: 0, width: 480, height: 300), isPreview: preview) else {
                throw SyncProbeFailure("Cannot load the exported screen saver.")
            }
            self.bundle = bundle; self.view = view
            window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            guard let video = view.layer?.sublayers?.compactMap({ $0 as? AVPlayerLayer }).first else {
                throw SyncProbeFailure("Missing native video layer.")
            }
            self.video = video
        }
    }

    @MainActor private static func ready(_ instance: Instance) -> Bool {
        instance.player?.status == .readyToPlay && instance.player?.currentItem?.status == .readyToPlay
    }
    @MainActor private static func wait(_ message: String, instances: [Instance], condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while true {
            instances.forEach { $0.view.animateOneFrame() }
            if condition() { return }
            guard Date() < deadline else { throw SyncProbeFailure("Timed out: " + message) }
            try await Task.sleep(for: .milliseconds(80))
        }
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw SyncProbeFailure(message) }
    }
    @MainActor private static func poster(_ color: NSColor) throws -> Data {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { throw SyncProbeFailure("Cannot convert poster color.") }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw SyncProbeFailure("Cannot allocate poster.") }
        guard let pixels = bitmap.bitmapData else { throw SyncProbeFailure("Cannot access poster pixels.") }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            .map { UInt8(clamping: Int(($0 * 255).rounded())) }
        for y in 0..<16 {
            for x in 0..<16 {
                let offset = y * bitmap.bytesPerRow + x * 3
                for channel in 0..<3 { pixels[offset + channel] = channels[channel] }
            }
        }
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw SyncProbeFailure("Cannot encode poster.")
        }
        return data
    }
}

private struct SyncProbeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
