import Foundation
import Testing
@testable import MyWallpaper

@Suite @MainActor
struct UpdateRelaunchStateTests {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let snapshot = UpdatePlaybackSnapshot(wallpaperWasActive: true, userPaused: true,
        temporarilyAnimating: true, powerSource: "battery", windowWasVisible: false)

    @Test func completedRestartRestoresExactlyOnceWithoutChangingLaunchPreferences() throws {
        try withDefaults { defaults in
            defaults.set(false, forKey: "restoreOnLaunch")
            let state = UpdateRelaunchState(defaults: defaults, now: { instant })
            prepare(state)
            state.finalize(snapshot)
            #expect(state.consume(currentVersion: "0.10.0", currentBuild: "12") == snapshot)
            #expect(state.consume(currentVersion: "0.10.0", currentBuild: "12") == nil)
            #expect(defaults.bool(forKey: "restoreOnLaunch") == false)
        }
    }

    @Test func cancelledOrUnfinishedInstallDoesNotRestoreAnotherSession() throws {
        try withDefaults { defaults in
            let state = UpdateRelaunchState(defaults: defaults, now: { instant })
            prepare(state)
            #expect(state.consume(currentVersion: "0.10.0", currentBuild: "12") == nil)
            prepare(state)
            state.finalize(snapshot)
            state.cancel()
            #expect(state.consume(currentVersion: "0.10.0", currentBuild: "12") == nil)
        }
    }

    @Test func failedInstallWrongBuildAndStaleReceiptAreDiscarded() throws {
        try withDefaults { defaults in
            let state = UpdateRelaunchState(defaults: defaults, now: { instant })
            for (version, build) in [("0.9.0", "11"), ("0.10.0", "13"), ("0.11.0", "12")] {
                prepare(state)
                state.finalize(snapshot)
                #expect(state.consume(currentVersion: version, currentBuild: build) == nil)
                #expect(defaults.object(forKey: "updates.pendingRelaunch") == nil)
            }
            prepare(state)
            state.finalize(snapshot)
            let stale = UpdateRelaunchState(defaults: defaults, now: { instant.addingTimeInterval(7 * 86_400) })
            #expect(stale.consume(currentVersion: "0.10.0", currentBuild: "12") == nil)
            prepare(state)
            state.finalize(snapshot)
            let clockBackwards = UpdateRelaunchState(defaults: defaults, now: { instant.addingTimeInterval(-1) })
            #expect(clockBackwards.consume(currentVersion: "0.10.0", currentBuild: "12") == nil)
        }
    }

    @Test func corruptReceiptAndDowngradeCannotTriggerRestoration() throws {
        try withDefaults { defaults in
            let state = UpdateRelaunchState(defaults: defaults, now: { instant })
            defaults.set(Data("not a receipt".utf8), forKey: "updates.pendingRelaunch")
            #expect(state.consume(currentVersion: "0.10.0", currentBuild: "12") == nil)
            state.prepare(sourceVersion: "0.11.0", sourceBuild: "13", targetVersion: "0.10.0", targetBuild: "12")
            state.finalize(snapshot)
            #expect(state.consume(currentVersion: "0.10.0", currentBuild: "12") == nil)
        }
    }

    @Test func stoppedSessionIsNotConvertedToPlaying() throws {
        try withDefaults { defaults in
            let state = UpdateRelaunchState(defaults: defaults, now: { instant })
            prepare(state)
            let stopped = UpdatePlaybackSnapshot(wallpaperWasActive: false, userPaused: false,
                temporarilyAnimating: false, powerSource: "external", windowWasVisible: true)
            state.finalize(stopped)
            #expect(state.consume(currentVersion: "0.10.0", currentBuild: "12") == stopped)
        }
    }

    private func prepare(_ state: UpdateRelaunchState) {
        state.prepare(sourceVersion: "0.9.0", sourceBuild: "11", targetVersion: "0.10.0", targetBuild: "12")
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let domain = "UpdateRelaunchStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults)
    }
}
