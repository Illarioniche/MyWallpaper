import Foundation
import ImageIO
import Testing
@testable import MyWallpaper

@Suite
struct WallpaperLibraryTests {
    @Test
    func missingLibraryIsReadOnlyUntilFirstImport() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        #expect(try fixture.library.list().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.library.rootURL.path))
    }

    @Test
    func copiedMediaAndIndependentSettingsSurviveOriginalDeletion() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.create(name: "../../Night / Ночь", options: .init(target: .main, scaling: .fit, isMuted: false,
            volume: 0.23, animateOnExternalPower: false, animateOnBattery: true, pauseInLowPowerMode: false,
            pauseWhenCovered: false, syncSystemWallpaper: true))
        let second = try fixture.create(name: first.name)
        try FileManager.default.removeItem(at: fixture.video)
        let library = WallpaperLibrary(rootURL: fixture.library.rootURL)
        #expect(Set(try library.list().entries.map(\.id)) == Set([first.id, second.id]))
        #expect(first.id != second.id && first.options != second.options)
        #expect(try library.entry(for: first.id) == first)
        let savedURL = try library.videoURL(for: first.id)
        #expect(savedURL.deletingLastPathComponent().lastPathComponent == first.id.uuidString)
        #expect(savedURL.lastPathComponent == "video.mov")
        #expect(try Data(contentsOf: savedURL) == fixture.videoBytes)
        #expect(try Data(contentsOf: library.thumbnailURL(for: first.id)) == fixture.poster)
    }

    @Test
    func renameAndOptionsEditsPreserveMediaAndEachOther() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.create()
        let savedURL = try fixture.library.videoURL(for: entry.id)
        let renamed = try fixture.library.rename(id: entry.id, name: "  Moon 🌙  ")
        let options = WallpaperLibraryOptions(scaling: .fit, volume: 0.35, animateOnBattery: true)
        let updated = try fixture.library.updateOptions(id: entry.id, options: options)
        #expect(updated.id == entry.id && updated.createdAt == entry.createdAt)
        #expect(updated.name == renamed.name && updated.name == "Moon 🌙")
        #expect(updated.options == options)
        #expect(try fixture.library.videoURL(for: entry.id) == savedURL)
        #expect(try Data(contentsOf: savedURL) == fixture.videoBytes)
    }

    @Test
    func deletionOnlyRemovesSelectedCopy() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let removed = try fixture.create()
        let kept = try fixture.create()
        try fixture.library.delete(id: removed.id)
        #expect(try fixture.library.list().entries == [kept])
        #expect(try Data(contentsOf: fixture.video) == fixture.videoBytes)
        #expect(try Data(contentsOf: fixture.library.videoURL(for: kept.id)) == fixture.videoBytes)
        #expect(throws: WallpaperLibraryError.self) { try fixture.library.videoURL(for: removed.id) }
    }

    @Test
    func invalidInputAndFailedCopyLeaveExistingRecordUntouched() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.create()
        for name in ["", "  ", "Bad\nName", String(repeating: "a", count: 81)] {
            #expect(throws: WallpaperLibraryError.self) { try fixture.library.rename(id: entry.id, name: name) }
        }
        #expect(throws: WallpaperLibraryError.self) {
            try fixture.library.updateOptions(id: entry.id, options: .init(volume: .nan))
        }
        #expect(throws: WallpaperLibraryError.self) {
            try fixture.library.create(videoURL: fixture.video, posterJPEG: Data("bad".utf8), name: "Invalid")
        }
        #expect(throws: WallpaperLibraryError.self) {
            try fixture.library.create(videoURL: fixture.root.appendingPathComponent("missing.mov"), posterJPEG: fixture.poster, name: "Missing")
        }
        #expect(try fixture.library.entry(for: entry.id) == entry)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.library.rootURL.path) == [entry.id.uuidString])
    }

    @Test
    func damagedRecordDoesNotHideHealthyEntries() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let good = try fixture.create()
        let bad = try fixture.create()
        try Data("broken metadata".utf8).write(to: fixture.metadata(bad.id))
        let listing = try fixture.library.list()
        #expect(listing.entries == [good])
        #expect(listing.warnings.count == 1)
        #expect(try Data(contentsOf: fixture.metadata(bad.id)) == Data("broken metadata".utf8))
    }

    @Test
    func rootEntryAndMediaSymlinksAreRejectedWithoutDeletingTargets() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.create()
        let directory = fixture.library.rootURL.appendingPathComponent(entry.id.uuidString)
        let moved = fixture.root.appendingPathComponent("Untouched")
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
        #expect(throws: WallpaperLibraryError.self) { try fixture.library.delete(id: entry.id) }
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("metadata.json").path))
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        let saved = try fixture.library.videoURL(for: entry.id)
        try FileManager.default.removeItem(at: saved)
        try FileManager.default.createSymbolicLink(at: saved, withDestinationURL: fixture.video)
        #expect(throws: WallpaperLibraryError.self) { try fixture.library.videoURL(for: entry.id) }
        #expect(try Data(contentsOf: fixture.video) == fixture.videoBytes)
        let linkedRoot = fixture.root.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: fixture.library.rootURL)
        #expect(throws: WallpaperLibraryError.self) { try WallpaperLibrary(rootURL: linkedRoot).list() }
    }

    @Test
    func cancelledCreationPublishesNoRecord() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.create()
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled create should fail.")
        } catch is CancellationError { }
        #expect(try fixture.library.list().entries.isEmpty)
    }
}

struct WallpaperLibraryFixture: Sendable {
    let root: URL
    let library: WallpaperLibrary
    let video: URL
    let poster: Data
    let videoBytes = Data("A synthetic media file; storage tests never decode it.".utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = WallpaperLibrary(rootURL: root.appendingPathComponent("Library"))
        video = root.appendingPathComponent("Original.MOV")
        try videoBytes.write(to: video)
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        poster = data as Data
    }

    func create(name: String = "Saved", options: WallpaperLibraryOptions = .init()) throws -> WallpaperLibraryEntry {
        try library.create(videoURL: video, posterJPEG: poster, name: name, options: options)
    }
    func metadata(_ id: UUID) -> URL { library.rootURL.appendingPathComponent(id.uuidString).appendingPathComponent("metadata.json") }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
