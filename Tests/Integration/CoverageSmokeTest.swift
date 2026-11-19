import AppKit
import CoreGraphics

/// Exercises real WindowServer geometry in a small area, without loading videos,
/// changing preferences or inspecting the contents of any application window.
@main
enum CoverageSmokeTest {
    @MainActor
    static func main() {
        guard CommandLine.arguments.dropFirst().first == "--run"
                || CommandLine.arguments.dropFirst().first == "--cover" else {
            print("Usage: coverage-smoke-test --run")
            exit(2)
        }
        let app = NSApplication.shared
        let delegate = CoverageSmokeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private struct CoverageSmokeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private final class CoverageSmokeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CoverageSmokeDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var monitor: DesktopCoverageMonitor?
    private var child: Process?
    private var temporaryDirectory: URL?
    private var safetyTimer: Timer?
    private var finished = false
    private var allowedWindowIDs = Set<CGWindowID>()
    private var providerCalls = 0
    private var latestSnapshot: [[String: Any]] = []
    private var latestCoverage: [Bool]?
    private var coverageEvents = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let timer = Timer(timeInterval: 14, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.finish(code: 1, message: "FAIL: coverage test exceeded its 14-second safety limit")
            }
        }
        safetyTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        Task { @MainActor in
            do {
                if CommandLine.arguments[1] == "--cover" {
                    try await runChildCover()
                    finish(code: 0, message: nil)
                } else {
                    try await runChecks()
                    finish(code: 0, message: "PASS: real titled-window geometry, partial and independent coverage, union, polling lifecycle and another process")
                }
            } catch {
                finish(code: 1, message: "FAIL: \(error.localizedDescription)")
            }
        }
    }

    private func runChecks() async throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw CoverageSmokeFailure(message: "An active macOS graphical session is required.")
        }
        let frame = CGRect(x: (screen.visibleFrame.midX - 180).rounded(),
                           y: (screen.visibleFrame.midY - 120).rounded(),
                           width: 360, height: 240)
        let leftHalf = CGRect(x: frame.minX, y: frame.minY, width: 180, height: 240)
        let rightHalf = CGRect(x: frame.midX, y: frame.minY, width: 180, height: 240)
        let leftTarget = CGRect(x: frame.minX, y: frame.minY, width: 170, height: 240)
        let rightTarget = CGRect(x: frame.midX + 10, y: frame.minY, width: 170, height: 240)

        // This noninteractive outline is above ordinary apps but below the test
        // covers. It is never included in the injected WindowServer snapshot.
        let probe = makeWindow(frame: frame, cover: false)
        probe.orderFrontRegardless()

        let monitor = DesktopCoverageMonitor { [weak self] in
            guard let self else { return nil }
            self.providerCalls += 1
            guard let snapshot = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else { return nil }
            let ownCovers = snapshot.filter { info in
                guard let number = info[kCGWindowNumber as String] as? NSNumber else { return false }
                return self.allowedWindowIDs.contains(number.uint32Value)
            }
            self.latestSnapshot = ownCovers
            return ownCovers
        }
        self.monitor = monitor
        monitor.onChange = { [weak self] coverage in
            self?.latestCoverage = coverage
            self?.coverageEvents += 1
        }

        monitor.update(trackingFrames: [frame], enabled: true)
        try expect([false], "uncovered baseline")
        try require(providerCalls > 0, "Enabling coverage did not read a WindowServer snapshot.")

        let first = try showCover(frame: frame)
        // Do not call update here: this assertion exercises the real timer,
        // rather than only the monitor's synchronous configuration refresh.
        try await wait("timer detects a native titled cover", timeout: 2) {
            self.latestCoverage == [true]
        }
        try require(latestSnapshot.contains { info in
            (info[kCGWindowNumber as String] as? NSNumber)?.intValue == first.windowNumber
                && (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 3
        }, "The covering rectangle did not come from the real floating test window.")
        print("PASS: a native titled window with a transparent title bar is detected by polling")

        first.setFrame(leftHalf, display: true)
        try await refresh(monitor, frames: [frame])
        try expect([false], "half-covered desktop remains visible")

        monitor.update(trackingFrames: [leftTarget, rightTarget], enabled: true)
        try expect([true, false], "left region pauses independently")
        first.setFrame(rightHalf, display: true)
        try await refresh(monitor, frames: [leftTarget, rightTarget])
        try expect([false, true], "right region pauses independently")
        first.close()
        try await refresh(monitor, frames: [leftTarget, rightTarget])
        try expect([false, false], "closing a cover exposes both regions")
        print("PASS: partial visibility and independently tracked regions")

        let left = try showCover(frame: leftHalf)
        try await refresh(monitor, frames: [frame])
        try expect([false], "one half of a two-window union is insufficient")
        let right = try showCover(frame: rightHalf)
        try await refresh(monitor, frames: [frame])
        try expect([true], "two adjacent windows jointly cover the target")
        right.orderOut(nil)
        try await refresh(monitor, frames: [frame])
        try expect([false], "ordering out one union member resumes the target")
        right.orderFrontRegardless()
        try await refresh(monitor, frames: [frame])
        try expect([true], "restoring a cover pauses the target again")

        monitor.update(trackingFrames: [frame], enabled: false)
        try expect([false], "disabling smart pause clears coverage")
        let disabledCalls = providerCalls
        try await Task.sleep(for: .milliseconds(1_400))
        try require(providerCalls == disabledCalls, "Disabled monitor kept polling WindowServer.")
        monitor.update(trackingFrames: [frame], enabled: false)
        try require(providerCalls == disabledCalls, "A disabled update read window metadata.")

        monitor.update(trackingFrames: [frame], enabled: true)
        try expect([true], "re-enabling smart pause refreshes immediately")
        let stoppedCalls = providerCalls
        let stoppedEvents = coverageEvents
        monitor.stop()
        try await Task.sleep(for: .milliseconds(1_400))
        try require(providerCalls == stoppedCalls, "Stopped monitor kept polling WindowServer.")
        try require(coverageEvents == stoppedEvents, "Stopped monitor continued publishing coverage.")
        monitor.update(trackingFrames: [frame], enabled: true)
        try expect([true], "a stopped monitor can start again")
        try require(coverageEvents > stoppedEvents, "Restart did not publish a fresh initial state.")
        left.close()
        right.close()
        try await refresh(monitor, frames: [frame])
        try expect([false], "closing all local covers resumes playback")
        print("PASS: rectangular union, disable, stop and restart without background polling")

        try await checkOtherProcess(monitor, frame: frame)
        monitor.stop()
    }

    private func checkOtherProcess(_ monitor: DesktopCoverageMonitor, frame: CGRect) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyWallpaperCoverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        let ready = directory.appendingPathComponent("ready.json")
        let stop = directory.appendingPathComponent("stop")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--cover", String(Double(frame.origin.x)), String(Double(frame.origin.y)),
                             String(Double(frame.width)), String(Double(frame.height)), ready.path, stop.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        child = process
        try process.run()
        try await wait("separate cover process", timeout: 2) {
            FileManager.default.fileExists(atPath: ready.path) || !process.isRunning
        }
        try require(FileManager.default.fileExists(atPath: ready.path),
                    "The separate cover process exited before creating its window.")
        let data = try Data(contentsOf: ready)
        guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: NSNumber],
              let windowID = receipt["windowID"]?.uint32Value, windowID != 0 else {
            throw CoverageSmokeFailure(message: "The separate process returned an invalid window ID.")
        }
        allowedWindowIDs.insert(windowID)
        try await refresh(monitor, frames: [frame])
        try expect([true], "a different process's titled window covers the target")
        try require(latestSnapshot.contains { info in
            (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
                && (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.processIdentifier
        }, "The cross-process check did not use the child window's real WindowServer record.")

        try Data().write(to: stop, options: .atomic)
        try await wait("separate cover process cleanup", timeout: 1.5) { !process.isRunning }
        try require(process.terminationStatus == 0, "The separate cover process failed during cleanup.")
        try await refresh(monitor, frames: [frame])
        try expect([false], "closing another process's window resumes the target")
        print("PASS: another process's native titled window pauses and resumes independently")
    }

    private func runChildCover() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 8,
              let x = Double(arguments[2]), let y = Double(arguments[3]),
              let width = Double(arguments[4]), let height = Double(arguments[5]),
              x.isFinite, y.isFinite, width > 0, width <= 360, height > 0, height <= 240 else {
            throw CoverageSmokeFailure(message: "Invalid internal cover-process arguments.")
        }
        let window = try showCover(frame: CGRect(x: x, y: y, width: width, height: height))
        let data = try JSONSerialization.data(withJSONObject: ["windowID": window.windowNumber])
        try data.write(to: URL(fileURLWithPath: arguments[6]), options: .atomic)
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: arguments[7]) {
            guard ContinuousClock.now < deadline else {
                throw CoverageSmokeFailure(message: "Cover-process safety timeout.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func makeWindow(frame: CGRect, cover: Bool) -> NSWindow {
        let window = CoverageSmokeWindow(contentRect: frame,
                                         styleMask: cover ? [.titled, .fullSizeContentView] : [.borderless],
                                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: cover ? 3 : 1)
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = "MyWallpaper — проверка перекрытия"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = (cover ? NSColor.windowBackgroundColor
                                               : NSColor.systemTeal.withAlphaComponent(0.06)).cgColor
        if !cover {
            content.layer?.borderWidth = 1
            content.layer?.borderColor = NSColor.systemTeal.withAlphaComponent(0.65).cgColor
        }
        window.contentView = content
        window.setFrame(frame, display: false)
        windows.append(window)
        return window
    }

    private func showCover(frame: CGRect) throws -> NSWindow {
        let window = makeWindow(frame: frame, cover: true)
        window.orderFrontRegardless()
        try require(window.windowNumber > 0, "The test cover has no WindowServer ID.")
        try require(!window.canBecomeKey && !window.canBecomeMain && window.ignoresMouseEvents,
                    "A coverage test window can steal focus or intercept input.")
        allowedWindowIDs.insert(CGWindowID(window.windowNumber))
        return window
    }

    private func refresh(_ monitor: DesktopCoverageMonitor, frames: [CGRect]) async throws {
        // Let WindowServer finish ordering/resizing before taking a real snapshot.
        try await Task.sleep(for: .milliseconds(80))
        monitor.update(trackingFrames: frames, enabled: true)
    }

    private func expect(_ expected: [Bool], _ label: String) throws {
        try require(latestCoverage == expected,
                    "\(label): expected \(expected), observed \(String(describing: latestCoverage)).")
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CoverageSmokeFailure(message: message) }
    }

    private func wait(_ label: String, timeout: Double,
                      until condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw CoverageSmokeFailure(message: "Timed out waiting for \(label).")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func finish(code: Int32, message: String?) {
        guard !finished else { return }
        finished = true
        safetyTimer?.invalidate()
        monitor?.stop()
        windows.forEach { $0.close() }
        if let child, child.isRunning { child.terminate() }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        if let message { print(message) }
        exit(code)
    }
}
