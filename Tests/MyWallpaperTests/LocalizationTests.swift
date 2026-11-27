import Foundation
import Testing
@testable import MyWallpaper

@Suite
struct LocalizationTests {
    @Test
    func defaultLanguageIsEnglishEvenOnARussianSystem() {
        let localizer = AppLocalizer(preferredLanguages: ["ru-RU", "en-US"])
        #expect(localizer.language == .english)
        #expect(localizer.resolvedCode == "en")
        #expect(localizer == .english)
        #expect(localizer.text("Системный") == "System")
    }

    @Test
    func systemLanguageUsesTheFirstSupportedPreferenceIncludingRegionalIdentifiers() {
        #expect(AppLocalizer(language: .system, preferredLanguages: ["fr-FR", "ru-RU", "en-US"]).resolvedCode == "ru")
        #expect(AppLocalizer(language: .system, preferredLanguages: ["en-GB", "ru"]).resolvedCode == "en")
        #expect(AppLocalizer(language: .system, preferredLanguages: ["RU_ru", "en"]).resolvedCode == "ru")
        #expect(AppLocalizer(language: .system, preferredLanguages: ["fr", "de"]).resolvedCode == "en")
        #expect(AppLocalizer(language: .system, preferredLanguages: []).resolvedCode == "en")
        #expect(AppLocalizer(language: .system, preferredLanguages: ["russian", "eng"]).resolvedCode == "en")
    }

    @Test
    func explicitChoiceOverridesSystemPreferencesAndKeepsItsIdentity() {
        let russian = AppLocalizer(language: .russian, preferredLanguages: ["en-US"])
        let english = AppLocalizer(language: .english, preferredLanguages: ["ru-RU"])
        let system = AppLocalizer(language: .system, preferredLanguages: ["ru-RU"])
        #expect(russian.resolvedCode == "ru")
        #expect(english.resolvedCode == "en")
        #expect(system.language == .system)
        #expect(russian.language == .russian)
        #expect(russian != system, "An explicit choice remains distinct from following the system.")
        #expect(russian.locale.language.languageCode?.identifier == "ru")
        #expect(english.locale.language.languageCode?.identifier == "en")
        #expect(AppLanguage(rawValue: "ru") == .russian)
        #expect(AppLanguage(rawValue: "en") == .english)
        #expect(AppLanguage(rawValue: "system") == .system)
    }

    @Test
    func languageChoicesKeepNativeNamesAndLocalizeSystemChoice() {
        let english = AppLocalizer(language: .english)
        #expect(AppLanguage.russian.title(using: english) == "Русский")
        #expect(AppLanguage.english.title(using: .russian) == "English")
        #expect(AppLanguage.system.title(using: .russian) == "Системный")
        #expect(AppLanguage.system.title(using: english) == "System")
    }

    @Test
    func explicitCatalogLookupDoesNotDependOnProcessLanguageAndMissingKeysRemainReadable() {
        let english = AppLocalizer(language: .english)
        let key = "GitHub не ответил вовремя. Попробуй ещё раз."
        #expect(AppLocalizer.russian.text(key) == key)
        #expect(english.text(key) != key, "The English resource table must load, including in SwiftPM tests.")
        #expect(english.text("Missing localization fixture") == "Missing localization fixture")
        #expect(AppLocalizer.russian.text("Missing localization fixture") == "Missing localization fixture")
    }

    @Test
    func formattingKeepsInterpolatedValuesSeparateFromLocalizedTemplates() {
        let key = "Не удалось включить автозапуск. %@"
        let detail = "Permission 50% denied"
        let english = AppLocalizer(language: .english)
        let rendered = english.format(key, detail)
        #expect(rendered != AppLocalizer.russian.format(key, detail))
        #expect(rendered.hasSuffix(detail))
        #expect(!rendered.contains("%@"))
        #expect(AppLocalizer.russian.format(key, detail) == "Не удалось включить автозапуск. Permission 50% denied")
    }
}
