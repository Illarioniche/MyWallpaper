import Foundation
import Testing
@testable import MyWallpaper

@Suite
struct WallpaperPowerStorageTests {
    @Test
    func oldLibraryRecordsKeepEverySettingAsAnExplicitPowerExceptionWithoutRewritingFiles() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let saved = WallpaperLibraryOptions(target: .main, scaling: .fit, isMuted: false, volume: 0.23,
            animateOnExternalPower: false, animateOnBattery: true, pauseInLowPowerMode: false,
            pauseWhenCovered: false, syncSystemWallpaper: true, usesGlobalPowerRules: false)
        let entry = try fixture.create(name: "Legacy", options: saved)
        let metadata = fixture.metadata(entry.id)
        var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        var oldEntry = try #require(record["entry"] as? [String: Any])
        var oldOptions = try #require(oldEntry["options"] as? [String: Any])
        oldOptions.removeValue(forKey: "usesGlobalPowerRules")
        oldEntry["options"] = oldOptions
        record["entry"] = oldEntry
        let legacyBytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try legacyBytes.write(to: metadata)
        let library = WallpaperLibrary(rootURL: fixture.library.rootURL)
        let loaded = try library.entry(for: entry.id)
        #expect(loaded.options == saved)
        #expect(!loaded.options.usesGlobalPowerRules)
        #expect(loaded.options.effectivePowerRules(defaults: .init()) == saved.powerRules)
        #expect(try library.list().entries == [loaded])
        #expect(try Data(contentsOf: metadata) == legacyBytes, "Reading an old record must not perform a lossy migration.")
        #expect(try Data(contentsOf: fixture.video) == fixture.videoBytes)

        // A later explicit edit adds the marker, but preserves both behavior and identity.
        let renamed = try library.rename(id: entry.id, name: "Renamed")
        #expect(renamed.options == saved && renamed.id == entry.id)
        #expect(try library.entry(for: entry.id).options == saved)
    }

    @Test
    func newRecordsInheritGlobalRulesAcrossReloadsAndCanOptIntoIndependentRules() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.create()
        let defaults = WallpaperPowerRules(animateOnExternalPower: false, animateOnBattery: true,
                                            pauseInLowPowerMode: false, pauseWhenCovered: false)
        let inherited = try fixture.library.entry(for: entry.id).options
        #expect(inherited.usesGlobalPowerRules)
        #expect(inherited.effectivePowerRules(defaults: defaults) == defaults)
        #expect(inherited.effectivePowerRules(defaults: .init()) == WallpaperPowerRules())

        var custom = inherited
        custom.usesGlobalPowerRules = false
        custom.powerRules = WallpaperPowerRules(animateOnExternalPower: true, animateOnBattery: true,
                                                pauseInLowPowerMode: true, pauseWhenCovered: false)
        _ = try fixture.library.updateOptions(id: entry.id, options: custom)
        let reloaded = try fixture.library.entry(for: entry.id).options
        #expect(reloaded == custom)
        #expect(reloaded.effectivePowerRules(defaults: defaults) == custom.powerRules)
        #expect(reloaded.effectivePowerRules(defaults: .init()) == custom.powerRules)

        var reverted = reloaded
        reverted.usesGlobalPowerRules = true
        _ = try fixture.library.updateOptions(id: entry.id, options: reverted)
        let follows = try fixture.library.entry(for: entry.id).options
        #expect(follows.effectivePowerRules(defaults: defaults) == defaults)
        #expect(follows.powerRules == custom.powerRules, "Turning inheritance on must retain the previous exception values.")
    }

    @Test
    func inheritanceMarkerParticipatesInEqualityAndRoundTripsIndependentlyOfSavedValues() throws {
        let inherited = WallpaperLibraryOptions(volume: 0.37)
        var custom = inherited
        custom.usesGlobalPowerRules = false
        #expect(inherited != custom)
        for options in [inherited, custom] {
            let encoded = try JSONEncoder().encode(options)
            #expect(try JSONDecoder().decode(WallpaperLibraryOptions.self, from: encoded) == options)
        }
    }

    @Test(arguments: ["null", "1", "\"true\"", "{}", "[]"])
    func malformedInheritanceMarkersAreRejectedInsteadOfSilentlyChangingSavedBehavior(_ marker: String) throws {
        let encoded = try JSONEncoder().encode(WallpaperLibraryOptions())
        var dictionary = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        dictionary["usesGlobalPowerRules"] = try JSONSerialization.jsonObject(with: Data(marker.utf8), options: [.fragmentsAllowed])
        let malformed = try JSONSerialization.data(withJSONObject: dictionary)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WallpaperLibraryOptions.self, from: malformed) }
    }
}
