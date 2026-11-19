import Combine
import Foundation
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct AudioPreferencesModelTests {
    @Test
    func existingPreferencesKeepTheirMuteSettingWhenVolumeIsIntroduced() throws {
        try withDefaults { defaults in
            defaults.set(false, forKey: "isMuted")
            let preferences = WallpaperPreferences(defaults: defaults)
            #expect(preferences.volume == 1)
            #expect(!preferences.isMuted)
            #expect(!preferences.wallpaperEnabled)
        }
    }

    @Test
    func storedVolumeIsValidatedBeforeItReachesTheModel() throws {
        try withDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            for (stored, expected) in [(-2.0, 0.0), (0.25, 0.25), (3.0, 1.0)] {
                defaults.set(stored, forKey: "videoVolume")
                #expect(preferences.volume == expected)
            }
            defaults.set("invalid volume", forKey: "videoVolume")
            #expect(preferences.volume == 1)
            let model = makeModel(defaults)
            defer { model.shutDown() }
            #expect(model.volume == 1)
            #expect(model.isMuted)
            #expect(!model.hasWallpaper && !model.isPlaying)
        }
    }

    @Test
    func muteAndVolumePersistIndependentlyAcrossPreferencesInstances() throws {
        try withDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            preferences.volume = 0.375
            #expect(preferences.isMuted)
            preferences.isMuted = false
            #expect(preferences.volume == 0.375)
            preferences.isMuted = true

            let restored = WallpaperPreferences(defaults: defaults)
            #expect(restored.volume == 0.375)
            #expect(restored.isMuted)
            restored.volume = 0
            restored.isMuted = false
            #expect(restored.volume == 0, "Unmuting must preserve an explicitly silent level.")
        }
    }

    @Test
    func modelAudioChangesPersistWithoutSelectingOrStartingWallpaper() throws {
        try withDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            preferences.userPaused = true
            preferences.animateOnExternalPower = false
            preferences.animateOnBattery = false
            let model = makeModel(defaults)
            defer { model.shutDown() }

            model.volume = 0.25
            #expect(model.isMuted && preferences.isMuted)
            model.isMuted = false
            #expect(model.volume == 0.25 && preferences.volume == 0.25)
            model.volume = 0.75
            #expect(!model.isMuted && !preferences.isMuted)
            model.isMuted = true
            #expect(model.volume == 0.75 && preferences.volume == 0.75)

            #expect(model.userPaused && preferences.userPaused)
            #expect(!model.animateOnExternalPower && !model.animateOnBattery)
            #expect(!model.hasWallpaper && !model.isPlaying && !model.isLoading)
            #expect(model.displayCount == 0 && model.occludedDisplayCount == 0)
            #expect(model.selectedURL == nil && preferences.videoBookmark == nil)
            #expect(!preferences.wallpaperEnabled)
        }
    }

    @Test
    func invalidModelVolumeIsNormalizedAndPersistedWithoutUnmuting() throws {
        try withDefaults { defaults in
            let model = makeModel(defaults)
            defer { model.shutDown() }
            let preferences = WallpaperPreferences(defaults: defaults)
            let cases: [(Double, Double)] = [(-2, 0), (3, 1), (.nan, 1), (.infinity, 1), (-.infinity, 1)]
            for (input, expected) in cases {
                model.volume = input
                #expect(model.volume == expected)
                #expect(preferences.volume == expected)
                #expect(model.isMuted && preferences.isMuted)
                #expect(!model.hasWallpaper && !model.isPlaying)
            }
        }
    }

    @Test
    func modelRestoresSavedVolumeAndMuteAfterRelaunch() throws {
        try withDefaults { defaults in
            do {
                let model = makeModel(defaults)
                defer { model.shutDown() }
                model.volume = 0.625
                model.isMuted = false
            }
            let restored = makeModel(defaults)
            defer { restored.shutDown() }
            #expect(restored.volume == 0.625)
            #expect(!restored.isMuted)
            #expect(!restored.hasWallpaper && !restored.isPlaying)
        }
    }

    private func makeModel(_ defaults: UserDefaults) -> WallpaperModel {
        let preferences = WallpaperPreferences(defaults: defaults)
        preferences.language = .russian
        let loginItems = LoginItemController(service: AudioTestLoginService(), notificationCenter: NotificationCenter())
        let updates = UpdateController(currentVersion: "0.5.0", defaults: defaults, transport: { _ in
            Issue.record("Audio preference tests must not check for updates.")
            throw URLError(.cancelled)
        })
        return WallpaperModel(preferences: preferences, loginItems: loginItems,
                              powerMonitor: AudioTestPowerMonitor(), updates: updates)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let domain = "AudioPreferencesModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults)
    }
}

@MainActor
private final class AudioTestPowerMonitor: PowerSourceMonitoring {
    var source: PowerSource { .external }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { Just(.external).eraseToAnyPublisher() }
}

@MainActor
private final class AudioTestLoginService: LoginItemServicing {
    var status: LoginItemStatus { .disabled }
    func register() throws { Issue.record("Audio tests must not register a login item.") }
    func unregister() throws { Issue.record("Audio tests must not remove a login item.") }
    func openSystemSettings() { Issue.record("Audio tests must not open System Settings.") }
}
