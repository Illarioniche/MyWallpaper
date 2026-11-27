import AppKit
import CryptoKit
import Sparkle

/// A throwaway native host for Sparkle's actual installer. It never launches MyWallpaper.
@main
struct UpdateInstallerProbe {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--generate-key" {
            let key = Curve25519.Signing.PrivateKey()
            let destination = URL(fileURLWithPath: CommandLine.arguments[2])
            try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            print(key.publicKey.rawRepresentation.base64EncodedString())
            return
        }
        let application = NSApplication.shared
        let delegate = ProbeDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class ProbeDelegate: NSObject, NSApplicationDelegate, SPUUserDriver, SPUUpdaterDelegate {
    private let root: URL
    private let expectsFailure: Bool
    private let quitDuringExtraction: Bool
    private let defaults: UserDefaults
    private var updater: SPUUpdater?
    private var target: SUAppcastItem?
    private var waitingForWrites = false
    private var installationState: UpdateInstallationState = .idle
    private var terminationTask: Task<Void, Never>?
    private var finished = false
    private var bytes: UInt64 = 0
    private var receipt: UpdateRelaunchState { UpdateRelaunchState(defaults: defaults) }
    private let snapshot = UpdatePlaybackSnapshot(wallpaperWasActive: true, userPaused: true,
                                                  temporarilyAnimating: false, powerSource: "battery",
                                                  windowWasVisible: true)

    override init() {
        guard let rootPath = Bundle.main.object(forInfoDictionaryKey: "ProbeRoot") as? String else {
            fatalError("Fixture is missing ProbeRoot")
        }
        guard Bundle.main.bundleIdentifier != nil else { fatalError("Fixture is missing bundle identifier") }
        self.root = URL(fileURLWithPath: rootPath)
        // Every fixture has a unique bundle ID. macOS rejects opening your own ID as a named suite.
        self.defaults = .standard
        expectsFailure = Bundle.main.object(forInfoDictionaryKey: "ProbeExpectsFailure") as? Bool ?? false
        quitDuringExtraction = Bundle.main.object(forInfoDictionaryKey: "ProbeQuitDuringExtraction") as? Bool ?? false
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
        event("launch", ["pid": ProcessInfo.processInfo.processIdentifier, "version": version, "build": build])
        if build == "13" {
            let restored = receipt.consume(currentVersion: version, currentBuild: build)
            let notes = WhatsNewRelease(version: version, build: build, titleKey: "Fixture", subtitleKey: "Fixture", features: [])
            let whatsNew = WhatsNewController(currentVersion: version, currentBuild: build, defaults: defaults, releases: [notes])
            let shown = whatsNew.recordLaunch(wasUpdated: restored != nil)
            whatsNew.dismiss()
            let noRepeat = !WhatsNewController(currentVersion: version, currentBuild: build, defaults: defaults,
                                              releases: [notes]).recordLaunch()
            let passed = !expectsFailure && restored == snapshot && shown && noRepeat
                && defaults.bool(forKey: "probe.pendingWriteFinished")
                && (!quitDuringExtraction || defaults.bool(forKey: "probe.quitWasDeferred"))
                && defaults.string(forKey: "probe.existingSetting") == "preserved"
                && receipt.consume(currentVersion: version, currentBuild: build) == nil
            finish(passed, ["version": version, "build": build, "restored": restored == snapshot,
                            "whatsNewShown": shown, "dismissalPersisted": noRepeat,
                            "manualQuitWasDeferred": defaults.bool(forKey: "probe.quitWasDeferred"),
                            "writeFinished": defaults.bool(forKey: "probe.pendingWriteFinished")])
            return
        }
        defaults.set("preserved", forKey: "probe.existingSetting")
        defaults.synchronize()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        self.updater = updater
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        do {
            try updater.start()
            updater.checkForUpdates()
        } catch { handleError(error) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard waitingForWrites || installationState.requiresPreparationBeforeQuit else { return .terminateNow }
        event("waitingForPendingWrite")
        defaults.set(true, forKey: "probe.quitWasDeferred")
        if terminationTask == nil {
            terminationTask = Task { @MainActor in
                while installationState.requiresPreparationBeforeQuit {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if waitingForWrites {
                    try? await Task.sleep(for: .milliseconds(500))
                    completePendingWrite()
                }
                terminationTask = nil
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if target != nil, !finished { receipt.finalize(snapshot) }
        event("willTerminate")
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        installationState = .checking
        event("checking")
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        target = appcastItem
        event("found", ["build": appcastItem.versionString])
        reply(.install)
    }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        handleError(error)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        handleError(error)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        installationState = .downloading(received: 0, total: nil)
        event("downloading")
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        event("downloadLength", ["length": expectedContentLength])
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) { bytes += length }
    func showDownloadDidStartExtractingUpdate() {
        installationState = .extracting(nil)
        event("extracting", ["received": bytes])
        if quitDuringExtraction {
            // A real menu action runs after this callback has returned. Calling
            // terminate synchronously here would prevent Sparkle starting extraction.
            // Use a run-loop selector, not a main-queue block: terminateLater spins
            // an AppKit event loop that must remain able to service the main queue.
            perform(#selector(simulateMenuQuit), with: nil, afterDelay: 0.05)
        }
    }
    @objc private func simulateMenuQuit() {
        event("manualQuitDuringExtraction")
        NSApplication.shared.terminate(nil)
    }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let target else { reply(.dismiss); return }
        if quitDuringExtraction {
            installationState = .waitingForApplication
            waitingForWrites = true
            event("preparingAfterManualQuit")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                completePendingWrite()
                prepareReceipt(target)
                installationState = .restarting
                reply(.install)
            }
        } else {
            prepareReceipt(target)
            waitingForWrites = true
            installationState = .restarting
            reply(.install)
        }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        event("installing", ["terminated": applicationTerminated])
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        event("installed", ["relaunched": relaunched])
        acknowledgement()
    }
    func dismissUpdateInstallation() { event("dismissed") }
    func showUpdateInFocus() {}

    private func handleError(_ error: Error) {
        guard !finished else { return }
        installationState = .failed(UpdateInstallFailure(message: error.localizedDescription))
        var chain: [[String: Any]] = []
        var current: NSError? = error as NSError
        while let item = current, chain.count < 8 {
            chain.append(["domain": item.domain, "code": item.code, "message": item.localizedDescription])
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        event("error", ["errors": chain])
        let rejectedSignature = chain.contains {
            $0["domain"] as? String == SUSparkleErrorDomain && [3001, 3002].contains($0["code"] as? Int ?? 0)
        }
        let sourceStillInstalled = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "12"
        receipt.cancel()
        finish(expectsFailure && rejectedSignature && sourceStillInstalled,
               ["rejectedSignature": rejectedSignature, "sourceStillInstalled": sourceStillInstalled, "errors": chain])
    }

    private func prepareReceipt(_ target: SUAppcastItem) {
        receipt.prepare(sourceVersion: "0.10.0", sourceBuild: "12", targetVersion: target.displayVersionString,
                        targetBuild: target.versionString)
        event("readyToInstall")
    }

    private func completePendingWrite() {
        defaults.set(true, forKey: "probe.pendingWriteFinished")
        defaults.synchronize()
        waitingForWrites = false
        event("pendingWriteFinished")
    }

    private func finish(_ passed: Bool, _ details: [String: Any]) {
        guard !finished else { return }
        finished = true
        var result = details
        result["passed"] = passed
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .atomic)
        event("result", ["passed": passed])
        defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        defaults.synchronize()
        NSApplication.shared.terminate(nil)
    }

    private func event(_ name: String, _ details: [String: Any] = [:]) {
        var values = details
        values["event"] = name
        values["time"] = Date().timeIntervalSince1970
        guard var data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let destination = root.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: destination) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
