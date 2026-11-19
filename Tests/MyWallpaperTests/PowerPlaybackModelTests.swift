import Combine
import Foundation
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct PowerPlaybackModelTests {
    @Test(arguments: [PowerSource.external, .battery, .unknown])
    func readsInitialPowerSourceWithoutWaitingForANotification(_ source: PowerSource) throws {
        try withPreferences { preferences in
            let monitor = FakePowerMonitor(source)
            let model = makeModel(preferences, monitor: monitor)
            defer { model.shutDown() }

            #expect(model.powerSource == source)
            #expect(model.animateOnExternalPower)
            #expect(!model.animateOnBattery)
            #expect(!model.userPaused)
            #expect(!model.hasWallpaper)
            #expect(model.selectedURL == nil)
        }
    }

    @Test
    func powerChangesReachTheModelWithoutChangingSavedProfiles() throws {
        try withPreferences { preferences in
            let monitor = FakePowerMonitor(.external)
            let model = makeModel(preferences, monitor: monitor)
            defer { model.shutDown() }

            for source in [PowerSource.battery, .external, .unknown, .battery] {
                monitor.send(source)
                #expect(model.powerSource == source)
                #expect(model.animateOnExternalPower)
                #expect(!model.animateOnBattery)
                #expect(preferences.animateOnExternalPower)
                #expect(!preferences.animateOnBattery)
                #expect(!model.userPaused)
            }
        }
    }

    @Test
    func customProfilesPersistAcrossModelInstancesAndPowerChanges() throws {
        try withPreferences { preferences in
            let monitor = FakePowerMonitor(.battery)
            do {
                let model = makeModel(preferences, monitor: monitor)
                defer { model.shutDown() }
                model.animateOnExternalPower = false
                model.animateOnBattery = true
                monitor.send(.external)
                #expect(!model.animateOnExternalPower)
                #expect(model.animateOnBattery)
            }

            let restored = makeModel(preferences, monitor: FakePowerMonitor(.unknown))
            defer { restored.shutDown() }
            #expect(!restored.animateOnExternalPower)
            #expect(restored.animateOnBattery)
            #expect(!preferences.animateOnExternalPower)
            #expect(preferences.animateOnBattery)
        }
    }

    @Test
    func sourceEventsAndProfileChangesNeverRemoveSavedManualPause() throws {
        try withPreferences { preferences in
            preferences.userPaused = true
            let monitor = FakePowerMonitor(.battery)
            let model = makeModel(preferences, monitor: monitor)
            defer { model.shutDown() }

            model.animateOnBattery = true
            model.animateOnExternalPower = false
            for source in [PowerSource.external, .battery, .unknown, .external] {
                monitor.send(source)
                #expect(model.powerSource == source)
                #expect(model.userPaused)
                #expect(preferences.userPaused)
                #expect(model.pauseReason == "На паузе")
                #expect(!model.isPlaying)
            }
        }
    }

    @Test(arguments: [PowerSource.external, .battery, .unknown])
    func explicitPlayOfAStoppedSelectionEnablesOnlyItsCurrentProfile(_ source: PowerSource) throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyWallpaperPowerSelection-\(UUID().uuidString).txt")
        try Data("Deliberately not media: this test must never create a video window.".utf8).write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try withPreferences { preferences in
            preferences.restoreOnLaunch = false
            preferences.animateOnExternalPower = false
            preferences.animateOnBattery = false
            preferences.videoBookmark = try fixture.bookmarkData(options: [],
                                                                 includingResourceValuesForKeys: nil, relativeTo: nil)
            let model = makeModel(preferences, monitor: FakePowerMonitor(source))
            defer { model.shutDown() }
            model.restore()
            try #require(model.selectedURL != nil, "Require a selection so Play cannot open a file dialog.")
            #expect(!model.hasWallpaper)

            model.togglePlayback()

            #expect(model.animateOnBattery == (source == .battery))
            #expect(preferences.animateOnBattery == (source == .battery))
            #expect(model.animateOnExternalPower == (source != .battery))
            #expect(preferences.animateOnExternalPower == (source != .battery))
            #expect(!model.hasWallpaper, "No video is decoded or displayed by this profile-action test.")
        }
    }

    @Test
    func initializingAndUpdatingPowerDoesNotOverwriteUnrelatedSettings() throws {
        try withPreferences { preferences in
            preferences.target = .main
            preferences.scaling = .fit
            preferences.isMuted = false
            preferences.pauseInLowPowerMode = false
            preferences.pauseWhenCovered = false
            preferences.restoreOnLaunch = false
            preferences.wallpaperEnabled = true
            let bookmark = Data([0x11, 0x22])
            preferences.videoBookmark = bookmark
            let monitor = FakePowerMonitor(.external)
            let model = makeModel(preferences, monitor: monitor)
            defer { model.shutDown() }

            monitor.send(.battery)
            model.animateOnBattery = true
            monitor.send(.external)
            #expect(model.target == .main && preferences.target == .main)
            #expect(model.scaling == .fit && preferences.scaling == .fit)
            #expect(!model.isMuted && !preferences.isMuted)
            #expect(!model.pauseInLowPowerMode && !preferences.pauseInLowPowerMode)
            #expect(!model.pauseWhenCovered && !preferences.pauseWhenCovered)
            #expect(!model.restoreOnLaunch && !preferences.restoreOnLaunch)
            #expect(preferences.wallpaperEnabled)
            #expect(preferences.videoBookmark == bookmark)
        }
    }

    private func makeModel(_ preferences: WallpaperPreferences, monitor: FakePowerMonitor) -> WallpaperModel {
        let loginItems = LoginItemController(service: PassiveLoginService(), notificationCenter: NotificationCenter())
        return WallpaperModel(preferences: preferences, loginItems: loginItems, powerMonitor: monitor)
    }

    private func withPreferences(_ body: (WallpaperPreferences) throws -> Void) throws {
        let domain = "PowerPlaybackModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(WallpaperPreferences(defaults: defaults))
    }
}

@MainActor
private final class FakePowerMonitor: PowerSourceMonitoring {
    private let subject: CurrentValueSubject<PowerSource, Never>
    var source: PowerSource { subject.value }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { subject.eraseToAnyPublisher() }

    init(_ source: PowerSource) { subject = CurrentValueSubject(source) }
    func send(_ source: PowerSource) { subject.send(source) }
}

@MainActor
private final class PassiveLoginService: LoginItemServicing {
    var status: LoginItemStatus { .disabled }
    func register() throws { Issue.record("Power tests must not request login registration.") }
    func unregister() throws { Issue.record("Power tests must not request login removal.") }
    func openSystemSettings() { Issue.record("Power tests must not open System Settings.") }
}
