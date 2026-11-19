import AppKit
@preconcurrency import AVFoundation
import Combine

/// Owns the desktop windows, but leaves playback policy and persistence to the app model.
@MainActor
final class WallpaperEngine: ObservableObject {
    @Published private(set) var hasWallpaper = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isPausedForOcclusion = false
    @Published private(set) var occludedDisplayCount = 0
    @Published private(set) var displayCount = 0

    var onPlaybackError: ((String, String?) -> Void)?
    private(set) var posterImage: CGImage?

    private var asset: AVURLAsset?
    private var surfaces: [WallpaperSurface] = []
    private var screenObserver: NSObjectProtocol?
    private var target: DisplayTarget = .all
    private var scaling: VideoScaling = .fill
    private var audio = WallpaperAudioSettings()
    private var pauseWhenCovered = true
    private var playbackEnabled = false
    private var loadGeneration = 0
    private var surfaceGeneration = 0
    private lazy var coverageMonitor: DesktopCoverageMonitor = {
        let monitor = DesktopCoverageMonitor()
        monitor.onChange = { [weak self] coverage in
            guard let self, coverage.count == self.surfaces.count else { return }
            for (surface, covered) in zip(self.surfaces, coverage) {
                surface.setCoveredByWindows(covered)
            }
            self.refreshPlaybackState()
        }
        return monitor
    }()

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

