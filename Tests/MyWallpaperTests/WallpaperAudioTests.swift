import AVFoundation
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct WallpaperAudioTests {
    @Test
    func finiteVolumeIsClampedWithoutChangingValidLevels() {
        let cases: [(Float, Float)] = [(-2, 0), (0, 0), (0.25, 0.25), (0.8, 0.8), (1, 1), (3, 1)]
        for (input, expected) in cases {
            #expect(WallpaperAudioSettings(volume: input).volume == expected)
        }
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity])
    func nonfiniteVolumeRestoresTheDefault(_ value: Float) {
        let settings = WallpaperAudioSettings(isMuted: true, volume: value)
        #expect(settings.volume == 1)
        #expect(settings.isMuted, "Invalid input must not unmute the user's wallpaper.")
    }

    @Test
    func changingVolumeAndMutingAreIndependent() {
        let player = AVQueuePlayer()
        WallpaperAudioSettings(isMuted: true, volume: 0.25).apply(to: player)
        #expect(player.isMuted)
        #expect(player.volume == 0.25)

        WallpaperAudioSettings(isMuted: true, volume: 0.8).apply(to: player)
        #expect(player.isMuted, "Moving the slider must not turn sound on.")
        #expect(player.volume == 0.8)

        WallpaperAudioSettings(isMuted: false, volume: 0.8).apply(to: player)
        #expect(!player.isMuted)
        #expect(player.volume == 0.8, "Unmuting restores the selected level.")

        WallpaperAudioSettings(isMuted: false, volume: 0).apply(to: player)
        #expect(!player.isMuted, "Zero volume is distinct from the mute preference.")
        #expect(player.volume == 0)
        #expect(player.currentItem == nil)
        #expect(player.rate == 0)
        #expect(player.timeControlStatus == .paused)
    }

    @Test
    func multipleDisplaysKeepOnlyOneAudioOutputAcrossChanges() {
        var players = [AVQueuePlayer(), AVQueuePlayer(), AVQueuePlayer()]
        for volume in [Float(0.25), 0.8, 1] {
            apply(WallpaperAudioSettings(isMuted: false, volume: volume), to: players)
            #expect(players.filter { !$0.isMuted }.count == 1)
            #expect(!players[0].isMuted)
            #expect(players.allSatisfy { $0.volume == volume })
        }

        apply(WallpaperAudioSettings(isMuted: true, volume: 0.4), to: players)
        #expect(players.allSatisfy { $0.isMuted })

        // A different display becomes primary after the old first one disappears.
        players.removeFirst()
        apply(WallpaperAudioSettings(isMuted: false, volume: 0.4), to: players)
        #expect(!players[0].isMuted)
        #expect(players[1].isMuted)
        #expect(players.allSatisfy { $0.volume == 0.4 })
        #expect(players.allSatisfy { $0.currentItem == nil && $0.rate == 0 && $0.timeControlStatus == .paused })
    }

    @Test
    func invalidVolumeIsNormalizedBeforeReachingEveryPlayer() {
        let players = [AVQueuePlayer(), AVQueuePlayer()]
        apply(WallpaperAudioSettings(isMuted: false, volume: .nan), to: players)
        #expect(players.allSatisfy { $0.volume == 1 })
        #expect(!players[0].isMuted && players[1].isMuted)
        #expect(players.allSatisfy { $0.currentItem == nil && $0.rate == 0 })
    }

    private func apply(_ settings: WallpaperAudioSettings, to players: [AVQueuePlayer]) {
        for (index, player) in players.enumerated() {
            settings.forDisplay(at: index).apply(to: player)
        }
    }
}
