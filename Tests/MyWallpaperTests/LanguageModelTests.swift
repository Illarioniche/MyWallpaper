import AppKit
import Combine
import Foundation
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct LanguageModelTests {
    @Test
    func preferenceDefaultsToSystemAndPersistsWithoutChangingExistingSettings() throws {
        try withDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            #expect(preferences.language == .system)
            defaults.set("unsupported", forKey: "appLanguage")
            #expect(preferences.language == .system)
            preferences.isMuted = true
            preferences.volume = 0.25
            preferences.userPaused = true
            preferences.language = .english
            let restored = WallpaperPreferences(defaults: defaults)
            #expect(restored.language == .english)
            #expect(restored.volume == 0.25)
            #expect(restored.isMuted && restored.userPaused)
        }
    }

    @Test
    func switchingLanguageUpdatesExistingMessagesAndMenusWithoutStartingPlayback() throws {
        try withDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            preferences.language = .russian
            preferences.userPaused = true
            preferences.volume = 0.25
            let model = makeModel(preferences, defaults: defaults)
            defer { model.shutDown() }
            model.selectVideo(URL(string: "https://example.invalid/not-a-local-file.mp4")!)
            #expect(model.errorMessage == "Выбери видео, сохранённое на этом Mac.")
            let menu = SettingsMenuController(model: model)
            #expect(menu.makeMenu().title == "Настройки")

            model.language = .english
            #expect(model.errorMessage == AppLocalizer(language: .english).text("Выбери видео, сохранённое на этом Mac."))
            #expect(model.errorMessage != "Выбери видео, сохранённое на этом Mac.")
            #expect(menu.makeMenu().title == "Settings")
            #expect(model.loginItems.localizer.resolvedCode == "en")
            #expect(model.updates.localizer.resolvedCode == "en")
            #expect(model.userPaused && model.isMuted)
            #expect(model.volume == 0.25 && preferences.volume == 0.25)
            #expect(!model.isPlaying && !model.hasWallpaper)
            #expect(model.selectedURL == nil)

            model.language = .russian
            #expect(model.errorMessage == "Выбери видео, сохранённое на этом Mac.")
            #expect(model.pauseReason == "На паузе")
            model.errorMessage = nil
            model.language = .english
            #expect(model.errorMessage == nil, "Dismissed messages must not reappear on a language switch.")
        }
    }

    @Test
    func languageChangeDoesNotReplaceANewerPlaybackErrorWithAnOldLoginFailure() throws {
        try withDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            preferences.language = .russian
            let login = LoginItemController(service: LanguageLoginService(), notificationCenter: NotificationCenter())
            let model = makeModel(preferences, defaults: defaults, login: login)
            defer { model.shutDown() }
            model.setLaunchAtLogin(true)
            #expect(model.errorMessage != nil)
            model.selectVideo(URL(string: "https://example.invalid/file.mp4")!)
            model.language = .english
            #expect(model.errorMessage == AppLocalizer(language: .english).text("Выбери видео, сохранённое на этом Mac."))
        }
    }

    @Test
    func runtimePlaybackErrorsTranslateTheirPrefixAndPreserveSystemDetails() throws {
        try withDefaults { defaults in
            let preferences = WallpaperPreferences(defaults: defaults)
            preferences.language = .russian
            let model = makeModel(preferences, defaults: defaults)
            defer { model.shutDown() }
            let key = "Не удалось воспроизвести видео. Попробуйте выбрать другой файл."
            let detail = "Decoder detail: 50% complete"
            model.engine.onPlaybackError?(key, detail)
            #expect(model.errorMessage == key + "\n\n" + detail)
            model.language = .english
            #expect(model.errorMessage == AppLocalizer(language: .english).text(key) + "\n\n" + detail)
            #expect(model.errorMessage?.hasPrefix(key) == false)
            model.language = .russian
            #expect(model.errorMessage == key + "\n\n" + detail)
            #expect(!model.hasWallpaper && !model.isPlaying)
        }
    }

    private func makeModel(_ preferences: WallpaperPreferences, defaults: UserDefaults,
                           login: LoginItemController? = nil) -> WallpaperModel {
        WallpaperModel(preferences: preferences,
                       loginItems: login ?? LoginItemController(service: LanguageLoginService(), notificationCenter: NotificationCenter()),
                       powerMonitor: LanguagePowerMonitor(),
                       updates: UpdateController(currentVersion: "0.5.0", defaults: defaults, transport: { _ in
                           Issue.record("Changing settings must not check for updates.")
                           throw URLError(.cancelled)
                       }))
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let domain = "LanguageModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try body(defaults)
    }
}

@MainActor
private final class LanguageLoginService: LoginItemServicing {
    var status: LoginItemStatus { .disabled }
    func register() throws { throw CocoaError(.featureUnsupported) }
    func unregister() throws { Issue.record("Language selection must not unregister login items.") }
    func openSystemSettings() { Issue.record("Language selection must not open System Settings.") }
}

@MainActor
private final class LanguagePowerMonitor: PowerSourceMonitoring {
    var source: PowerSource { .external }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { Just(.external).eraseToAnyPublisher() }
}
