/// Stable pause categories shared by the status explanation and support report.
/// The order is owned by PlaybackPolicy; desktop coverage applies afterwards.
enum WallpaperPauseCause: CaseIterable, Equatable, Sendable {
    case manual, systemSleep, displaySleep, sessionInactive, lowPowerMode
    case batteryRule, externalPowerRule, unknownPowerRule, desktopHidden

    var titleKey: String {
        switch self {
        case .manual: "На паузе"
        case .systemSleep, .displaySleep: "Экран спит"
        case .sessionInactive: "Сеанс неактивен"
        case .lowPowerMode: "Пауза для экономии энергии"
        case .batteryRule: "Статичные обои · от батареи"
        case .externalPowerRule: "Статичные обои · от сети"
        case .unknownPowerRule: "Статичные обои · источник питания неизвестен"
        case .desktopHidden: "Пауза: рабочий стол скрыт"
        }
    }

    var detailKey: String {
        switch self {
        case .manual:
            "Ты поставил обои на паузу. Нажми «Продолжить», чтобы снять ручную паузу. Затем применятся правила питания и видимости рабочего стола."
        case .systemSleep:
            "Mac переходит в режим сна. Видео продолжится после пробуждения, если остальные правила разрешают воспроизведение."
        case .displaySleep:
            "Экраны выключены. Видео продолжится, когда они проснутся, если остальные правила разрешают воспроизведение."
        case .sessionInactive:
            "Сеанс пользователя сейчас неактивен. Видео продолжится после возвращения в сеанс, если остальные правила разрешают воспроизведение."
        case .lowPowerMode:
            "В macOS включён режим энергосбережения. После его выключения снова применятся остальные правила воспроизведения. Правило паузы можно изменить в настройках питания."
        case .batteryRule:
            "От батареи для этих обоев выбран статичный режим. Нажми «Оживить сейчас» для временной анимации. После подключения питания применится правило для сети."
        case .externalPowerRule:
            "От сети для этих обоев выбран статичный режим. Нажми «Оживить сейчас» для временной анимации или измени правило питания."
        case .unknownPowerRule:
            "Источник питания пока неизвестен, поэтому применяется правило для питания от сети: статичный режим. Нажми «Оживить сейчас» для временной анимации."
        case .desktopHidden:
            "Окна закрывают рабочий стол на всех экранах с обоями. Видео возобновится на каждом экране, когда рабочий стол на нём снова станет виден."
        }
    }

    var usesPowerRules: Bool {
        switch self {
        case .lowPowerMode, .batteryRule, .externalPowerRule, .unknownPowerRule, .desktopHidden: true
        case .manual, .systemSleep, .displaySleep, .sessionInactive: false
        }
    }

    func explanation(using localizer: AppLocalizer, usesGlobalPowerRules: Bool) -> String {
        let explanation = localizer.text(detailKey)
        guard usesPowerRules else { return explanation }
        let rulesKey = usesGlobalPowerRules
            ? "Используются общие правила из раздела «Питание»."
            : "Используются индивидуальные правила из редактора этих обоев."
        return explanation + "\n\n" + localizer.text(rulesKey)
    }

    var diagnosticCause: AppDiagnosticSnapshot.PauseCause {
        switch self {
        case .manual: .manual
        case .systemSleep: .systemSleep
        case .displaySleep: .displaySleep
        case .sessionInactive: .sessionInactive
        case .lowPowerMode: .lowPowerMode
        case .batteryRule: .batteryRule
        case .externalPowerRule: .externalPowerRule
        case .unknownPowerRule: .unknownPowerRule
        case .desktopHidden: .desktopHidden
        }
    }

    static func current(policy: PlaybackPolicy, isLoading: Bool, hasWallpaper: Bool,
                        desktopHidden: Bool) -> Self? {
        guard !isLoading, hasWallpaper else { return nil }
        return policy.pauseCause ?? (desktopHidden ? .desktopHidden : nil)
    }
}
