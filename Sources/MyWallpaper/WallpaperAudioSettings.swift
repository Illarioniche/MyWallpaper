@preconcurrency import AVFoundation

/// App-local audio preferences, independent of playback and the system volume.
struct WallpaperAudioSettings: Equatable, Sendable {
    let isMuted: Bool
    let volume: Float

    init(isMuted: Bool = true, volume: Float = 1) {
        self.isMuted = isMuted
        self.volume = Self.normalizedVolume(volume)
    }

    static func normalizedVolume(_ value: Float) -> Float {
        guard value.isFinite else { return 1 }
        return min(max(value, 0), 1)
    }

    /// Each display has a video player, but only the first may produce audio.
    func forDisplay(at index: Int) -> WallpaperAudioSettings {
        WallpaperAudioSettings(isMuted: isMuted || index != 0, volume: volume)
    }

    @MainActor
    func apply(to player: AVPlayer) {
        player.volume = volume
        player.isMuted = isMuted
    }
}
