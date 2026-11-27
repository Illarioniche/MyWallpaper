import Combine
import Foundation

struct WhatsNewFeature: Identifiable, Equatable, Sendable {
    let symbol: String
    let titleKey: String
    let detailKey: String

    var id: String { titleKey }
}

/// Bundled release notes are matched to the installed application, not a remote latest release.
struct WhatsNewRelease: Equatable, Sendable {
    let version: String
    let build: String
    let titleKey: String
    let subtitleKey: String
    let features: [WhatsNewFeature]

    static let bundled: [Self] = [
        Self(version: "1.0.0", build: "13",
             titleKey: "Первый стабильный выпуск",
             subtitleKey: "Твои обои, понятные настройки и помощь рядом.",
             features: [
                WhatsNewFeature(symbol: "hand.wave.fill",
                                titleKey: "Краткая инструкция",
                                detailKey: "Подсказки помогут добавить видео и найти управление. Их можно снова открыть в «Основные»."),
                WhatsNewFeature(symbol: "info.circle.fill",
                                titleKey: "Понятная пауза и диагностика",
                                detailKey: "Статус объясняет паузу. «Скопировать диагностику» готовит отчёт без путей к файлам и названий видео."),
                WhatsNewFeature(symbol: "globe",
                                titleKey: "Английский по умолчанию",
                                detailKey: "Новые установки запускаются на английском. Ранее выбранный язык сохраняется."),
                WhatsNewFeature(symbol: "moon.stars.fill",
                                titleKey: "Заставки помечены Beta",
                                detailKey: "Работа зависит от версии macOS. Видео за полем ввода пароля не поддерживается.")
             ]),
        Self(version: "0.10.0", build: "12",
             titleKey: "Обновления без лишних шагов",
             subtitleKey: "Всё готово для следующих версий MyWallpaper.",
             features: [
                WhatsNewFeature(symbol: "arrow.down.circle.fill",
                                titleKey: "Обновление прямо в приложении",
                                detailKey: "Нажми «Обновить» — MyWallpaper скачает новую версию и покажет ход загрузки. Обои продолжат работать."),
                WhatsNewFeature(symbol: "checkmark.shield.fill",
                                titleKey: "Проверка перед установкой",
                                detailKey: "Перед заменой приложения проверяется цифровая подпись обновления."),
                WhatsNewFeature(symbol: "arrow.clockwise.circle.fill",
                                titleKey: "Вернись к своим обоям",
                                detailKey: "После установки приложение перезапустится. Коллекции, настройки и состояние обоев сохранятся.")
             ])
    ]
}

@MainActor
final class WhatsNewController: ObservableObject {
    @Published private(set) var shouldPresent = false

    let release: WhatsNewRelease?
    private let installed: InstalledRelease?
    private let defaults: UserDefaults

    init(currentVersion: String? = nil, currentBuild: String? = nil,
         defaults: UserDefaults = .standard, releases: [WhatsNewRelease] = WhatsNewRelease.bundled) {
        self.defaults = defaults
        let version = currentVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = currentBuild ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        installed = InstalledRelease(version: version, build: build)
        release = installed.flatMap { installed in
            releases.first { $0.version == installed.version && $0.build == installed.build }
        }
    }

    /// `wasUpdated` is supplied only after the installer receipt matches this installed build.
    /// A fresh installation establishes a baseline without announcing a nonexistent update.
    @discardableResult
    func recordLaunch(wasUpdated: Bool = false) -> Bool {
        guard let installed else {
            shouldPresent = false
            return false
        }
        let previous = defaults.data(forKey: Keys.lastLaunch)
            .flatMap { try? JSONDecoder().decode(InstalledRelease.self, from: $0) }
            .flatMap { InstalledRelease(version: $0.version, build: $0.build) }
        let upgraded = previous.map { installed.isNewer(than: $0) } ?? false
        if let encoded = try? JSONEncoder().encode(installed) {
            defaults.set(encoded, forKey: Keys.lastLaunch)
        }

        let dismissed = Set(defaults.stringArray(forKey: Keys.dismissed) ?? [])
        let pending = defaults.string(forKey: Keys.pending)
        guard release != nil, !dismissed.contains(installed.id) else {
            defaults.removeObject(forKey: Keys.pending)
            shouldPresent = false
            return false
        }

        shouldPresent = wasUpdated || upgraded || pending == installed.id
        if shouldPresent {
            // If the process quits before the user closes the window, offer the notes next time.
            defaults.set(installed.id, forKey: Keys.pending)
        } else {
            defaults.removeObject(forKey: Keys.pending)
        }
        return shouldPresent
    }

    /// Call for both the window's close button and its in-content dismissal button.
    func dismiss() {
        shouldPresent = false
        defaults.removeObject(forKey: Keys.pending)
        guard let installed, release != nil else { return }
        var dismissed = Set(defaults.stringArray(forKey: Keys.dismissed) ?? [])
        dismissed.insert(installed.id)
        defaults.set(dismissed.sorted(), forKey: Keys.dismissed)
    }

    private struct InstalledRelease: Codable {
        let version: String
        let build: String

        var id: String { "\(version)#\(build)" }

        init?(version: String?, build: String?) {
            guard let version, UpdateVersion(version, requireThreeComponents: true) != nil,
                  !version.hasPrefix("v"), let build, !build.isEmpty,
                  build.utf8.allSatisfy({ (48...57).contains($0) }),
                  build.count == 1 || build.first != "0",
                  let number = UInt64(build), number > 0 else { return nil }
            self.version = version
            self.build = build
        }

        func isNewer(than other: Self) -> Bool {
            guard let version = UpdateVersion(version), let otherVersion = UpdateVersion(other.version),
                  let build = UInt64(build), let otherBuild = UInt64(other.build) else { return false }
            return version >= otherVersion && build > otherBuild
        }
    }

    private enum Keys {
        static let lastLaunch = "updates.whatsNew.lastLaunchedRelease"
        static let pending = "updates.whatsNew.pendingRelease"
        static let dismissed = "updates.whatsNew.dismissedReleases"
    }
}
