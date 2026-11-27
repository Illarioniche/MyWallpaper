import Foundation

enum DisplayTarget: String, CaseIterable, Identifiable, Codable, Sendable {
    case all, main
    var id: String { rawValue }
    var title: String { self == .all ? "Все экраны" : "Основной экран" }
}

enum VideoScaling: String, CaseIterable, Identifiable, Codable, Sendable {
    case fill, fit
    var id: String { rawValue }
    var title: String { self == .fill ? "Заполнить" : "Вместить" }
}

/// App-wide defaults and optional per-wallpaper exceptions share the same rules.
struct WallpaperPowerRules: Codable, Equatable, Sendable {
    var animateOnExternalPower = true
    var animateOnBattery = false
    var pauseInLowPowerMode = true
    var pauseWhenCovered = true
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
    var temporaryAnimationOverride = false

    var animatesOnCurrentPowerSource: Bool {
        // Missing power readings should not unexpectedly freeze a desktop Mac.
        temporaryAnimationOverride || (powerSource == .battery ? animateOnBattery : animateOnExternalPower)
    }

    var shouldPlay: Bool {
        !userPaused && !systemSleeping && !screensSleeping && !sessionInactive
            && !(lowPowerMode && pauseInLowPowerMode) && animatesOnCurrentPowerSource
    }

    var pauseCause: WallpaperPauseCause? {
        if userPaused { return .manual }
        if systemSleeping { return .systemSleep }
        if screensSleeping { return .displaySleep }
        if sessionInactive { return .sessionInactive }
        if lowPowerMode && pauseInLowPowerMode { return .lowPowerMode }
        if !animatesOnCurrentPowerSource {
            switch powerSource {
            case .battery: return .batteryRule
            case .external: return .externalPowerRule
            case .unknown: return .unknownPowerRule
            }
        }
        return nil
    }

    var pauseReason: String? { pauseCause?.titleKey }

}

struct WallpaperPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Reading legacy values does not rewrite preferences. The model explicitly
    /// seeds this independent record once, before playback updates its old cache.
    var globalPowerRules: WallpaperPowerRules {
        get {
            if let saved = storedGlobalPowerRules { return saved }
            return WallpaperPowerRules(animateOnExternalPower: animateOnExternalPower,
                animateOnBattery: animateOnBattery, pauseInLowPowerMode: pauseInLowPowerMode,
                pauseWhenCovered: pauseWhenCovered)
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "globalPowerRules")
            }
        }
    }

    var hasStoredGlobalPowerRules: Bool { storedGlobalPowerRules != nil }

    /// A missing value identifies the pre-refactor playback cache. Keeping that
    /// distinction preserves a current override across migration and restart.
    var currentWallpaperUsesGlobalPowerRules: Bool? {
        get { defaults.object(forKey: "currentWallpaperUsesGlobalPowerRules") as? Bool }
        nonmutating set { defaults.set(newValue, forKey: "currentWallpaperUsesGlobalPowerRules") }
    }

    /// Identifies a preserved pre-upgrade current state until the user saves it
    /// explicitly or successfully switches to a saved wallpaper.
    var legacyCurrentWallpaperID: UUID? {
        get { defaults.string(forKey: "legacyCurrentWallpaperID").flatMap(UUID.init(uuidString:)) }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: "legacyCurrentWallpaperID") }
    }

    private var storedGlobalPowerRules: WallpaperPowerRules? {
        guard let data = defaults.data(forKey: "globalPowerRules") else { return nil }
        return try? JSONDecoder().decode(WallpaperPowerRules.self, from: data)
    }

    var target: DisplayTarget {
        get { DisplayTarget(rawValue: defaults.string(forKey: "displayTarget") ?? "") ?? .all }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "displayTarget") }
    }

    var scaling: VideoScaling {
        get { VideoScaling(rawValue: defaults.string(forKey: "videoScaling") ?? "") ?? .fill }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "videoScaling") }
    }

    var syncSystemWallpaper: Bool {
        get { defaults.object(forKey: "syncSystemWallpaper") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "syncSystemWallpaper") }
    }

    var syncScreenSaver: Bool {
        get { defaults.object(forKey: "syncScreenSaver") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "syncScreenSaver") }
    }

    var isMuted: Bool {
        get { defaults.object(forKey: "isMuted") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "isMuted") }
    }

    var volume: Double {
        get { Double(WallpaperAudioSettings.normalizedVolume(Float(defaults.object(forKey: "videoVolume") as? Double ?? 1))) }
        nonmutating set { defaults.set(Double(WallpaperAudioSettings.normalizedVolume(Float(newValue))), forKey: "videoVolume") }
    }

    var language: AppLanguage {
        get { AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .english }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "appLanguage") }
    }

    var hasSeenQuickStart: Bool {
        get { defaults.bool(forKey: "hasSeenQuickStart") }
        nonmutating set { defaults.set(newValue, forKey: "hasSeenQuickStart") }
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

    var activeWallpaperID: UUID? {
        get { defaults.string(forKey: "activeWallpaperID").flatMap(UUID.init(uuidString:)) }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: "activeWallpaperID") }
    }
}
