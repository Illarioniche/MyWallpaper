import Foundation

/// Explicitly selected support data. Never accept media names, URLs, bookmarks,
/// arbitrary error descriptions or a dump of UserDefaults in this report.
struct AppDiagnosticSnapshot {
    enum Architecture: String {
        case arm64, x86_64, unknown

        static var current: Self {
            #if arch(arm64)
            .arm64
            #elseif arch(x86_64)
            .x86_64
            #else
            .unknown
            #endif
        }
    }

    enum Playback: String {
        case empty, loading, stopped, playing, paused, preparing
    }

    enum PauseCause: String {
        case none, manual
        case systemSleep = "system-sleep"
        case displaySleep = "display-sleep"
        case sessionInactive = "session-inactive"
        case lowPowerMode = "low-power-mode"
        case batteryRule = "battery-rule"
        case externalPowerRule = "external-power-rule"
        case unknownPowerRule = "unknown-power-rule"
        case desktopHidden = "desktop-hidden"
    }

    enum UpdateCheck: String {
        case idle, checking, available, failed
        case upToDate = "up-to-date"

        init(_ state: UpdateState) {
            switch state {
            case .idle: self = .idle
            case .checking: self = .checking
            case .upToDate: self = .upToDate
            case .available: self = .available
            case .failed: self = .failed
            }
        }
    }

    enum UpdateInstallation: String {
        case idle, checking, downloading, extracting, restarting, cancelled, failed
        case waitingForApplication = "waiting-for-application"

        init(_ state: UpdateInstallationState) {
            switch state {
            case .idle: self = .idle
            case .checking: self = .checking
            case .downloading: self = .downloading
            case .extracting: self = .extracting
            case .waitingForApplication: self = .waitingForApplication
            case .restarting: self = .restarting
            case .cancelled: self = .cancelled
            case .failed: self = .failed
            }
        }
    }

    enum FailureArea: String, Hashable {
        case wallpaper, login
        case wallpaperLibrary = "wallpaper-library"
        case screenSaver = "screen-saver"
        case screenSaverSync = "screen-saver-sync"
        case updateCheck = "update-check"
        case updateInstallation = "update-installation"
    }

    var appVersion: String?
    var appBuild: String?
    var systemVersion = OperatingSystemVersion(majorVersion: 0, minorVersion: 0, patchVersion: 0)
    var architecture: Architecture = .current
    var language: AppLanguage = .english
    var playback: Playback = .empty
    var pauseCause: PauseCause = .none
    var userPaused = false
    var isTemporarilyAnimating = false
    var connectedDisplayCount = 0
    var wallpaperDisplayCount = 0
    var occludedDisplayCount = 0
    var powerSource: PowerSource = .unknown
    var lowPowerMode = false
    var effectivePowerRules = WallpaperPowerRules()
    var usesGlobalPowerRules = true
    var wallpaperCount = 0
    var screenSaverCount = 0
    var screenSaverSyncEnabled = false
    var screenSaverSyncInstalled = false
    var loginStatus: LoginItemStatus = .unavailable
    var loginAvailability: LoginItemAvailability = .notAppBundle
    var automaticUpdateChecksEnabled = true
    var updateCheck: UpdateCheck = .idle
    var updateInstallation: UpdateInstallation = .idle
    var lastUpdateCheck: Date?
    var failures: Set<FailureArea> = []

    /// English labels and UTC dates make reports comparable across app languages.
    /// Formatting has no side effects: the caller copies this only on user action.
    func formattedText() -> String {
        let osVersion = systemVersion.majorVersion > 0 && systemVersion.minorVersion >= 0 && systemVersion.patchVersion >= 0
            ? "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)" : "unknown"
        let failedAreas = failures.map(\.rawValue).sorted()
        return """
        MyWallpaper diagnostics (format 1)
        App version: \(Self.safeNumericVersion(appVersion))
        App build: \(Self.safeNumericVersion(appBuild))
        macOS: \(osVersion)
        Process architecture: \(architecture.rawValue)
        App language: \(language.rawValue)

        Playback: \(playback.rawValue)
        Pause reason: \(pauseCause.rawValue)
        Manual pause: \(Self.yesNo(userPaused))
        Temporary animation: \(Self.yesNo(isTemporarilyAnimating))
        Displays connected: \(connectedDisplayCount)
        Wallpaper displays: \(wallpaperDisplayCount)
        Covered wallpaper displays: \(occludedDisplayCount)

        Power source: \(powerSource.rawValue)
        Low Power Mode: \(Self.yesNo(lowPowerMode))
        Power rules: \(usesGlobalPowerRules ? "shared" : "individual")
        Animate on external power: \(Self.yesNo(effectivePowerRules.animateOnExternalPower))
        Animate on battery: \(Self.yesNo(effectivePowerRules.animateOnBattery))
        Pause in Low Power Mode: \(Self.yesNo(effectivePowerRules.pauseInLowPowerMode))
        Pause when desktop is hidden: \(Self.yesNo(effectivePowerRules.pauseWhenCovered))

        Saved wallpapers: \(wallpaperCount)
        Saved screen savers: \(screenSaverCount)
        Screen saver sync enabled: \(Self.yesNo(screenSaverSyncEnabled))
        Linked screen saver installed: \(Self.yesNo(screenSaverSyncInstalled))
        Launch at login: \(loginStatusText)
        Login item availability: \(loginAvailabilityText)

        Automatic update checks: \(Self.yesNo(automaticUpdateChecksEnabled))
        Update check: \(updateCheck.rawValue)
        Update installation: \(updateInstallation.rawValue)
        Last successful update check (UTC): \(lastUpdateCheckText)
        Reported errors: \(failedAreas.isEmpty ? "none" : failedAreas.joined(separator: ", "))

        File paths, media names and error details are not included.
        """
    }

    private var loginStatusText: String {
        switch loginStatus {
        case .enabled: "enabled"
        case .disabled: "disabled"
        case .requiresApproval: "requires-approval"
        case .notFound: "not-found"
        case .unavailable: "unavailable"
        }
    }

    private var loginAvailabilityText: String {
        switch loginAvailability {
        case .available: "available"
        case .notAppBundle: "not-app-bundle"
        case .readOnlyVolume: "read-only-volume"
        case .translocated: "translocated"
        }
    }

    private var lastUpdateCheckText: String {
        guard let lastUpdateCheck, lastUpdateCheck.timeIntervalSince1970.isFinite else { return "never" }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: lastUpdateCheck)
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    /// Bundle metadata normally contains only numeric versions. A malformed
    /// value must not become a way to include a path or additional report lines.
    private static func safeNumericVersion(_ value: String?) -> String {
        guard let value, value.count <= 32, !value.isEmpty else { return "unknown" }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count), components.allSatisfy({ component in
            !component.isEmpty && component.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return "unknown" }
        return value
    }
}
