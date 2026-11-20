import AppKit
import Combine
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct SystemWallpaperModelTests {
    @Test
    func existingSettingsDoNotOptIntoChangingTheSystemDesktop() async throws {
        try await withModel { model, preferences, spy in
            #expect(!model.syncSystemWallpaper && !preferences.syncSystemWallpaper)
            model.target = .main
            model.scaling = .fit
            model.volume = 0.3
            model.animateOnBattery = true
            await Task.yield()
            #expect(spy.calls == 0)
            #expect(!model.isSyncingSystemWallpaper)
            #expect(!model.hasWallpaper && !preferences.wallpaperEnabled)
        }
    }

    @Test
    func enablingSyncWithoutAnActiveVideoStoresIntentWithoutChangingDesktop() async throws {
        try await withModel { model, preferences, spy in
            model.syncSystemWallpaper = true
            #expect(preferences.syncSystemWallpaper)
            model.stop()
            await Task.yield()
            #expect(spy.calls == 0)
            #expect(model.syncSystemWallpaper && !model.isSyncingSystemWallpaper)
            #expect(!model.hasWallpaper && model.selectedURL == nil)
            model.syncSystemWallpaper = false
            #expect(!preferences.syncSystemWallpaper)
        }
    }

    private func withModel(_ body: @MainActor (WallpaperModel, WallpaperPreferences, SyncSpy) async throws -> Void) async throws {
        let domain = "SystemWallpaperModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = WallpaperPreferences(defaults: defaults)
        let spy = SyncSpy()
        let updates = UpdateController(currentVersion: "0.6.1", defaults: defaults, transport: { _ in
            Issue.record("Sync preference tests must not request updates.")
            throw URLError(.cancelled)
        })
        let model = WallpaperModel(preferences: preferences,
            loginItems: LoginItemController(service: SyncLoginService(), notificationCenter: NotificationCenter()),
            powerMonitor: SyncPowerMonitor(), updates: updates, systemWallpaperSync: spy)
        defer { model.shutDown() }
        try await body(model, preferences, spy)
    }
}

@MainActor
private final class SyncSpy: SystemWallpaperSyncing {
    private(set) var calls = 0
    func synchronize(image: CGImage, name: String, target: DisplayTarget, scaling: VideoScaling) async throws {
        calls += 1
        Issue.record("No active video: system desktop must stay untouched.")
    }
}

@MainActor
private final class SyncPowerMonitor: PowerSourceMonitoring {
    var source: PowerSource { .external }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { Just(.external).eraseToAnyPublisher() }
}

@MainActor
private final class SyncLoginService: LoginItemServicing {
    var status: LoginItemStatus { .disabled }
    func register() throws { Issue.record("Tests must not change login items.") }
    func unregister() throws { Issue.record("Tests must not change login items.") }
    func openSystemSettings() { Issue.record("Tests must not open System Settings.") }
}
