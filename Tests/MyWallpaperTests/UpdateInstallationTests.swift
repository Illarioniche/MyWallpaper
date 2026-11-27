import Foundation
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct UpdateInstallationTests {
    @Test
    func installationNeedsANewerReleaseAndARelaunchHandler() {
        let harness = InstallHarness()
        let installer = harness.controller
        installer.prepareForRelaunch = nil
        installer.start(release: release(), currentVersion: "0.9.0")
        #expect(harness.starts == 0)
        #expect(!installer.isBusy)
        installer.prepareForRelaunch = { _ in }
        installer.start(release: release(), currentVersion: "0.10.0")
        #expect(harness.starts == 0)
        installer.start(release: release(), currentVersion: "0.9.0")
        #expect(harness.starts == 1)
        #expect(installer.state == .checking)
    }

    @Test
    func repeatedUpdateClickDoesNotStartAnotherSession() {
        let harness = InstallHarness()
        let installer = harness.controller
        var focused = 0
        installer.openUpdates = { focused += 1 }
        installer.start(release: release(), currentVersion: "0.9.0")
        installer.start(release: release(), currentVersion: "0.9.0")
        #expect(harness.starts == 1)
        #expect(focused == 1)
    }

    @Test
    func appcastMustMatchConsentAndAdvanceBuildBeforeDownload() throws {
        let installer = InstallHarness().controller
        installer.start(release: release(), currentVersion: "0.9.0")
        let id = try #require(installer.activeSessionID)
        let url = try #require(release().downloadURL)
        for candidate in [UpdateInstallTarget(version: "0.9.0", build: "12"),
                          UpdateInstallTarget(version: "0.11.0", build: "13"),
                          UpdateInstallTarget(version: "0.10.0", build: "11"),
                          UpdateInstallTarget(version: "0.10.0", build: "012"),
                          UpdateInstallTarget(version: "0.10.0", build: "12-beta")] {
            #expect(throws: UpdateInstallFailure.self) {
                try installer.validate(candidate, downloadURL: url, informationOnly: false, sessionID: id)
            }
        }
        let valid = UpdateInstallTarget(version: "0.10.0", build: "12")
        for invalidURL in [nil, URL(string: "https://example.com/update.dmg"), URL(string: url.absoluteString + "?redirect=1")] {
            #expect(throws: UpdateInstallFailure.self) {
                try installer.validate(valid, downloadURL: invalidURL, informationOnly: false, sessionID: id)
            }
        }
        #expect(throws: UpdateInstallFailure.self) {
            try installer.validate(valid, downloadURL: url, informationOnly: true, sessionID: id)
        }
        try installer.validate(valid, downloadURL: url, informationOnly: false, sessionID: id)
    }

    @Test
    func cancellingADownloadPreventsLateCallbacksFromChangingANewAttempt() throws {
        let harness = InstallHarness()
        let installer = harness.controller
        var cancellations = 0
        var aborts = 0
        installer.installationDidAbort = { aborts += 1 }
        installer.start(release: release(), currentVersion: "0.9.0")
        let first = try #require(installer.activeSessionID)
        installer.downloading(cancellation: { cancellations += 1 }, sessionID: first)
        installer.cancel()
        installer.cancel()
        #expect(cancellations == 1)
        #expect(aborts == 1)
        #expect(installer.state == .cancelled)

        installer.start(release: release(), currentVersion: "0.9.0")
        installer.receivedData(1024, sessionID: first)
        installer.fail(CancellationError(), sessionID: first)
        installer.dismissed(sessionID: first)
        #expect(installer.state == .checking)
        #expect(harness.starts == 2)
    }

    @Test
    func unknownLengthAndOverflowDoNotBreakDownloadProgress() throws {
        let installer = InstallHarness().controller
        installer.start(release: release(), currentVersion: "0.9.0")
        let id = try #require(installer.activeSessionID)
        installer.downloading(cancellation: {}, sessionID: id)
        installer.receivedExpectedLength(0, sessionID: id)
        installer.receivedData(.max, sessionID: id)
        installer.receivedData(1, sessionID: id)
        #expect(installer.state == .downloading(received: .max, total: nil))
        installer.extracting(progress: .nan, sessionID: id)
        #expect(installer.state == .extracting(nil))
        #expect(!installer.canCancel)
        installer.extracting(progress: 9, sessionID: id)
        #expect(installer.state == .extracting(1))
    }

    @Test
    func installWaitsForPreparationAndRecordsTheExactTarget() async throws {
        let installer = InstallHarness().controller
        let gate = InstallPreparationGate()
        installer.prepareForRelaunch = { target in try await gate.wait(target) }
        installer.start(release: release(), currentVersion: "0.9.0")
        let id = try #require(installer.activeSessionID)
        let target = UpdateInstallTarget(version: "0.10.0", build: "12")
        try installer.validate(target, downloadURL: release().downloadURL, informationOnly: false, sessionID: id)
        var replies: [Bool] = []
        installer.readyToInstall(sessionID: id) { replies.append($0) }
        await gate.waitUntilEntered()
        #expect(installer.state == .waitingForApplication)
        #expect(replies.isEmpty)
        #expect(gate.target == target)
        gate.finish()
        for _ in 0..<20 where replies.isEmpty { await Task.yield() }
        #expect(replies == [true])
        #expect(installer.state == .restarting)
        #expect(!installer.canCancel)
    }

    @Test
    func cancelDuringSaveCannotRestartWhenSaveLaterFinishes() async throws {
        let installer = InstallHarness().controller
        let gate = InstallPreparationGate()
        installer.prepareForRelaunch = { target in try await gate.wait(target) }
        installer.start(release: release(), currentVersion: "0.9.0")
        let id = try #require(installer.activeSessionID)
        try installer.validate(UpdateInstallTarget(version: "0.10.0", build: "12"),
                               downloadURL: release().downloadURL, informationOnly: false, sessionID: id)
        var replies: [Bool] = []
        installer.readyToInstall(sessionID: id) { replies.append($0) }
        await gate.waitUntilEntered()
        installer.cancel()
        #expect(replies == [false])
        gate.finish()
        for _ in 0..<20 { await Task.yield() }
        #expect(replies == [false])
        #expect(installer.state == .cancelled)
    }

    @Test
    func failedPreparationCancelsInstallAndClearsRelaunchIntent() async throws {
        let installer = InstallHarness().controller
        installer.prepareForRelaunch = { _ in throw InstallTestError.saveFailed }
        var aborts = 0
        installer.installationDidAbort = { aborts += 1 }
        installer.start(release: release(), currentVersion: "0.9.0")
        let id = try #require(installer.activeSessionID)
        try installer.validate(UpdateInstallTarget(version: "0.10.0", build: "12"),
                               downloadURL: release().downloadURL, informationOnly: false, sessionID: id)
        var replies: [Bool] = []
        installer.readyToInstall(sessionID: id) { replies.append($0) }
        for _ in 0..<20 where replies.isEmpty { await Task.yield() }
        #expect(replies == [false])
        #expect(aborts == 1)
        #expect(!installer.isBusy)
        #expect(!installer.canCancel)
        installer.fail(InstallTestError.saveFailed, sessionID: id)
        #expect(aborts == 1)
    }

    @Test
    func deferredOfferReturnsOnExplicitCheckAndInstallationBlocksMetadataChanges() async throws {
        let suite = "UpdateInstallationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data("""
        {"tag_name":"v0.10.0","name":"New version","body":"Notes","draft":false,"prerelease":false,
        "html_url":"https://github.com/Illarioniche/MyWallpaper/releases/tag/v0.10.0","assets":[]}
        """.utf8)
        let harness = InstallHarness()
        let clock = InstallTestClock()
        let updates = UpdateController(currentVersion: "0.9.0", defaults: defaults, now: { clock.date }, transport: { request in
            UpdateHTTPResponse(data: data, statusCode: 200, finalURL: request.url!)
        }, installation: harness.controller)
        await updates.checkNow()
        #expect(updates.offeredRelease != nil)
        updates.deferAvailableRelease()
        #expect(updates.offeredRelease == nil)
        #expect(updates.availableRelease != nil)
        let firstChecked = try #require(updates.lastChecked)
        clock.date.addTimeInterval(25 * 60 * 60)
        await updates.checkAutomaticallyIfNeeded()
        #expect(updates.lastChecked == clock.date)
        #expect(updates.lastChecked != firstChecked, "The automatic network check must run after its daily interval.")
        #expect(updates.offeredRelease == nil)
        await updates.checkNow()
        #expect(updates.offeredRelease != nil)
        updates.installAvailableRelease()
        let before = updates.lastChecked
        await updates.checkNow()
        #expect(updates.lastChecked == before)
        updates.deferAvailableRelease()
        #expect(updates.offeredRelease != nil)
    }

    private func release() -> UpdateRelease {
        let root = "https://github.com/Illarioniche/MyWallpaper/releases"
        return UpdateRelease(version: "0.10.0", title: "MyWallpaper", notes: "",
                             pageURL: URL(string: "\(root)/tag/v0.10.0")!,
                             downloadURL: URL(string: "\(root)/download/v0.10.0/MyWallpaper-0.10.0-universal.dmg")!, checksumURL: nil)
    }
}

private enum InstallTestError: Error { case saveFailed }

@MainActor
private final class InstallTestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private final class InstallHarness {
    var starts = 0
    lazy var controller: UpdateInstallationController = {
        let controller = UpdateInstallationController(currentBuild: "11", serviceFactory: { [self] _, _ in
            InstallTestService { self.starts += 1 }
        })
        controller.prepareForRelaunch = { _ in }
        return controller
    }()
}

@MainActor
private final class InstallTestService: UpdateInstallationService {
    private let onStart: () -> Void
    init(onStart: @escaping () -> Void) { self.onStart = onStart }
    func start() throws { onStart() }
}

@MainActor
private final class InstallPreparationGate {
    var target: UpdateInstallTarget?
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(_ target: UpdateInstallTarget) async throws {
        self.target = target
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
    }
    func waitUntilEntered() async {
        while continuation == nil { await Task.yield() }
    }
    func finish() { continuation?.resume(); continuation = nil }
}
