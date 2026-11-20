import Foundation
import Testing
@testable import MyWallpaper

@Suite
struct ScreenSaverSyncStoreTests {
    @Test
    func anUnusedFeedIsReadOnlyAndCreatesNoFiles() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        #expect(try store.snapshot() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.rootURL.path))
    }

    @Test
    func publishedManifestUsesOwnedImmutableCopiesWithoutExposingSourcePath() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        let options = ScreenSaverExportOptions(scaling: .fit, animateOnBattery: true,
                                              animateOnExternalPower: false, pauseInLowPowerMode: false)
        let saved = try publish(store, fixture, options: options, name: "../../Night / Ночь")
        #expect(try store.snapshot() == saved)
        #expect(saved.version == 1 && saved.name == "../../Night / Ночь" && saved.videoFileName == "video.mov")
        #expect(saved.options == options)
        let video = try store.videoURL(for: saved)
        let poster = try store.posterURL(for: saved)
        #expect(video.deletingLastPathComponent().lastPathComponent == saved.revision.uuidString)
        #expect(try Data(contentsOf: video) == fixture.videoBytes)
        #expect(try Data(contentsOf: poster) == fixture.poster)
        let json = try String(contentsOf: store.rootURL.appendingPathComponent("current.json"), encoding: .utf8)
        #expect(!json.contains(fixture.root.path) && !json.contains(fixture.video.lastPathComponent))
        try FileManager.default.removeItem(at: fixture.video)
        #expect(try store.snapshot() == saved)
        #expect(try Data(contentsOf: video) == fixture.videoBytes)
    }

    @Test
    func settingsChangesAndSwitchingBackReuseMediaCopies() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        let first = try publish(store, fixture)
        let second = try publish(store, fixture, options: .init(scaling: .fit, animateOnBattery: true), name: "Renamed")
        #expect(second.revision == first.revision)
        #expect(second.options != first.options && second.name != first.name)
        #expect(try store.videoURL(for: second) == store.videoURL(for: first))
        let other = fixture.root.appendingPathComponent("Other.mp4")
        try Data("Another video".utf8).write(to: other)
        let third = try store.publish(videoURL: other, posterJPEG: fixture.poster, options: .init(), name: "Other")
        #expect(third.revision != first.revision)
        let back = try publish(store, fixture, options: .init(scaling: .fit), name: "Back")
        #expect(back.revision == first.revision)
        #expect(try store.snapshot() == back)
        #expect(try revisionNames(store).count == 2)
        #expect(try Data(contentsOf: store.videoURL(for: third)) == Data("Another video".utf8),
                "An existing saver may still be playing the previous revision.")
    }

    @Test
    func changingTheSourceCreatesANewRevisionAndKeepsOldBytes() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        let first = try publish(store, fixture)
        let changedBytes = Data("Replacement contents, with a different length.".utf8)
        try changedBytes.write(to: fixture.video, options: .atomic)
        let changed = try publish(store, fixture)
        #expect(changed.revision != first.revision)
        #expect(try Data(contentsOf: store.videoURL(for: first)) == fixture.videoBytes)
        #expect(try Data(contentsOf: store.videoURL(for: changed)) == changedBytes)
    }

    @Test
    func failedPublicationKeepsTheLastCompleteSnapshotAndSources() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        let first = try publish(store, fixture)
        let before = try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path).sorted()
        let unsupported = fixture.root.appendingPathComponent("Unsupported.avi")
        try fixture.videoBytes.write(to: unsupported)
        #expect(throws: ScreenSaverSyncError.self) {
            try store.publish(videoURL: unsupported, posterJPEG: fixture.poster, options: .init(), name: "Bad format")
        }
        #expect(throws: ScreenSaverSyncError.self) {
            try store.publish(videoURL: fixture.video, posterJPEG: Data("not JPEG".utf8), options: .init(), name: "Bad poster")
        }
        #expect(throws: ScreenSaverSyncError.self) {
            try store.publish(videoURL: fixture.root.appendingPathComponent("missing.mov"),
                              posterJPEG: fixture.poster, options: .init(), name: "Missing")
        }
        #expect(try store.snapshot() == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path).sorted() == before)
        #expect(try Data(contentsOf: fixture.video) == fixture.videoBytes)
    }

    @Test
    func cancelledPublicationDoesNotReplaceTheSelectedRevision() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        let first = try publish(store, fixture)
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try store.publish(videoURL: fixture.video, posterJPEG: fixture.poster,
                                     options: .init(animateOnBattery: true), name: "Cancelled")
        }
        do {
            _ = try await cancelled.value
            Issue.record("A cancelled publication must fail before committing its manifest.")
        } catch is CancellationError { }
        #expect(try store.snapshot() == first)
        #expect(try revisionNames(store) == [first.revision.uuidString])
    }

    @Test
    func symbolicLinksAtFeedManifestRevisionAndMediaBoundariesAreRejected() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        let first = try publish(store, fixture)
        let linked = fixture.root.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: store.rootURL)
        #expect(throws: ScreenSaverSyncError.self) { try ScreenSaverSyncStore(rootURL: linked).snapshot() }
        #expect(throws: ScreenSaverSyncError.self) { try publish(ScreenSaverSyncStore(rootURL: linked), fixture) }

        let manifest = store.rootURL.appendingPathComponent("current.json")
        let manifestData = try Data(contentsOf: manifest)
        let outside = fixture.root.appendingPathComponent("Untouched.json")
        try manifestData.write(to: outside)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
        #expect(throws: ScreenSaverSyncError.self) { try store.snapshot() }
        #expect(throws: ScreenSaverSyncError.self) { try publish(store, fixture) }
        #expect(try Data(contentsOf: outside) == manifestData)
        try FileManager.default.removeItem(at: manifest)
        try manifestData.write(to: manifest)

        let revision = store.rootURL.appendingPathComponent(first.revision.uuidString)
        let moved = fixture.root.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: revision, to: moved)
        try FileManager.default.createSymbolicLink(at: revision, withDestinationURL: moved)
        #expect(throws: ScreenSaverSyncError.self) { try store.snapshot() }
        try FileManager.default.removeItem(at: revision)
        try FileManager.default.moveItem(at: moved, to: revision)
        let video = try store.videoURL(for: first)
        try FileManager.default.removeItem(at: video)
        try FileManager.default.createSymbolicLink(at: video, withDestinationURL: fixture.video)
        #expect(throws: ScreenSaverSyncError.self) { try store.snapshot() }
        #expect(throws: ScreenSaverSyncError.self) { try store.videoURL(for: first) }
        #expect(try Data(contentsOf: fixture.video) == fixture.videoBytes)
    }

    @Test
    func malformedManifestCannotEscapeItsRevision() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        _ = try publish(store, fixture)
        let manifest = store.rootURL.appendingPathComponent("current.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        json["videoFileName"] = "../../Original.MOV"
        try JSONSerialization.data(withJSONObject: json).write(to: manifest, options: .atomic)
        #expect(throws: ScreenSaverSyncError.self) { try store.snapshot() }
        #expect(try Data(contentsOf: fixture.video) == fixture.videoBytes)
    }

    @Test
    func installerKeepsAStableIdentityAndFailedRebuildPreservesThePreviousCopy() throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        let current = try publish(store, fixture)
        let template = try makeTemplate(fixture)
        let installed = try store.prepareInstaller(templateURL: template, signer: { _ in })
        let infoURL = installed.appendingPathComponent("Contents/Info.plist")
        let oldInfo = try Data(contentsOf: infoURL)
        let info = try #require(PropertyListSerialization.propertyList(from: oldInfo, format: nil) as? [String: Any])
        #expect(info["CFBundleIdentifier"] as? String == "app.mywallpaper.screensaver.3f3e7bd1-66f2-4d84-b3b5-2dfe09b53454")
        #expect(info["CFBundleDisplayName"] as? String == "MyWallpaper — Sync")
        #expect(installed.lastPathComponent == "MyWallpaper-3F3E7BD1-66F2-4D84-B3B5-2DFE09B53454.saver")
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/Resources/video.mov").path),
                "A linked installer reads the feed and must not duplicate its large video.")
        #expect(throws: ScreenSaverSyncError.self) {
            try store.prepareInstaller(templateURL: template, signer: { _ in throw CocoaError(.fileWriteNoPermission) })
        }
        #expect(try Data(contentsOf: infoURL) == oldInfo)
        #expect(try store.snapshot() == current)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path).allSatisfy { !$0.hasPrefix(".installing-") })
        let updated = try publish(store, fixture, options: .init(scaling: .fit), name: "New label")
        #expect(updated.revision == current.revision)
        #expect(try store.prepareInstaller(templateURL: template, signer: { _ in }) == installed)
    }

    private func makeStore(_ fixture: WallpaperLibraryFixture) -> ScreenSaverSyncStore {
        ScreenSaverSyncStore(rootURL: fixture.root.appendingPathComponent("Sync"))
    }

    private func publish(_ store: ScreenSaverSyncStore, _ fixture: WallpaperLibraryFixture,
                         options: ScreenSaverExportOptions = .init(), name: String = "Current") throws -> ScreenSaverSyncSnapshot {
        try store.publish(videoURL: fixture.video, posterJPEG: fixture.poster, options: options, name: name)
    }

    private func revisionNames(_ store: ScreenSaverSyncStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path).filter { UUID(uuidString: $0) != nil }.sorted()
    }

    private func makeTemplate(_ fixture: WallpaperLibraryFixture) throws -> URL {
        let template = fixture.root.appendingPathComponent("Template.saver", isDirectory: true)
        try FileManager.default.createDirectory(at: template.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("Template executable; tests inject a signer and do not load it.".utf8)
            .write(to: template.appendingPathComponent("Contents/MacOS/MyWallpaperScreenSaver"))
        let info: [String: Any] = ["CFBundlePackageType": "BNDL", "CFBundleIdentifier": "app.mywallpaper.screensaver",
                                  "CFBundleExecutable": "MyWallpaperScreenSaver", "NSPrincipalClass": "MyWallpaperScreenSaverView",
                                  "MyWallpaperRuntimeVersion": 3]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: template.appendingPathComponent("Contents/Info.plist"))
        return template
    }
}
