import Foundation

enum DisplayTarget: String, CaseIterable, Identifiable {
    case all, main
    var id: String { rawValue }
    var title: String { self == .all ? "Все экраны" : "Основной экран" }
}

enum VideoScaling: String, CaseIterable, Identifiable {
    case fill, fit
    var id: String { rawValue }
    var title: String { self == .fill ? "Заполнить" : "Вместить" }
}

/// Separate temporary system pauses from the user's intent to play.
struct PlaybackPolicy {
    var userPaused = false
    var systemSleeping = false
    var screensSleeping = false
    var sessionInactive = false
    var lowPowerMode = false
    var pauseInLowPowerMode = true
    var powerSource: PowerSource = .external
    var animateOnExternalPower = true
    var animateOnBattery = false

    var animatesOnCurrentPowerSource: Bool {
        // Missing power readings should not unexpectedly freeze a desktop Mac.
        powerSource == .battery ? animateOnBattery : animateOnExternalPower
    }

    var shouldPlay: Bool {
        !userPaused && !systemSleeping && !screensSleeping && !sessionInactive
            && !(lowPowerMode && pauseInLowPowerMode) && animatesOnCurrentPowerSource
    }

    var pauseReason: String? {
        if userPaused { return "На паузе" }
        if systemSleeping || screensSleeping { return "Экран спит" }
        if sessionInactive { return "Сеанс неактивен" }
        if lowPowerMode && pauseInLowPowerMode { return "Пауза для экономии энергии" }
        if !animatesOnCurrentPowerSource {
            switch powerSource {
            case .battery: return "Статичные обои · от батареи"
            case .external: return "Статичные обои · от сети"
            case .unknown: return "Статичные обои · источник питания неизвестен"
            }
        }
        return nil
    }
}

struct WallpaperPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var target: DisplayTarget {
        get { DisplayTarget(rawValue: defaults.string(forKey: "displayTarget") ?? "") ?? .all }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "displayTarget") }
    }

    var scaling: VideoScaling {
        get { VideoScaling(rawValue: defaults.string(forKey: "videoScaling") ?? "") ?? .fill }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "videoScaling") }
    }

    var isMuted: Bool {
        get { defaults.object(forKey: "isMuted") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "isMuted") }
    }

    var pauseInLowPowerMode: Bool {
        get { defaults.object(forKey: "pauseInLowPowerMode") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "pauseInLowPowerMode") }
    }

    var pauseWhenCovered: Bool {
        get { defaults.object(forKey: "pauseWhenCovered") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "pauseWhenCovered") }
    }

    var animateOnExternalPower: Bool {
        get { defaults.object(forKey: "animateOnExternalPower") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "animateOnExternalPower") }
    }

    var animateOnBattery: Bool {
        get { defaults.object(forKey: "animateOnBattery") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "animateOnBattery") }
    }

    var restoreOnLaunch: Bool {
        get { defaults.object(forKey: "restoreOnLaunch") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "restoreOnLaunch") }
    }

    var userPaused: Bool {
        get { defaults.bool(forKey: "userPaused") }
        nonmutating set { defaults.set(newValue, forKey: "userPaused") }
    }

    var wallpaperEnabled: Bool {
        get { defaults.bool(forKey: "wallpaperEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "wallpaperEnabled") }
    }

    var videoBookmark: Data? {
        get { defaults.data(forKey: "videoBookmark") }
        nonmutating set { defaults.set(newValue, forKey: "videoBookmark") }
    }
}
