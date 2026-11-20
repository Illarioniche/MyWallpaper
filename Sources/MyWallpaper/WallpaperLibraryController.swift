import AppKit
import AVFoundation
import Combine
import ImageIO

/// Owns saved media without changing desktop playback. Calls are serialized so
/// queued edits and a reload cannot overwrite each other's published snapshot.
@MainActor
final class WallpaperLibraryController: ObservableObject {
    @Published private(set) var entries: [WallpaperLibraryEntry] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    @Published private(set) var libraryWarnings: [WallpaperLibraryError] = []
    @Published private(set) var hasLoadedLibrary = false
    @Published private(set) var isWorking = false
    @Published private(set) var failure: WallpaperLibraryError?

    typealias VideoPreparer = @Sendable (URL) async throws -> Data

    private let library: WallpaperLibrary
    private let prepare: VideoPreparer
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(library: WallpaperLibrary = .init(), prepareVideo: VideoPreparer? = nil) {
        self.library = library
        self.prepare = prepareVideo ?? Self.prepareVideo
    }

    func reload() async {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return }
        failure = nil
        let library = self.library
        do {
            let snapshot = try await Self.offMain {
                let listing = try library.list()
                var previews: [UUID: Data] = [:]
                for entry in listing.entries {
                    try Task.checkCancellation()
                    if let url = try? library.thumbnailURL(for: entry.id),
                       let data = Self.smallPreview(at: url) { previews[entry.id] = data }
                }
                return Snapshot(listing: listing, previews: previews)
            }
            entries = snapshot.listing.entries
            libraryWarnings = snapshot.listing.warnings
            thumbnails = snapshot.previews.compactMapValues { NSImage(data: $0) }
            hasLoadedLibrary = true
        } catch { present(error, fallback: "Не удалось открыть библиотеку обоев.") }
    }

    @discardableResult
    func addVideo(_ url: URL, options: WallpaperLibraryOptions) async -> WallpaperLibraryEntry? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        failure = nil
        let acquired = url.startAccessingSecurityScopedResource()
        defer { if acquired { url.stopAccessingSecurityScopedResource() } }
        let library = self.library
        do {
            let prepare = self.prepare
            let preparation = Task.detached(priority: .userInitiated) { try await prepare(url) }
            let poster = try await withTaskCancellationHandler {
                try await preparation.value
            } onCancel: { preparation.cancel() }
            try Task.checkCancellation()
            let rawName = url.deletingPathExtension().lastPathComponent
            let cleanName = String(String.UnicodeScalarView(rawName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String((cleanName.isEmpty ? "Video" : cleanName).prefix(80))
            let (entry, preview) = try await Self.offMain {
                let entry = try library.create(videoURL: url, posterJPEG: poster, name: name, options: options)
                return (entry, (try? library.thumbnailURL(for: entry.id)).flatMap { Self.smallPreview(at: $0) })
            }
            entries.insert(entry, at: 0)
            if let preview { thumbnails[entry.id] = NSImage(data: preview) }
            return entry
        } catch {
            present(error, fallback: "Не удалось добавить видео в библиотеку обоев.")
            return nil
        }
    }

    @discardableResult
    func rename(_ entry: WallpaperLibraryEntry, name: String) async -> WallpaperLibraryEntry? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        failure = nil
        let library = self.library
        do {
            let updated = try await Self.offMain { try library.rename(id: entry.id, name: name) }
            replace(updated)
            return updated
        } catch {
            present(error, fallback: "Не удалось переименовать обои.")
            return nil
        }
    }

    @discardableResult
    func updateOptions(_ entry: WallpaperLibraryEntry, options: WallpaperLibraryOptions) async -> WallpaperLibraryEntry? {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return nil }
        failure = nil
        let library = self.library
        do {
            let updated = try await Self.offMain { try library.updateOptions(id: entry.id, options: options) }
            replace(updated)
            return updated
        } catch {
            present(error, fallback: "Не удалось сохранить настройки обоев.")
            return nil
        }
    }

    @discardableResult
    func delete(_ entry: WallpaperLibraryEntry) async -> Bool {
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return false }
        failure = nil
        let library = self.library
        do {
            try await Self.offMain { try library.delete(id: entry.id) }
            entries.removeAll { $0.id == entry.id }
            thumbnails[entry.id] = nil
            return true
        } catch {
            present(error, fallback: "Не удалось удалить обои из библиотеки.")
            return false
        }
    }

    func videoURL(for entry: WallpaperLibraryEntry) throws -> URL { try library.videoURL(for: entry.id) }
    func entry(for id: UUID) throws -> WallpaperLibraryEntry { try library.entry(for: id) }
    func dismissFailure() { failure = nil }

    private func replace(_ entry: WallpaperLibraryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
        else { entries.insert(entry, at: 0) }
    }

    private func acquire() async {
        if isWorking { await withCheckedContinuation { waiters.append($0) } }
        else { isWorking = true }
    }

    private func release() {
        if waiters.isEmpty { isWorking = false }
        else { waiters.removeFirst().resume() }
    }

    private func present(_ error: Error, fallback: String) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        failure = (error as? WallpaperLibraryError)
            ?? WallpaperLibraryError(ruKey: fallback, detail: error.localizedDescription)
    }

    private nonisolated static func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated, operation: body)
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }

    private nonisolated static func prepareVideo(_ url: URL) async throws -> Data {
        guard url.isFileURL else { throw WallpaperLibraryError(ruKey: "Выбери локальное видео для обоев.") }
        let asset = AVURLAsset(url: url)
        async let playable = asset.load(.isPlayable)
        async let tracks = asset.loadTracks(withMediaType: .video)
        async let duration = asset.load(.duration)
        let (isPlayable, videoTracks, length) = try await (playable, tracks, duration)
        guard isPlayable, !videoTracks.isEmpty, length.isNumeric, length.seconds.isFinite, length.seconds > 0 else {
            throw WallpaperLibraryError(ruKey: "Это видео нельзя использовать как обои.")
        }
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 3840, height: 2160)
        let image = try await generator.image(at: .zero).image
        try Task.checkCancellation()
        guard let data = jpeg(image, quality: 0.9) else {
            throw WallpaperLibraryError(ruKey: "Не удалось подготовить кадр обоев.")
        }
        return data
    }

    private nonisolated static func smallPreview(at url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return jpeg(image, quality: 0.8)
    }

    private nonisolated static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private struct Snapshot: Sendable {
        let listing: WallpaperLibraryListing
        let previews: [UUID: Data]
    }
}
