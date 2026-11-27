import AppKit
import Combine
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct SettingsMenuControllerTests {
    @Test
    func laterHidesMenuReminderAndExplicitCheckOffersTheReleaseAgain() async throws {
        let domain = "SettingsMenuControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let transport = SettingsMenuTestTransport()
        let updates = UpdateController(currentVersion: "0.9.0", defaults: defaults,
                                       transport: { try await transport.fetch($0) })
        let model = WallpaperModel(preferences: WallpaperPreferences(defaults: defaults),
                                   loginItems: LoginItemController(service: SettingsMenuLoginService(),
                                                                   notificationCenter: NotificationCenter()),
                                   powerMonitor: SettingsMenuPowerMonitor(), updates: updates)
        defer { model.shutDown() }
        let controller = SettingsMenuController(model: model)
        var openedUpdates = 0
        controller.onOpenUpdates = { openedUpdates += 1 }
        let menu = controller.makeMenu()
        await updates.checkNow()
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.last?.title == model.localizer.format("Доступна версия %@…", "0.10.0"))

        updates.deferAvailableRelease()
        controller.menuNeedsUpdate(menu)
        let check = try #require(menu.items.last)
        #expect(check.title == model.localizer.text("Проверить обновления…"))
        #expect(check.isEnabled)
        #expect(updates.availableRelease != nil && updates.offeredRelease == nil)
        let target = try #require(check.target as? NSObject)
        let action = try #require(check.action)
        _ = target.perform(action)

        // The menu schedules an async check. Wait for the fake transport, never the network.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (updates.offeredRelease == nil || updates.isChecking) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(openedUpdates == 1)
        #expect(await transport.calls == 2)
        #expect(updates.offeredRelease != nil && !updates.isChecking)
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.last?.title == model.localizer.format("Доступна версия %@…", "0.10.0"))

        // An already offered release only needs navigation, not another request.
        let offered = try #require(menu.items.last)
        _ = target.perform(try #require(offered.action))
        #expect(openedUpdates == 2)
        #expect(await transport.calls == 2)
    }
}

private actor SettingsMenuTestTransport {
    private(set) var calls = 0

    func fetch(_ request: URLRequest) throws -> UpdateHTTPResponse {
        calls += 1
        let data = Data("""
        {"tag_name":"v0.10.0","name":"MyWallpaper","body":"Notes","draft":false,"prerelease":false,
        "html_url":"https://github.com/Illarioniche/MyWallpaper/releases/tag/v0.10.0","assets":[]}
        """.utf8)
        return UpdateHTTPResponse(data: data, statusCode: 200, finalURL: try #require(request.url))
    }
}

@MainActor
private final class SettingsMenuLoginService: LoginItemServicing {
    var status: LoginItemStatus { .disabled }
    func register() throws { Issue.record("The update menu must not change login items.") }
    func unregister() throws { Issue.record("The update menu must not change login items.") }
    func openSystemSettings() { Issue.record("The update menu must not open System Settings.") }
}

@MainActor
private final class SettingsMenuPowerMonitor: PowerSourceMonitoring {
    var source: PowerSource { .external }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { Just(.external).eraseToAnyPublisher() }
}
