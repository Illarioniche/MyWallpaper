import AppKit
@preconcurrency import AVFoundation
import Combine

/// Owns the desktop windows, but leaves playback policy and persistence to the app model.
@MainActor
final class WallpaperEngine: ObservableObject {
    @Published private(set) var hasWallpaper = false
    @Published private(set) var isPlaying = false

    var onPlaybackError: ((String) -> Void)?

    private var asset: AVURLAsset?
    private var surfaces: [WallpaperSurface] = []
    private var screenObserver: NSObjectProtocol?
    private var target: DisplayTarget = .all
    private var scaling: VideoScaling = .fill
    private var isMuted = true
    private var playbackEnabled = false
    private var loadGeneration = 0
    private var surfaceGeneration = 0

    func load(url: URL) async throws {
        loadGeneration += 1
        let generation = loadGeneration
        let candidate = AVURLAsset(url: url)
        let (playable, duration) = try await candidate.load(.isPlayable, .duration)
        let videoTracks = try await candidate.loadTracks(withMediaType: .video)

        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }
        guard playable else { throw WallpaperError.unsupportedVideo }
        guard !videoTracks.isEmpty else { throw WallpaperError.noVideoTrack }
        // AVPlayerLooper raises an Objective-C exception for zero-length items.
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            throw WallpaperError.invalidDuration
        }
        guard !selectedScreens.isEmpty else { throw WallpaperError.noDisplay }

        asset = candidate
        hasWallpaper = true
        observeScreensIfNeeded()
        rebuildSurfaces()
    }

    func configure(target: DisplayTarget, scaling: VideoScaling, isMuted: Bool) {
        let screensChanged = self.target != target
        self.target = target
        self.scaling = scaling
        self.isMuted = isMuted
        if screensChanged, asset != nil {
            rebuildSurfaces()
        } else {
            for (index, surface) in surfaces.enumerated() {
                surface.configure(scaling: scaling, isMuted: isMuted || index != 0)
            }
        }
    }

    func setPlaybackEnabled(_ enabled: Bool) {
        playbackEnabled = enabled
        for surface in surfaces {
            surface.setPlaybackEnabled(enabled)
        }
        refreshPlaybackState()
    }

    func stop() {
        loadGeneration += 1
        surfaceGeneration += 1
        playbackEnabled = false
        disposeSurfaces()
        asset = nil
        hasWallpaper = false
        isPlaying = false
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    private var selectedScreens: [NSScreen] {
        // NSScreen.main follows the focused window. The first screen is the
        // stable primary display with the menu bar, which is what "main" means here.
        target == .main ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
    }

    private func observeScreensIfNeeded() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildSurfaces()
            }
        }
    }

    private func rebuildSurfaces() {
        guard let asset else { return }
        surfaceGeneration += 1
        let generation = surfaceGeneration
        disposeSurfaces()

        for (index, screen) in selectedScreens.enumerated() {
            let surface = WallpaperSurface(
                asset: asset,
                screen: screen,
                scaling: scaling,
                isMuted: isMuted || index != 0,
                onStateChanged: { [weak self] in
                    guard let self, self.surfaceGeneration == generation else { return }
                    self.refreshPlaybackState()
                },
                onFailure: { [weak self] message in
                    guard let self, self.surfaceGeneration == generation else { return }
                    self.stop()
                    self.onPlaybackError?(message)
                }
            )
            surfaces.append(surface)
            surface.show()
            surface.setPlaybackEnabled(playbackEnabled)
        }
        refreshPlaybackState()
    }

    private func disposeSurfaces() {
        for surface in surfaces { surface.dispose() }
        surfaces.removeAll()
        isPlaying = false
    }

    private func refreshPlaybackState() {
        isPlaying = playbackEnabled && surfaces.contains(where: \.isPlaying)
    }
}

private enum WallpaperError: LocalizedError {
    case unsupportedVideo
    case noVideoTrack
    case invalidDuration
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .unsupportedVideo:
            "macOS не может воспроизвести это видео. Попробуйте MP4 с кодеком H.264 или HEVC."
        case .noVideoTrack:
            "В файле нет видеодорожки. Выберите видео, а не аудиофайл."
        case .invalidDuration:
            "Не удалось определить длительность видео или файл пуст."
        case .noDisplay:
            "Не найден подключённый экран."
        }
    }
}

@MainActor
private final class WallpaperSurface {
    private let window: DesktopWindow
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let videoView: WallpaperVideoView
    private var observations: [NSKeyValueObservation] = []
    private var currentItemObservation: NSKeyValueObservation?
    private let onStateChanged: @MainActor () -> Void
    private let onFailure: @MainActor (String) -> Void
    private var disposed = false

    var isPlaying: Bool { player.timeControlStatus == .playing }

    init(
        asset: AVURLAsset,
        screen: NSScreen,
        scaling: VideoScaling,
        isMuted: Bool,
        onStateChanged: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        self.onStateChanged = onStateChanged
        self.onFailure = onFailure

        player = AVQueuePlayer()
        player.isMuted = isMuted
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
        videoView = WallpaperVideoView(frame: NSRect(origin: .zero, size: screen.frame.size))
        videoView.playerLayer.player = player
        videoView.playerLayer.videoGravity = scaling == .fill ? .resizeAspectFill : .resizeAspect

        window = DesktopWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.animationBehavior = .none
        window.hidesOnDeactivate = false
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.contentView = videoView
        observePlayback()
    }

    func show() { window.orderFrontRegardless() }

    func configure(scaling: VideoScaling, isMuted: Bool) {
        player.isMuted = isMuted
        videoView.playerLayer.videoGravity = scaling == .fill ? .resizeAspectFill : .resizeAspect
    }

    func setPlaybackEnabled(_ enabled: Bool) {
        enabled ? player.play() : player.pause()
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        player.pause()
        looper.disableLooping()
        player.removeAllItems()
        videoView.playerLayer.player = nil
        window.orderOut(nil)
        window.close()
    }

    private func observePlayback() {
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.disposed else { return }
                self.onStateChanged()
            }
        })
        observations.append(player.observe(\.status, options: [.initial, .new]) { [weak self] player, _ in
            guard player.status == .failed else { return }
            let detail = player.error?.localizedDescription
            Task { @MainActor [weak self] in self?.reportFailure(detail) }
        })
        observations.append(looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            let detail = looper.error?.localizedDescription
            Task { @MainActor [weak self] in self?.reportFailure(detail) }
        })
        observations.append(player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.observeCurrentItem() }
        })
    }

    private func observeCurrentItem() {
        guard !disposed else { return }
        currentItemObservation?.invalidate()
        currentItemObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let detail = item.error?.localizedDescription
            Task { @MainActor [weak self] in self?.reportFailure(detail) }
        }
    }

    private func reportFailure(_ detail: String?) {
        guard !disposed else { return }
        var message = "Не удалось воспроизвести видео. Попробуйте выбрать другой файл."
        if let detail, !detail.isEmpty { message += "\n\n" + detail }
        onFailure(message)
    }
}

@MainActor
private final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class WallpaperVideoView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }
}
