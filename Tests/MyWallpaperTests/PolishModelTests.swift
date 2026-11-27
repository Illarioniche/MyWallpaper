import AppKit
import Combine
import Foundation
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct PolishModelTests {
    @Test
    func quickStartDismissalSurvivesRelaunchAndManualReopeningPreservesPreferences() throws {
        try withFixture { preferences, defaults, root in
            preferences.language = .russian
            preferences.userPaused = true
            preferences.isMuted = false
            preferences.volume = 0.25
            preferences.scaling = .fit
            preferences.animateOnBattery = true
            let model = makeModel(preferences, defaults: defaults, root: root)
            defer { model.shutDown() }
            #expect(model.showsQuickStart)
            #expect(!preferences.hasSeenQuickStart)
            #expect(!model.hasWallpaper && model.selectedURL == nil)
            model.dismissQuickStart()
            #expect(!model.showsQuickStart && preferences.hasSeenQuickStart)
            model.showQuickStart()
            #expect(model.showsQuickStart && preferences.hasSeenQuickStart)
            let restored = makeModel(preferences, defaults: defaults, root: root)
            defer { restored.shutDown() }
            #expect(!restored.showsQuickStart, "Reopening help must not reset the first-launch marker.")
            #expect(preferences.language == .russian && preferences.userPaused)
            #expect(!preferences.isMuted && preferences.volume == 0.25)
            #expect(preferences.scaling == .fit && preferences.animateOnBattery)
            #expect(!model.hasWallpaper && !restored.hasWallpaper)
        }
    }

    @Test(arguments: [false, true])
    func existingSetupSkipsAutomaticQuickStartWithoutLosingTheSelection(_ hasLibraryEntry: Bool) throws {
        try withFixture { preferences, defaults, root in
            let entryID = UUID()
            let bookmark = Data([0x11, 0x22])
            if hasLibraryEntry { preferences.activeWallpaperID = entryID }
            else { preferences.videoBookmark = bookmark }
            preferences.wallpaperEnabled = true
            preferences.userPaused = true
            let model = makeModel(preferences, defaults: defaults, root: root)
            defer { model.shutDown() }
            #expect(!model.showsQuickStart && preferences.hasSeenQuickStart)
            #expect(preferences.activeWallpaperID == (hasLibraryEntry ? entryID : nil))
            #expect(preferences.videoBookmark == (hasLibraryEntry ? nil : bookmark))
            #expect(preferences.wallpaperEnabled && preferences.userPaused)
            #expect(!model.hasWallpaper, "Initializing help must not restore video by itself.")
        }
    }

    @Test
    func diagnosticsAndExplanationUseLoadingAndStoppedStatusBeforeSavedPause() throws {
        try withFixture { preferences, defaults, root in
            preferences.userPaused = true
            preferences.restoreOnLaunch = false
            let fixture = root.appendingPathComponent("Private Video.txt")
            try Data("Not media; this test must not create a wallpaper window.".utf8).write(to: fixture)
            preferences.videoBookmark = try fixture.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let model = makeModel(preferences, defaults: defaults, root: root)
            defer { model.shutDown() }
            #expect(model.diagnosticSnapshot.playback == .empty)
            #expect(model.currentPauseCause == nil && model.playbackExplanation == nil)
            model.restore()
            #expect(model.diagnosticSnapshot.playback == .stopped)
            #expect(model.diagnosticSnapshot.pauseCause == .none)
            #expect(model.currentPauseCause == nil)
            model.togglePlayback()
            #expect(model.isLoading)
            #expect(model.diagnosticSnapshot.playback == .loading)
            #expect(model.currentPauseCause == nil && model.playbackExplanation == nil)
            #expect(model.diagnosticSnapshot.userPaused)
            model.stop()
            #expect(model.diagnosticSnapshot.playback == .stopped)
            #expect(model.diagnosticSnapshot.pauseCause == .none)
        }
    }

    @Test
    func diagnosticsReportsIndividualRulesAndErrorAreasWithoutPrivateDetails() throws {
        try withFixture { preferences, defaults, root in
            preferences.globalPowerRules = WallpaperPowerRules()
            preferences.currentWallpaperUsesGlobalPowerRules = false
            preferences.animateOnBattery = true
            preferences.animateOnExternalPower = false
            let model = makeModel(preferences, defaults: defaults, root: root)
            defer { model.shutDown() }
            model.setLaunchAtLogin(true)
            #expect(model.diagnosticSnapshot.failures == [.login])
            model.errorMessage = "Could not read /Users/Alice/Movies/Private Video.mp4?token=secret"
            let snapshot = model.diagnosticSnapshot
            #expect(snapshot.failures == [.login, .wallpaper])
            #expect(!snapshot.usesGlobalPowerRules)
            #expect(snapshot.effectivePowerRules.animateOnBattery && !snapshot.effectivePowerRules.animateOnExternalPower)
            #expect(snapshot.loginStatus == .disabled && snapshot.loginAvailability == .available)
            #expect(snapshot.powerSource == .battery)
            let report = snapshot.formattedText()
            #expect(!report.contains("Alice") && !report.contains("Private Video") && !report.contains("secret"))
            #expect(!report.contains(root.path))
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            #expect(model.copyDiagnostics(to: pasteboard))
            #expect(pasteboard.string(forType: .string) == report)
        }
    }

    private func withFixture(_ body: (WallpaperPreferences, UserDefaults, URL) throws -> Void) throws {
        let name = "PolishModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        try body(WallpaperPreferences(defaults: defaults), defaults, root)
    }

    private func makeModel(_ preferences: WallpaperPreferences, defaults: UserDefaults, root: URL) -> WallpaperModel {
        WallpaperModel(preferences: preferences,
            loginItems: LoginItemController(service: PolishLoginService(), notificationCenter: NotificationCenter()),
            powerMonitor: PolishPowerMonitor(),
            updates: UpdateController(currentVersion: "0.10.0", defaults: defaults, transport: { _ in
                Issue.record("Help and diagnostics must not start network requests."); throw URLError(.cancelled)
            }),
            screenSaver: ScreenSaverController(templateURL: nil, library: .init(rootURL: root.appendingPathComponent("Savers"))),
            wallpaperLibrary: WallpaperLibraryController(library: .init(rootURL: root.appendingPathComponent("Wallpapers"))),
            screenSaverSync: ScreenSaverSyncController(store: .init(rootURL: root.appendingPathComponent("Sync")),
                templateURL: nil, installationLookup: { _ in nil }, openInstaller: { _ in
                    Issue.record("Help and diagnostics must not open an installer."); return false
                }))
    }
}

@MainActor
private final class PolishLoginService: LoginItemServicing {
    var status: LoginItemStatus { .disabled }
    var availability: LoginItemAvailability { .available }
    func register() throws { throw CocoaError(.featureUnsupported) }
    func unregister() throws { Issue.record("Help and diagnostics must not remove login items.") }
    func openSystemSettings() { Issue.record("Help and diagnostics must not open System Settings.") }
}

@MainActor
private final class PolishPowerMonitor: PowerSourceMonitoring {
    var source: PowerSource { .battery }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { Just(.battery).eraseToAnyPublisher() }
}
