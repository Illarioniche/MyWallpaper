import Testing
@testable import MyWallpaper

@Suite
struct WallpaperPauseCauseTests {
    @Test(arguments: WallpaperPauseCause.allCases)
    func explanationUsesTheAppLanguageAndIdentifiesOnlyRelevantRules(_ cause: WallpaperPauseCause) {
        let shared = cause.explanation(using: .english, usesGlobalPowerRules: true)
        let individual = cause.explanation(using: .english, usesGlobalPowerRules: false)
        #expect(!shared.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) })
        #expect(cause.explanation(using: .russian, usesGlobalPowerRules: true).hasPrefix(cause.detailKey))
        if cause.usesPowerRules {
            #expect(shared.contains("The shared rules from Power apply."))
            #expect(individual.contains("The individual rules in this wallpaper’s editor apply."))
        } else {
            #expect(shared == individual, "Manual and system pauses do not come from the wallpaper power rules.")
        }
    }

    @Test
    func explanationKeepsPolicyPriorityWhenSeveralConditionsOverlap() {
        var policy = PlaybackPolicy(userPaused: true, systemSleeping: true, screensSleeping: true,
            sessionInactive: true, lowPowerMode: true, powerSource: .battery)
        func current(_ policy: PlaybackPolicy) -> WallpaperPauseCause? {
            WallpaperPauseCause.current(policy: policy, isLoading: false, hasWallpaper: true, desktopHidden: true)
        }
        #expect(current(policy) == .manual)
        policy.userPaused = false
        #expect(current(policy) == .systemSleep)
        policy.systemSleeping = false
        #expect(current(policy) == .displaySleep)
        policy.screensSleeping = false
        #expect(current(policy) == .sessionInactive)
        policy.sessionInactive = false
        #expect(current(policy) == .lowPowerMode)
        policy.lowPowerMode = false
        #expect(current(policy) == .batteryRule)
        #expect(!policy.shouldPlay)
        policy.temporaryAnimationOverride = true
        #expect(current(policy) == .desktopHidden)
        #expect(policy.shouldPlay, "Coverage is an engine concern; explaining it must not change the playback policy.")
        #expect(!policy.animateOnBattery)
    }

    @Test
    func loadingAndStoppedWallpapersNeverExplainAStalePause() {
        let policy = PlaybackPolicy(userPaused: true, lowPowerMode: true, powerSource: .battery)
        #expect(WallpaperPauseCause.current(policy: policy, isLoading: true, hasWallpaper: true, desktopHidden: true) == nil)
        #expect(WallpaperPauseCause.current(policy: policy, isLoading: false, hasWallpaper: false, desktopHidden: true) == nil)
        #expect(WallpaperPauseCause.current(policy: PlaybackPolicy(), isLoading: false,
                                           hasWallpaper: true, desktopHidden: false) == nil)
    }

    @Test(arguments: [PowerSource.external, .battery, .unknown])
    func staticPowerRulesHaveDistinctSupportCategories(_ source: PowerSource) throws {
        var policy = PlaybackPolicy(powerSource: source, animateOnExternalPower: false, animateOnBattery: false)
        let cause = try #require(policy.pauseCause)
        switch source {
        case .external: #expect(cause.diagnosticCause == .externalPowerRule)
        case .battery: #expect(cause.diagnosticCause == .batteryRule)
        case .unknown: #expect(cause.diagnosticCause == .unknownPowerRule)
        }
        #expect(cause.usesPowerRules)
        #expect(policy.pauseReason == cause.titleKey)
        policy.temporaryAnimationOverride = true
        #expect(policy.pauseCause == nil)
        policy.lowPowerMode = true
        #expect(policy.pauseCause == .lowPowerMode)
        #expect(!policy.shouldPlay, "Animate Now must not bypass Low Power Mode.")
    }
}
