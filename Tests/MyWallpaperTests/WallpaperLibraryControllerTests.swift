import AppKit
import Foundation
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct WallpaperLibraryControllerTests {
    @Test
    func reloadingRestoresPreviewsAndOptionsAfterOriginalDisappears() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let options = WallpaperLibraryOptions(target: .main, scaling: .fit, isMuted: false, volume: 0.4,
                                              animateOnBattery: true, syncSystemWallpaper: true)
        let entry = try fixture.create(options: options)
        try FileManager.default.removeItem(at: fixture.video)
        let controller = WallpaperLibraryController(library: fixture.library)
        #expect(controller.entries.isEmpty && !controller.hasLoadedLibrary)
        await controller.reload()
        #expect(controller.entries == [entry])
        #expect(controller.thumbnails[entry.id] != nil)
        #expect(controller.failure == nil && controller.libraryWarnings.isEmpty)
        #expect(controller.hasLoadedLibrary && !controller.isWorking)
        #expect(try Data(contentsOf: controller.videoURL(for: entry)) == fixture.videoBytes)
    }

    @Test
    func importRenameEditAndDeletePreserveOtherEntriesAndOriginal() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let kept = try fixture.create(name: "Keep")
        let poster = fixture.poster
        let controller = WallpaperLibraryController(library: fixture.library, prepareVideo: { _ in poster })
        await controller.reload()
        let added = try #require(await controller.addVideo(fixture.video, options: .init(volume: 0.3)))
        #expect(added.name == "Original")
        #expect(controller.thumbnails[added.id] != nil)
        #expect(added.options.volume == 0.3)

        let renamed = try #require(await controller.rename(added, name: "  Day / День  "))
        let options = WallpaperLibraryOptions(target: .main, scaling: .fit, volume: 0.8)
        let edited = try #require(await controller.updateOptions(added, options: options))
        #expect(edited.name == renamed.name && edited.name == "Day / День")
        #expect(controller.entries.first?.options == options)
        #expect(try controller.entry(for: added.id) == edited)
        #expect(await controller.delete(edited))
        #expect(controller.entries == [kept])
        #expect(controller.thumbnails[added.id] == nil && controller.thumbnails[kept.id] != nil)
        #expect(try Data(contentsOf: fixture.video) == fixture.videoBytes)
    }

    @Test
    func failedReloadOrImportKeepsPreviouslyLoadedRecords() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let kept = try fixture.create()
        let controller = WallpaperLibraryController(library: fixture.library, prepareVideo: { _ in
            throw WallpaperLibraryError(ruKey: "Это видео нельзя использовать как обои.")
        })
        await controller.reload()
        #expect(await controller.addVideo(fixture.video, options: .init()) == nil)
        #expect(controller.failure != nil && controller.entries == [kept])
        #expect(controller.thumbnails[kept.id] != nil && !controller.isWorking)
        controller.dismissFailure()
        let moved = fixture.root.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: fixture.library.rootURL, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.library.rootURL, withDestinationURL: moved)
        await controller.reload()
        #expect(controller.failure != nil && controller.entries == [kept])
        #expect(controller.thumbnails[kept.id] != nil && !controller.isWorking)
    }

    @Test
    func cancelledImportReleasesQueuedEditWithoutPublishingPartialRecord() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let entry = try fixture.create()
        let gate = WallpaperImportGate()
        let poster = fixture.poster
        let controller = WallpaperLibraryController(library: fixture.library, prepareVideo: { _ in
            await gate.wait()
            try Task.checkCancellation()
            return poster
        })
        await controller.reload()
        let importing = Task { await controller.addVideo(fixture.video, options: .init()) }
        await gate.waitUntilStarted()
        #expect(controller.isWorking)
        let editing = Task { await controller.updateOptions(entry, options: .init(volume: 0.22)) }
        importing.cancel()
        await gate.open()
        #expect(await importing.value == nil)
        let updated = try #require(await editing.value)
        #expect(updated.options.volume == 0.22)
        #expect(controller.entries == [updated])
        #expect(controller.failure == nil && !controller.isWorking)
        #expect(try fixture.library.list().entries == [updated])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.library.rootURL.path) == [entry.id.uuidString])
    }

    @Test
    func corruptRecordIsReportedWhileHealthyCardRemainsUsable() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let good = try fixture.create()
        let bad = try fixture.create()
        try Data("bad JSON".utf8).write(to: fixture.metadata(bad.id))
        let controller = WallpaperLibraryController(library: fixture.library)
        await controller.reload()
        #expect(controller.entries == [good])
        #expect(controller.libraryWarnings.count == 1 && controller.failure == nil)
        #expect(controller.thumbnails[good.id] != nil && controller.thumbnails[bad.id] == nil)
    }

    @Test
    func remoteURLIsRejectedBeforeAnyLibraryIsCreated() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let controller = WallpaperLibraryController(library: fixture.library)
        let url = try #require(URL(string: "https://example.invalid/video.mp4"))
        #expect(await controller.addVideo(url, options: .init()) == nil)
        #expect(controller.failure?.ruKey == "Выбери локальное видео для обоев.")
        #expect(!FileManager.default.fileExists(atPath: fixture.library.rootURL.path))
    }
}

private actor WallpaperImportGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false
    func wait() async {
        didStart = true
        started?.resume()
        started = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilStarted() async {
        if !didStart { await withCheckedContinuation { started = $0 } }
    }
    func open() { waiter?.resume(); waiter = nil }
}
