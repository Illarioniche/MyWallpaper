import Testing
@testable import MyWallpaper

@Suite
struct PlaybackPolicyTests {
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
