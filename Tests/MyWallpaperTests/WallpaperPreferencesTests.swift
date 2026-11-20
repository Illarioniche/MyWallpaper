import Foundation
import Testing
@testable import MyWallpaper

@Suite
struct WallpaperPreferencesTests {
    @Test
    func globalPowerRulesReadLegacyPreferencesWithoutChangingThem() throws {
        try withIsolatedDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            preferences.animateOnExternalPower = false
            preferences.animateOnBattery = true
            preferences.pauseInLowPowerMode = false
            preferences.pauseWhenCovered = false
            preferences.volume = 0.25
            let before = defaults.dictionaryRepresentation()
            #expect(!preferences.hasStoredGlobalPowerRules)
            #expect(preferences.currentWallpaperUsesGlobalPowerRules == nil)
            #expect(preferences.legacyCurrentWallpaperID == nil)
            #expect(preferences.globalPowerRules == WallpaperPowerRules(animateOnExternalPower: false,
                animateOnBattery: true, pauseInLowPowerMode: false, pauseWhenCovered: false))
            #expect(NSDictionary(dictionary: defaults.dictionaryRepresentation()).isEqual(to: before))
        }
    }

    @Test
    func seededGlobalRulesRemainIndependentOfTheEffectivePlaybackCache() throws {
        try withIsolatedDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            let preservedID = UUID()
            preferences.legacyCurrentWallpaperID = preservedID
            let global = WallpaperPowerRules(animateOnExternalPower: false, animateOnBattery: true,
                                             pauseInLowPowerMode: false, pauseWhenCovered: true)
            preferences.globalPowerRules = global
            preferences.currentWallpaperUsesGlobalPowerRules = false
            preferences.animateOnExternalPower = true
            preferences.animateOnBattery = false
            preferences.pauseInLowPowerMode = true
            preferences.pauseWhenCovered = false
            let restored = WallpaperPreferences(defaults: defaults)
            #expect(restored.hasStoredGlobalPowerRules && restored.globalPowerRules == global)
            #expect(restored.currentWallpaperUsesGlobalPowerRules == false)
            #expect(restored.legacyCurrentWallpaperID == preservedID)
            #expect(restored.animateOnExternalPower && !restored.animateOnBattery)
            #expect(restored.pauseInLowPowerMode && !restored.pauseWhenCovered)
            preferences.globalPowerRules = .init()
            #expect(restored.pauseInLowPowerMode && !restored.pauseWhenCovered,
                    "Changing global defaults does not itself rewrite the current cache.")
            preferences.currentWallpaperUsesGlobalPowerRules = true
            #expect(restored.currentWallpaperUsesGlobalPowerRules == true)
            preferences.currentWallpaperUsesGlobalPowerRules = nil
            #expect(restored.currentWallpaperUsesGlobalPowerRules == nil)
            preferences.legacyCurrentWallpaperID = nil
            #expect(restored.legacyCurrentWallpaperID == nil)
        }
    }

    @Test(arguments: [Data("invalid JSON".utf8), Data("{}".utf8),
                      Data("{\"animateOnExternalPower\":\"false\",\"animateOnBattery\":true,\"pauseInLowPowerMode\":true,\"pauseWhenCovered\":true}".utf8)])
    func invalidStoredGlobalRulesFallBackWithoutDestroyingLegacyValues(_ malformed: Data) throws {
        try withIsolatedDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            preferences.animateOnBattery = true
            defaults.set(malformed, forKey: "globalPowerRules")
            #expect(!preferences.hasStoredGlobalPowerRules)
            #expect(preferences.globalPowerRules.animateOnBattery)
            #expect(defaults.data(forKey: "globalPowerRules") == malformed)
            preferences.globalPowerRules = preferences.globalPowerRules
            #expect(preferences.hasStoredGlobalPowerRules && preferences.globalPowerRules.animateOnBattery)
            #expect(preferences.animateOnBattery)
        }
    }

    @Test
    func testFirstLaunchIsSilentAndDoesNotEnableMissingWallpaper() throws {
        try withIsolatedDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            #expect(preferences.target == .all)
            #expect(preferences.scaling == .fill)
            #expect(preferences.isMuted)
            #expect(preferences.pauseInLowPowerMode)
            #expect(preferences.pauseWhenCovered)
            #expect(preferences.animateOnExternalPower)
            #expect(!preferences.animateOnBattery)
            #expect(preferences.restoreOnLaunch)
            #expect(!preferences.userPaused)
            #expect(!preferences.wallpaperEnabled)
            #expect(preferences.videoBookmark == nil)
        }
    }

    @Test
    func testSettingsAndManualPauseSurviveASeparatePreferencesInstance() throws {
        try withIsolatedDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            preferences.target = .main
            preferences.scaling = .fit
            preferences.isMuted = false
            preferences.pauseInLowPowerMode = false
            preferences.pauseWhenCovered = false
            preferences.animateOnExternalPower = false
            preferences.animateOnBattery = true
            preferences.restoreOnLaunch = false
            preferences.userPaused = true
            preferences.wallpaperEnabled = true
            let bookmark = Data([0x31, 0x41, 0x59])
            preferences.videoBookmark = bookmark

            let restored = WallpaperPreferences(defaults: defaults)
            #expect(restored.target == .main)
            #expect(restored.scaling == .fit)
            #expect(!restored.isMuted, "An explicitly disabled setting must not fall back to true.")
            #expect(!restored.pauseInLowPowerMode)
            #expect(!restored.pauseWhenCovered)
            #expect(!restored.animateOnExternalPower)
            #expect(restored.animateOnBattery)
            #expect(!restored.restoreOnLaunch)
            #expect(restored.userPaused)
            #expect(restored.wallpaperEnabled)
            #expect(restored.videoBookmark == bookmark)
        }
    }

    @Test
    func addingPowerProfilesKeepsExistingSettingsAndManualPause() throws {
        try withIsolatedDefaults { defaults in
            // Simulate preferences saved by the version before power profiles existed.
            defaults.set(true, forKey: "userPaused")
            defaults.set(false, forKey: "isMuted")
            defaults.set(false, forKey: "restoreOnLaunch")
            defaults.set("main", forKey: "displayTarget")
            let bookmark = Data([0x44, 0x55])
            defaults.set(bookmark, forKey: "videoBookmark")

            let preferences = WallpaperPreferences(defaults: defaults)
            #expect(preferences.animateOnExternalPower)
            #expect(!preferences.animateOnBattery)
            #expect(preferences.userPaused)
            #expect(!preferences.isMuted)
            #expect(!preferences.restoreOnLaunch)
            #expect(preferences.target == .main)
            #expect(preferences.videoBookmark == bookmark)

            preferences.animateOnBattery = true
            preferences.animateOnExternalPower = false
            #expect(preferences.userPaused)
            #expect(preferences.videoBookmark == bookmark)
        }
    }

    @Test
    func testUnknownStoredEnumValuesFallBackToSupportedOptions() throws {
        try withIsolatedDefaults { defaults in
            defaults.set("disconnected-display-from-another-version", forKey: "displayTarget")
            defaults.set("unsupported-scaling-mode", forKey: "videoScaling")
            let preferences = WallpaperPreferences(defaults: defaults)
            #expect(preferences.target == .all)
            #expect(preferences.scaling == .fill)

            preferences.target = .main
            preferences.scaling = .fit
            #expect(preferences.target == .main)
            #expect(preferences.scaling == .fit)
        }
    }

    @Test
    func testStoppingDoesNotDiscardSelectedVideoOrDisplaySettings() throws {
        try withIsolatedDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            let bookmark = Data([0x10, 0x20])
            preferences.videoBookmark = bookmark
            preferences.target = .main
            preferences.wallpaperEnabled = true

            preferences.wallpaperEnabled = false
            let restored = WallpaperPreferences(defaults: defaults)
            #expect(!restored.wallpaperEnabled)
            #expect(restored.videoBookmark == bookmark)
            #expect(restored.target == .main)
        }
    }

    @Test
    func testBookmarkCanBeClearedWithoutAffectingOtherSettings() throws {
        try withIsolatedDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            preferences.videoBookmark = Data([0x01])
            preferences.isMuted = false
            preferences.videoBookmark = nil

            #expect(WallpaperPreferences(defaults: defaults).videoBookmark == nil)
            #expect(!preferences.isMuted)
        }
    }

    @Test
    func testPreferenceDomainsAreIsolated() throws {
        try withIsolatedDefaults { first in
            try withIsolatedDefaults { second in
                let firstPreferences = WallpaperPreferences(defaults: first)
                let secondPreferences = WallpaperPreferences(defaults: second)
                firstPreferences.isMuted = false
                firstPreferences.videoBookmark = Data([0x55])

                #expect(secondPreferences.isMuted)
                #expect(secondPreferences.videoBookmark == nil)
            }
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let domain = "MyWallpaperTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults)
    }
}
