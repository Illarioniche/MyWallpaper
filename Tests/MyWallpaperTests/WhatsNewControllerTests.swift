import Foundation
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct WhatsNewControllerTests {
    @Test
    func firstStableUpgradeShowsItsOwnBundledNotesOnceAndRetainsThePreviousRelease() throws {
        try withDefaults { defaults in
            let previous = WhatsNewController(currentVersion: "0.10.0", currentBuild: "12", defaults: defaults)
            #expect(previous.release?.version == "0.10.0")
            #expect(!previous.recordLaunch())

            let stable = WhatsNewController(currentVersion: "1.0.0", currentBuild: "13", defaults: defaults)
            let release = try #require(stable.release)
            #expect(release.version == "1.0.0" && release.build == "13")
            #expect(stable.recordLaunch())
            stable.dismiss()

            let relaunched = WhatsNewController(currentVersion: "1.0.0", currentBuild: "13", defaults: defaults)
            #expect(!relaunched.recordLaunch(wasUpdated: true))
            #expect(relaunched.release == release, "Dismissal keeps notes available from Updates.")
            #expect(WhatsNewController(currentVersion: "1.0.0", currentBuild: "12", defaults: defaults).release == nil)
            #expect(WhatsNewController(currentVersion: "0.10.0", currentBuild: "13", defaults: defaults).release == nil)
            #expect(previous.release?.titleKey == "Обновления без лишних шагов")
        }
    }

    @Test
    func freshInstallationEstablishesBaselineAndKeepsNotesAvailableManually() throws {
        try withDefaults { defaults in
            let first = controller(defaults)
            #expect(first.release?.version == "0.10.0")
            #expect(!first.recordLaunch())
            #expect(!first.shouldPresent)
            #expect(!controller(defaults).recordLaunch())
            #expect(first.release != nil, "Updates can show bundled notes even without an automatic announcement.")
        }
    }

    @Test
    func verifiedUpdateAppearsUntilClosedAndStaysDismissedOnSubsequentLaunches() throws {
        try withDefaults { defaults in
            let installed = controller(defaults)
            #expect(installed.recordLaunch(wasUpdated: true))
            let relaunchedBeforeClosing = controller(defaults)
            #expect(relaunchedBeforeClosing.recordLaunch())

            relaunchedBeforeClosing.dismiss()

            #expect(!relaunchedBeforeClosing.shouldPresent)
            let relaunched = controller(defaults)
            #expect(!relaunched.recordLaunch())
            #expect(!relaunched.recordLaunch(wasUpdated: true), "A repeated installer receipt must not reopen dismissed notes.")
            #expect(relaunched.release != nil, "Dismissing must not remove the manual What's New entry.")
        }
    }

    @Test
    func manualUpgradeFromRecordedVersionIsDetectedWithoutInstallerReceipt() throws {
        try withDefaults { defaults in
            let previous = controller(defaults, version: "0.9.0", build: "11")
            #expect(!previous.recordLaunch())

            let current = controller(defaults)

            #expect(current.recordLaunch())
            #expect(current.shouldPresent)
        }
    }

    @Test
    func NewReleaseCanBeAnnouncedAfterEarlierReleaseWasDismissed() throws {
        try withDefaults { defaults in
            let previous = controller(defaults, version: "0.9.0", build: "11")
            _ = previous.recordLaunch(wasUpdated: true)
            previous.dismiss()
            let current = controller(defaults)

            #expect(current.recordLaunch())
            current.dismiss()
            #expect(!controller(defaults, version: "0.9.0", build: "11").recordLaunch())
            #expect(!controller(defaults).recordLaunch(), "Revisiting a dismissed build after a downgrade must not announce it again.")
        }
    }

    @Test
    func notesMustMatchBothInstalledVersionAndBuild() throws {
        try withDefaults { defaults in
            let mismatch = WhatsNewController(currentVersion: "0.11.0", currentBuild: "13", defaults: defaults)
            #expect(mismatch.release == nil)
            #expect(!mismatch.recordLaunch(wasUpdated: true))
            let differentBuild = WhatsNewController(currentVersion: "0.10.0", currentBuild: "14", defaults: defaults)
            #expect(differentBuild.release == nil)
            #expect(!differentBuild.recordLaunch(wasUpdated: true))
        }
    }

    @Test
    func downgradeAndUnchangedBuildDoNotClaimAnUpdate() throws {
        try withDefaults { defaults in
            #expect(!controller(defaults, version: "0.11.0", build: "13").recordLaunch())
            #expect(!controller(defaults).recordLaunch())
            #expect(!controller(defaults, version: "0.11.0", build: "12").recordLaunch())
        }
    }

    @Test
    func corruptStateDoesNotCreateFalseUpgradeAndDoesNotBlockVerifiedOne() throws {
        try withDefaults { defaults in
            defaults.set(Data("not JSON".utf8), forKey: "updates.whatsNew.lastLaunchedRelease")
            defaults.set(["wrong": "type"], forKey: "updates.whatsNew.dismissedReleases")
            defaults.set("0.99.0#1000", forKey: "updates.whatsNew.pendingRelease")
            #expect(!controller(defaults).recordLaunch())
            #expect(controller(defaults).recordLaunch(wasUpdated: true))
        }
    }

    @Test
    func malformedVersionAndBuildCannotShowMismatchedNotes() throws {
        try withDefaults { defaults in
            for (version, build) in [("0.10.0", ""), ("0.10.0", "0"), ("0.10.0", "012"),
                                     ("0.10.0", "12beta"), ("v0.10.0", "12"), ("0.10", "12")] {
                let model = WhatsNewController(currentVersion: version, currentBuild: build, defaults: defaults)
                #expect(model.release == nil)
                #expect(!model.recordLaunch(wasUpdated: true))
            }
        }
    }

    @Test
    func bundledReleaseNotesHaveEnglishTranslations() {
        let english = AppLocalizer(language: .english)
        for release in WhatsNewRelease.bundled {
            let keys = [release.titleKey, release.subtitleKey] + release.features.flatMap { [$0.titleKey, $0.detailKey] }
            for key in keys {
                #expect(english.text(key) != key, "Missing English release note: \(key)")
                #expect(AppLocalizer.russian.text(key) == key)
            }
        }
    }

    private func controller(_ defaults: UserDefaults, version: String = "0.10.0", build: String = "12") -> WhatsNewController {
        let releases = [("0.9.0", "11"), ("0.10.0", "12"), ("0.11.0", "12"), ("0.11.0", "13")].map { version, build in
            WhatsNewRelease(version: version, build: build, titleKey: "Fixture", subtitleKey: "Fixture", features: [])
        }
        return WhatsNewController(currentVersion: version, currentBuild: build, defaults: defaults, releases: releases)
    }

    private func withDefaults(_ operation: (UserDefaults) throws -> Void) throws {
        let name = "MyWallpaperTests.WhatsNew.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try operation(defaults)
    }
}
