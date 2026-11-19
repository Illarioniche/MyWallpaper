import Testing
@testable import MyWallpaper

@Suite
struct PlaybackPolicyTests {
    @Test
    func defaultsAnimateOnExternalPowerAndHoldAStillFrameOnBattery() {
        var policy = PlaybackPolicy()
        policy.powerSource = .external
        #expect(policy.shouldPlay)
        #expect(policy.pauseReason == nil)

        policy.powerSource = .battery
        #expect(!policy.shouldPlay)
        #expect(!policy.animatesOnCurrentPowerSource)
        #expect(policy.pauseReason != nil)

        policy.powerSource = .external
        #expect(policy.shouldPlay, "Plugging in should resume unless another pause remains.")
    }

    @Test
    func bothPowerProfilesCanBeReversedIndependently() {
        var policy = PlaybackPolicy()
        policy.animateOnExternalPower = false
        policy.animateOnBattery = true
        policy.powerSource = .external
        #expect(!policy.shouldPlay)

        policy.powerSource = .battery
        #expect(policy.shouldPlay)
        policy.powerSource = .external
        #expect(!policy.shouldPlay, "Changing the source must not rewrite either saved profile.")
        #expect(policy.animateOnBattery)
        #expect(!policy.animateOnExternalPower)
    }

    @Test
    func unknownPowerUsesTheExternalProfileIncludingItsStaticOverride() {
        var policy = PlaybackPolicy()
        policy.powerSource = .unknown
        #expect(policy.shouldPlay)

        policy.animateOnExternalPower = false
        policy.animateOnBattery = true
        #expect(!policy.shouldPlay, "Unknown does not mean unconditional animation.")
        #expect(!policy.animatesOnCurrentPowerSource)
    }

    @Test
    func pluggingInDoesNotClearAManualPause() {
        var policy = PlaybackPolicy()
        policy.powerSource = .battery
        policy.userPaused = true
        policy.powerSource = .external
        #expect(!policy.shouldPlay)
        #expect(policy.userPaused)

        policy.powerSource = .battery
        policy.animateOnBattery = true
        #expect(!policy.shouldPlay, "A profile preference change does not remove manual pause.")
        policy.userPaused = false
        #expect(policy.shouldPlay)
    }

    @Test
    func animationOverridesStillRespectSleepSessionAndLowPowerPauses() {
        var policy = PlaybackPolicy()
        policy.powerSource = .battery
        policy.animateOnBattery = true
        policy.systemSleeping = true
        #expect(!policy.shouldPlay)

        policy.systemSleeping = false
        policy.sessionInactive = true
        policy.powerSource = .external
        #expect(!policy.shouldPlay)

        policy.sessionInactive = false
        policy.lowPowerMode = true
        #expect(!policy.shouldPlay)
        policy.pauseInLowPowerMode = false
        #expect(policy.shouldPlay)

        policy.powerSource = .battery
        policy.animateOnBattery = false
        #expect(!policy.shouldPlay, "Disabling low-power pause does not override the battery profile.")
    }

    @Test
    func testManualPauseSurvivesSleepAndWake() {
        var policy = PlaybackPolicy()
        policy.userPaused = true
        policy.systemSleeping = true
        policy.screensSleeping = true
        #expect(!policy.shouldPlay)

        policy.systemSleeping = false
        policy.screensSleeping = false
        #expect(!policy.shouldPlay, "Waking the Mac must not undo a manual pause.")
        #expect(policy.pauseReason != nil)

        policy.userPaused = false
        #expect(policy.shouldPlay)
        #expect(policy.pauseReason == nil)
    }

    @Test
    func testScreenWakeDoesNotResumeAnInactiveSession() {
        var policy = PlaybackPolicy()
        policy.systemSleeping = true
        policy.screensSleeping = true
        policy.sessionInactive = true

        policy.systemSleeping = false
        #expect(!policy.shouldPlay)
        policy.screensSleeping = false
        #expect(!policy.shouldPlay, "An inactive user session remains paused after display wake.")
        policy.sessionInactive = false
        #expect(policy.shouldPlay)
        #expect(policy.pauseReason == nil)
    }

    @Test
    func testResumeDuringSystemPauseWaitsForWake() {
        var policy = PlaybackPolicy()
        policy.userPaused = true
        policy.screensSleeping = true

        policy.userPaused = false
        #expect(!policy.shouldPlay, "Resume records intent without playing on a sleeping display.")
        policy.screensSleeping = false
        #expect(policy.shouldPlay)
    }

    @Test
    func testLowPowerPauseCanBeDisabledWithoutRemovingOtherPauses() {
        var policy = PlaybackPolicy()
        policy.lowPowerMode = true
        #expect(!policy.shouldPlay)
        #expect(policy.pauseReason != nil)

        policy.pauseInLowPowerMode = false
        #expect(policy.shouldPlay)
        #expect(policy.pauseReason == nil)

        policy.userPaused = true
        #expect(!policy.shouldPlay, "The energy preference must not override manual pause.")
        policy.userPaused = false
        policy.sessionInactive = true
        #expect(!policy.shouldPlay, "The energy preference must not override session pause.")
    }

    @Test
    func testLowPowerExitResumesOnlyWhenNoOtherPauseRemains() {
        var policy = PlaybackPolicy()
        policy.lowPowerMode = true
        policy.screensSleeping = true

        policy.lowPowerMode = false
        #expect(!policy.shouldPlay)
        policy.screensSleeping = false
        #expect(policy.shouldPlay)
    }
}