        // A paused AVPlayerLayer need not have rendered a first frame yet.
        // Prepare one image before replacing the current wallpaper so a cold
        // static start never depends on briefly playing the video.
        let generator = AVAssetImageGenerator(asset: candidate)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 3_840, height: 2_160)
        let poster = try await generator.image(at: .zero).image
        try Task.checkCancellation()
        guard generation == loadGeneration else { throw CancellationError() }

        asset = candidate
        posterImage = poster
        hasWallpaper = true
        observeScreensIfNeeded()
        rebuildSurfaces()
    }

    func configure(target: DisplayTarget, scaling: VideoScaling, isMuted: Bool,
                   pauseWhenCovered: Bool = true, volume: Float = 1) {
        let screensChanged = self.target != target
        let onlyAudioChanged = !screensChanged && self.scaling == scaling
            && self.pauseWhenCovered == pauseWhenCovered
        self.target = target
        self.scaling = scaling
        self.audio = WallpaperAudioSettings(isMuted: isMuted, volume: volume)
        self.pauseWhenCovered = pauseWhenCovered

        if onlyAudioChanged {
            // Slider changes must not query other windows, rebuild surfaces,
            // or reevaluate whether a paused video should start playing.
            for (index, surface) in surfaces.enumerated() {
                surface.configureAudio(audio.forDisplay(at: index))
            }
            return
        }
        if screensChanged, asset != nil {
            rebuildSurfaces()
        } else {
            for (index, surface) in surfaces.enumerated() {
                surface.configure(scaling: scaling, audio: audio.forDisplay(at: index),
                                  pauseWhenCovered: pauseWhenCovered)
            }
            updateCoverageMonitoring()
            refreshPlaybackState()
        }
    }

    func setPlaybackEnabled(_ enabled: Bool) {
        playbackEnabled = enabled
        for surface in surfaces {
            surface.setPlaybackEnabled(enabled)
        }
        updateCoverageMonitoring()
        refreshPlaybackState()
    }

    func stop() {
        loadGeneration += 1
        surfaceGeneration += 1
        playbackEnabled = false
        disposeSurfaces()
        asset = nil
        posterImage = nil
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
                self?.refreshScreens()
            }
        }
    }

    private func refreshScreens() {
        guard asset != nil else { return }
        let screens = selectedScreens
        guard screens.count == surfaces.count,
              zip(surfaces, screens).allSatisfy({ $0.belongs(to: $1) }) else {
            rebuildSurfaces()
            return
        }

        // Dock changes (including minimized windows) can change the usable
        // desktop without changing displays. Keep the players and their current
        // positions; only the desktop and coverage window geometry needs updating.
        for (surface, screen) in zip(surfaces, screens) {
            surface.updateGeometry(for: screen)
        }
        updateCoverageMonitoring()
        refreshPlaybackState()
    }

    private func rebuildSurfaces() {
        guard let asset, let posterImage else { return }
        surfaceGeneration += 1
        let generation = surfaceGeneration
        disposeSurfaces()

        for (index, screen) in selectedScreens.enumerated() {
            let surface = WallpaperSurface(
                asset: asset,
                posterImage: posterImage,
                screen: screen,
                scaling: scaling,
                audio: audio.forDisplay(at: index),
                pauseWhenCovered: pauseWhenCovered,
                onStateChanged: { [weak self] in
                    guard let self, self.surfaceGeneration == generation else { return }
                    self.refreshPlaybackState()
                },
                onFailure: { [weak self] message, detail in
                    guard let self, self.surfaceGeneration == generation else { return }
                    self.stop()
                    self.onPlaybackError?(message, detail)
                }
            )
            surfaces.append(surface)
            surface.show()
            surface.setPlaybackEnabled(playbackEnabled)
        }
        updateCoverageMonitoring()
        refreshPlaybackState()
    }

    private func disposeSurfaces() {
        coverageMonitor.stop()
        for surface in surfaces { surface.dispose() }
        surfaces.removeAll()
        isPlaying = false
        isPausedForOcclusion = false
        occludedDisplayCount = 0
        displayCount = 0
    }

    private func updateCoverageMonitoring() {
        coverageMonitor.update(trackingFrames: surfaces.map(\.trackingFrame),
                               enabled: playbackEnabled && pauseWhenCovered && !surfaces.isEmpty)
    }

    private func refreshPlaybackState() {
        isPlaying = playbackEnabled && surfaces.contains(where: \.isPlaying)
        displayCount = surfaces.count
        occludedDisplayCount = playbackEnabled && pauseWhenCovered
            ? surfaces.filter(\.isOccluded).count : 0
        isPausedForOcclusion = playbackEnabled && pauseWhenCovered && !surfaces.isEmpty
            && occludedDisplayCount == surfaces.count
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
    private let displayID: CGDirectDisplayID?
    private let window: DesktopWindow
    private let visibilityWindow: DesktopWindow
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let videoView: WallpaperVideoView
    private var observations: [NSKeyValueObservation] = []
    private var currentItemObservation: NSKeyValueObservation?
    private var occlusionObserver: NSObjectProtocol?
    private let onStateChanged: @MainActor () -> Void
    private let onFailure: @MainActor (String, String?) -> Void
    private var disposed = false
    private var playbackEnabled = false
    private var pauseWhenCovered: Bool
    private var appliedPlaybackEnabled: Bool?
    private var coveredByWindows = false

    var isPlaying: Bool { player.timeControlStatus == .playing }
    var isOccluded: Bool { coveredByWindows || !visibilityWindow.occlusionState.contains(.visible) }
    var trackingFrame: CGRect { visibilityWindow.frame }

    init(
        asset: AVURLAsset,
        posterImage: CGImage,
        screen: NSScreen,
        scaling: VideoScaling,
        audio: WallpaperAudioSettings,
        pauseWhenCovered: Bool,
        onStateChanged: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (String, String?) -> Void
    ) {
        self.onStateChanged = onStateChanged
        self.onFailure = onFailure
        self.pauseWhenCovered = pauseWhenCovered
        displayID = Self.displayID(for: screen)

        player = AVQueuePlayer()
        audio.apply(to: player)
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
        videoView = WallpaperVideoView(frame: NSRect(origin: .zero, size: screen.frame.size))
        videoView.posterLayer.contents = posterImage
        videoView.playerLayer.player = player
        videoView.configure(scaling: scaling)

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

        // Track the usable desktop, excluding the menu bar and Dock. Observing
        // the full-screen video window would keep playback running behind a
        // maximized app whenever one of those narrow strips remained visible.
        // Native occlusion is supplemented with window bounds: on recent macOS,
        // even a fully covering titled window can leave this tracker "visible".
        // Ignore a narrow edge strip for rounded corners and window tiling gaps.
        let trackingFrame = Self.trackingFrame(for: screen)
        visibilityWindow = DesktopWindow(
            contentRect: trackingFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        visibilityWindow.setFrame(trackingFrame, display: false)
        visibilityWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 2)
        visibilityWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        visibilityWindow.ignoresMouseEvents = true
        visibilityWindow.hasShadow = false
        visibilityWindow.isOpaque = false
        visibilityWindow.backgroundColor = .clear
        visibilityWindow.animationBehavior = .none
        visibilityWindow.hidesOnDeactivate = false
        visibilityWindow.canHide = false
        visibilityWindow.isReleasedWhenClosed = false
        observePlayback()
        observeOcclusion()
    }

    func belongs(to screen: NSScreen) -> Bool {
        guard let displayID else { return false }
        return displayID == Self.displayID(for: screen)
    }

    func updateGeometry(for screen: NSScreen) {
        guard !disposed else { return }
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
        let trackingFrame = Self.trackingFrame(for: screen)
        if visibilityWindow.frame != trackingFrame {
            visibilityWindow.setFrame(trackingFrame, display: false)
        }
        applyPlaybackPolicy()
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              number.uint32Value != kCGNullDirectDisplay else { return nil }
        return number.uint32Value
    }

    private static func trackingFrame(for screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let usableFrame = visibleFrame.isEmpty ? screen.frame : visibleFrame
        let edgeInset = min(16, min(usableFrame.width, usableFrame.height) / 4)
        return usableFrame.insetBy(dx: edgeInset, dy: edgeInset)
    }

    func show() {
        window.orderFrontRegardless()
        visibilityWindow.orderFrontRegardless()
        applyPlaybackPolicy()
    }

    func configureAudio(_ audio: WallpaperAudioSettings) {
        audio.apply(to: player)
    }

    func configure(scaling: VideoScaling, audio: WallpaperAudioSettings, pauseWhenCovered: Bool) {
        configureAudio(audio)
        videoView.configure(scaling: scaling)
        self.pauseWhenCovered = pauseWhenCovered
        applyPlaybackPolicy()
    }

    func setPlaybackEnabled(_ enabled: Bool) {
        playbackEnabled = enabled
        applyPlaybackPolicy()
    }

    func setCoveredByWindows(_ covered: Bool) {
        guard coveredByWindows != covered else { return }
        coveredByWindows = covered
        applyPlaybackPolicy()
    }

    private func applyPlaybackPolicy() {
        guard !disposed else { return }
        let shouldPlay = playbackEnabled && (!pauseWhenCovered || !isOccluded)
        // Pausing keeps the last frame and window in place. Hiding the window
        // here would make it stay occluded and prevent a visibility-based resume.
        guard appliedPlaybackEnabled != shouldPlay else { return }
        appliedPlaybackEnabled = shouldPlay
        shouldPlay ? player.play() : player.pause()
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        player.pause()
        looper.disableLooping()
        player.removeAllItems()
        videoView.playerLayer.player = nil
        visibilityWindow.orderOut(nil)
        visibilityWindow.close()
        window.orderOut(nil)
        window.close()
    }

    private func observeOcclusion() {
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: visibilityWindow,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.disposed else { return }
                self.applyPlaybackPolicy()
                self.onStateChanged()
            }
        }
    }

    private func observePlayback() {
        observations.append(videoView.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.disposed else { return }
                self.videoView.updateVideoReadiness()
            }
        })
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
        onFailure("Не удалось воспроизвести видео. Попробуйте выбрать другой файл.", detail)
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
    let posterLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        posterLayer.name = "wallpaper.poster"
        playerLayer.name = "wallpaper.video"
        posterLayer.masksToBounds = true
        playerLayer.isHidden = true
        layer?.addSublayer(posterLayer)
        layer?.addSublayer(playerLayer)
        posterLayer.frame = bounds
        playerLayer.frame = bounds
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        posterLayer.frame = bounds
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func configure(scaling: VideoScaling) {
        playerLayer.videoGravity = scaling == .fill ? .resizeAspectFill : .resizeAspect
        posterLayer.contentsGravity = scaling == .fill ? .resizeAspectFill : .resizeAspect
    }

    func updateVideoReadiness() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ready = playerLayer.isReadyForDisplay
        playerLayer.isHidden = !ready
        posterLayer.isHidden = ready
        CATransaction.commit()
    }
}
