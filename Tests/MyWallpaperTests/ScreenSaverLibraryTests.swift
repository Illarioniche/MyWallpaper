import Foundation
import ImageIO
import Testing
@testable import MyWallpaper

@Suite
struct ScreenSaverLibraryTests {
    @Test
    func initializationAndListingAMissingLibraryDoNotCreateAnything() throws {
        try withFixture { fixture in
            let library = ScreenSaverLibrary(rootURL: fixture.library.rootURL)
            let listing = try library.list()
            #expect(listing.entries.isEmpty && listing.warnings.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: library.rootURL.path))
        }
    }

    @Test
    func creationReloadsIndependentRecordsAndNamesNeverBecomePaths() throws {
        try withFixture { fixture in
            let label = "../../Shared / Blue: Moon"
            let options = ScreenSaverExportOptions(scaling: .fit, animateOnBattery: true,
                                                  animateOnExternalPower: false, pauseInLowPowerMode: false)
            let beforeTemplate = try snapshot(fixture.template)
            let beforeVideo = try Data(contentsOf: fixture.video)
            let first = try create(fixture, name: "  \(label)  ", options: options)
            let second = try create(fixture, name: label)
            let reloaded = ScreenSaverLibrary(rootURL: fixture.library.rootURL)
            let listing = try reloaded.list()
            #expect(listing.warnings.isEmpty)
            #expect(Set(listing.entries.map(\.id)) == Set([first.id, second.id]))
            #expect(first.id != second.id)
            #expect(listing.entries.allSatisfy { $0.name == label })
            #expect(listing.entries.first(where: { $0.id == first.id }) == first)
            #expect(first.options == options)
            #expect(first.sourceFileName == "Original.MOV")
            for entry in listing.entries {
                let bundle = try reloaded.bundleURL(for: entry.id)
                #expect(bundle.lastPathComponent == "MyWallpaper.saver")
                #expect(bundle.deletingLastPathComponent().lastPathComponent == entry.id.uuidString)
                #expect(bundle.deletingLastPathComponent().deletingLastPathComponent() == reloaded.rootURL)
                #expect(try Data(contentsOf: reloaded.thumbnailURL(for: entry.id)) == fixture.poster)
            }
            #expect(try snapshot(fixture.template) == beforeTemplate)
            #expect(try Data(contentsOf: fixture.video) == beforeVideo)
            #expect(try FileManager.default.contentsOfDirectory(atPath: reloaded.rootURL.path).count == 2)
        }
    }

    @Test
    func renameOnlyChangesMetadataAndPreservesSignedBundleBytes() throws {
        try withFixture { fixture in
            let entry = try create(fixture, name: "Original")
            let bundle = try fixture.library.bundleURL(for: entry.id)
            let before = try snapshot(bundle)
            let renamed = try fixture.library.rename(id: entry.id, name: "  Night / Ночь 🌙  ")
            #expect(renamed.name == "Night / Ночь 🌙")
            #expect(renamed.id == entry.id && renamed.createdAt == entry.createdAt)
            #expect(renamed.sourceFileName == entry.sourceFileName && renamed.options == entry.options)
            #expect(try snapshot(bundle) == before)
            #expect(try fixture.library.bundleURL(for: entry.id) == bundle)
            #expect(try ScreenSaverLibrary(rootURL: fixture.library.rootURL).list().entries == [renamed])
        }
    }

    @Test
    func deleteRemovesOnlyTheRequestedOwnedEntry() throws {
        try withFixture { fixture in
            let removed = try create(fixture, name: "Duplicate")
            let kept = try create(fixture, name: "Duplicate")
            let keptBundle = try fixture.library.bundleURL(for: kept.id)
            let beforeKept = try snapshot(keptBundle)
            let beforeTemplate = try snapshot(fixture.template)
            try fixture.library.delete(id: removed.id)
            #expect(try fixture.library.list().entries == [kept])
            #expect(try snapshot(keptBundle) == beforeKept)
            #expect(try snapshot(fixture.template) == beforeTemplate)
            #expect(FileManager.default.fileExists(atPath: fixture.video.path))
            #expect(throws: ScreenSaverLibraryError.self) { try fixture.library.delete(id: removed.id) }
            #expect(throws: ScreenSaverLibraryError.self) { try fixture.library.bundleURL(for: removed.id) }
        }
    }

    @Test
    func invalidNamesDoNotCreateRecordsOrDamageExistingMetadata() throws {
        try withFixture { fixture in
            for name in ["", " \n\t ", "Bad\nName", "Bad\u{0000}Name", String(repeating: "é", count: 81)] {
                #expect(throws: ScreenSaverLibraryError.self) { try create(fixture, name: name) }
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.library.rootURL.path))
            let name = String(repeating: "e\u{301}", count: 80)
            let entry = try create(fixture, name: name)
            let before = try Data(contentsOf: metadataURL(entry, in: fixture.library))
            #expect(entry.name.count == 80, "The limit counts graphemes, not UTF-8 bytes or Unicode scalars.")
            #expect(throws: ScreenSaverLibraryError.self) { try fixture.library.rename(id: entry.id, name: "bad\tname") }
            #expect(try Data(contentsOf: metadataURL(entry, in: fixture.library)) == before)
        }
    }

    @Test
    func failedOrCancelledExportLeavesNoPublishedRecordOrStagingFolder() throws {
        try withFixture { fixture in
            let existing = try create(fixture, name: "Kept")
            let before = try snapshot(fixture.library.rootURL)
            #expect(throws: ScreenSaverLibraryError.self) {
                try fixture.library.create(videoURL: fixture.video, posterJPEG: fixture.poster, templateURL: fixture.template,
                                           name: "Failed", signer: { _ in throw CocoaError(.fileWriteNoPermission) })
            }
            #expect(throws: CancellationError.self) {
                try fixture.library.create(videoURL: fixture.video, posterJPEG: fixture.poster, templateURL: fixture.template,
                                           name: "Cancelled", signer: { _ in throw CancellationError() })
            }
            #expect(try snapshot(fixture.library.rootURL) == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.library.rootURL.path) == [existing.id.uuidString])
        }
    }

    @Test
    func corruptRecordsAreReportedAlongsideHealthyEntriesWithoutRepairingFiles() throws {
        try withFixture { fixture in
            let healthy = try create(fixture, name: "Healthy")
            let corrupt = try create(fixture, name: "Corrupt")
            let invalidMetadata = Data("invalid JSON".utf8)
            try invalidMetadata.write(to: metadataURL(corrupt, in: fixture.library))
            let partial = fixture.library.rootURL.appendingPathComponent(".creating-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
            try Data("in progress".utf8).write(to: partial.appendingPathComponent("metadata.json"))
            let unrelated = fixture.library.rootURL.appendingPathComponent("Unrecognized folder")
            try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
            let before = try snapshot(fixture.library.rootURL)

            let listing = try fixture.library.list()

            #expect(listing.entries == [healthy])
            #expect(listing.warnings.count == 2, "Corrupt and unrecognized records are reported; hidden staging is not published.")
            #expect(try snapshot(fixture.library.rootURL) == before)
            #expect(FileManager.default.fileExists(atPath: partial.path))
            #expect(throws: ScreenSaverLibraryError.self) { try fixture.library.rename(id: corrupt.id, name: "Do not replace corruption") }
            #expect(try Data(contentsOf: metadataURL(corrupt, in: fixture.library)) == invalidMetadata)
        }
    }

    @Test
    func metadataCannotImpersonateAnotherRecordOrRedirectResourcePaths() throws {
        try withFixture { fixture in
            let healthy = try create(fixture, name: "Healthy")
            let duplicate = try create(fixture, name: "Duplicate ID")
            try JSONEncoder().encode(healthy).write(to: metadataURL(duplicate, in: fixture.library))
            let listing = try fixture.library.list()
            #expect(listing.entries == [healthy])
            #expect(listing.warnings.count == 1)
            #expect(throws: ScreenSaverLibraryError.self) { try fixture.library.delete(id: duplicate.id) }
            #expect(FileManager.default.fileExists(atPath: metadataURL(duplicate, in: fixture.library).path))

            let displayOnly = ScreenSaverLibraryEntry(id: healthy.id, name: healthy.name, createdAt: healthy.createdAt,
                                                     sourceFileName: "../../untrusted/path.txt", options: healthy.options)
            try JSONEncoder().encode(displayOnly).write(to: metadataURL(healthy, in: fixture.library))
            #expect(try fixture.library.bundleURL(for: healthy.id).lastPathComponent == "MyWallpaper.saver")
            #expect(try fixture.library.thumbnailURL(for: healthy.id).lastPathComponent == "poster.jpg")
        }
    }

    @Test
    func symlinkedRootOrEntryCannotReadRenameOrDeleteExternalFiles() throws {
        try withFixture { fixture in
            let entry = try create(fixture, name: "External sentinel")
            let owned = fixture.library.rootURL.appendingPathComponent(entry.id.uuidString)
            let outside = fixture.root.appendingPathComponent("Outside")
            try FileManager.default.moveItem(at: owned, to: outside)
            try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: outside)
            let before = try snapshot(outside)
            let listing = try fixture.library.list()
            #expect(listing.entries.isEmpty && listing.warnings.count == 1)
            #expect(throws: ScreenSaverLibraryError.self) { try fixture.library.bundleURL(for: entry.id) }
            #expect(throws: ScreenSaverLibraryError.self) { try fixture.library.rename(id: entry.id, name: "Wrong") }
            #expect(throws: ScreenSaverLibraryError.self) { try fixture.library.delete(id: entry.id) }
            #expect(try snapshot(outside) == before)

            let rootLink = fixture.root.appendingPathComponent("Root link")
            try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: fixture.library.rootURL)
            let redirected = ScreenSaverLibrary(rootURL: rootLink)
            #expect(throws: ScreenSaverLibraryError.self) { try redirected.list() }
            #expect(throws: ScreenSaverLibraryError.self) { try redirected.delete(id: entry.id) }
            #expect(throws: ScreenSaverLibraryError.self) {
                try redirected.create(videoURL: fixture.video, posterJPEG: fixture.poster, templateURL: fixture.template,
                                      name: "Wrong", signer: { _ in Issue.record("A symlink root reached the exporter.") })
            }
            #expect(try snapshot(outside) == before)
        }
    }

    @Test
    func linkedMetadataAndBundleResourcesAreNotFollowed() throws {
        try withFixture { fixture in
            let entry = try create(fixture, name: "Linked")
            let metadata = metadataURL(entry, in: fixture.library)
            let externalMetadata = fixture.root.appendingPathComponent("External.json")
            try FileManager.default.moveItem(at: metadata, to: externalMetadata)
            try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: externalMetadata)
            let before = try Data(contentsOf: externalMetadata)
            #expect(try fixture.library.list().warnings.count == 1)
            #expect(throws: ScreenSaverLibraryError.self) { try fixture.library.rename(id: entry.id, name: "Do not write through link") }
            #expect(try Data(contentsOf: externalMetadata) == before)
            try FileManager.default.removeItem(at: metadata)
            try FileManager.default.moveItem(at: externalMetadata, to: metadata)
            let poster = try fixture.library.thumbnailURL(for: entry.id)
            try FileManager.default.removeItem(at: poster)
            try FileManager.default.createSymbolicLink(at: poster, withDestinationURL: fixture.video)
            #expect(throws: ScreenSaverLibraryError.self) { try fixture.library.thumbnailURL(for: entry.id) }
            #expect(throws: ScreenSaverLibraryError.self) { try fixture.library.bundleURL(for: entry.id) }
            #expect(try fixture.library.list().entries.isEmpty)
        }
    }

    @Test
    func damagedBundleIdentityAndConfigurationAreReportedAndCannotBeInstalled() throws {
        try withFixture { fixture in
            let entry = try create(fixture, name: "Damaged bundle")
            let bundle = try fixture.library.bundleURL(for: entry.id)
            let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
            let originalInfo = try Data(contentsOf: infoURL)
            var info = try #require(PropertyListSerialization.propertyList(from: originalInfo, format: nil) as? [String: Any])
            for key in ["CFBundleIdentifier", "NSPrincipalClass", "CFBundleExecutable", "CFBundlePackageType"] {
                let original = info[key]
                info[key] = "Unexpected value"
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
                let listing = try fixture.library.list()
                #expect(listing.entries.isEmpty && listing.warnings.count == 1)
                #expect(throws: ScreenSaverLibraryError.self) { try fixture.library.bundleURL(for: entry.id) }
                info[key] = original
            }
            try Data(repeating: 32, count: 65_537).write(to: infoURL)
            #expect(try fixture.library.list().warnings.count == 1)
            try originalInfo.write(to: infoURL)
            let configurationURL = bundle.appendingPathComponent("Contents/Resources/configuration.json")
            let originalConfiguration = try Data(contentsOf: configurationURL)
            let config = try #require(JSONSerialization.jsonObject(with: originalConfiguration) as? [String: Any])
            for mutation: [String: Any] in [["videoFileName": "../../outside.mov"], ["scaling": "invalid"],
                                           ["animateOnBattery": "yes"], ["animateOnExternalPower": false]] {
                let changed = config.merging(mutation) { _, replacement in replacement }
                try JSONSerialization.data(withJSONObject: changed).write(to: configurationURL)
                let listing = try fixture.library.list()
                #expect(listing.entries.isEmpty && listing.warnings.count == 1)
                #expect(throws: ScreenSaverLibraryError.self) { try fixture.library.bundleURL(for: entry.id) }
            }
        }
    }

    @Test
    func unsafeRootAndOversizedMetadataFailWithoutReplacingExistingFiles() throws {
        try withFixture { fixture in
            let fileRoot = fixture.root.appendingPathComponent("Not a directory")
            let sentinel = Data("untouched".utf8)
            try sentinel.write(to: fileRoot)
            let library = ScreenSaverLibrary(rootURL: fileRoot)
            #expect(throws: ScreenSaverLibraryError.self) { try library.list() }
            #expect(throws: ScreenSaverLibraryError.self) {
                try library.create(videoURL: fixture.video, posterJPEG: fixture.poster, templateURL: fixture.template,
                                   name: "Cannot create", signer: { _ in })
            }
            #expect(try Data(contentsOf: fileRoot) == sentinel)
            let entry = try create(fixture, name: "Too large")
            let oversized = Data(repeating: 32, count: 65_537)
            try oversized.write(to: metadataURL(entry, in: fixture.library))
            let listing = try fixture.library.list()
            #expect(listing.entries.isEmpty && listing.warnings.count == 1)
            #expect(try Data(contentsOf: metadataURL(entry, in: fixture.library)) == oversized)
        }
    }

    @Test
    func separateInstallersPreserveLibraryMediaAndStableIdentityAcrossRenames() throws {
        try withFixture { fixture in
            let first = try create(fixture, name: "Лес / Forest")
            let second = try create(fixture, name: "Лес / Forest")
            let saved = try fixture.library.bundleURL(for: first.id)
            let savedBytes = try snapshot(saved)
            try FileManager.default.removeItem(at: fixture.video)
            let a = try fixture.library.prepareInstallation(id: first.id, templateURL: nil, signer: { _ in })
            let b = try fixture.library.prepareInstallation(id: second.id, templateURL: nil, signer: { _ in })
            #expect(a.lastPathComponent != b.lastPathComponent)
            let aInfo = try info(a)
            let bInfo = try info(b)
            #expect(aInfo["CFBundleIdentifier"] as? String != bInfo["CFBundleIdentifier"] as? String)
            #expect(aInfo["NSPrincipalClass"] as? String != bInfo["NSPrincipalClass"] as? String)
            #expect(aInfo["CFBundleDisplayName"] as? String == first.name)
            #expect(try snapshot(saved) == savedBytes)
            #expect(try Data(contentsOf: a.appendingPathComponent("Contents/Resources/video.mov")) ==
                    Data(contentsOf: saved.appendingPathComponent("Contents/Resources/video.mov")))
            #expect(FileManager.default.fileExists(atPath: a.appendingPathComponent("Contents/Resources/thumbnail.png").path))

            _ = try fixture.library.rename(id: first.id, name: "Новое имя")
            let renamed = try fixture.library.prepareInstallation(id: first.id, templateURL: nil, signer: { _ in })
            let renamedInfo = try info(renamed)
            #expect(renamed == a, "Renaming must not create a second system installation.")
            #expect(renamedInfo["CFBundleDisplayName"] as? String == "Новое имя")
            #expect(renamedInfo["CFBundleIdentifier"] as? String == aInfo["CFBundleIdentifier"] as? String)
            #expect(try snapshot(saved) == savedBytes)
            #expect(try fixture.library.list().entries.count == 2)
        }
    }

    @Test
    func oldSavedRecordUsesNewRuntimeWithoutOriginalVideoOrLibraryRewrite() throws {
        try withFixture { fixture in
            let entry = try create(fixture, name: "Legacy")
            let saved = try fixture.library.bundleURL(for: entry.id)
            let plist = saved.appendingPathComponent("Contents/Info.plist")
            var legacy = try info(saved)
            legacy.removeValue(forKey: "MyWallpaperRuntimeVersion")
            try PropertyListSerialization.data(fromPropertyList: legacy, format: .xml, options: 0).write(to: plist)
            let before = try snapshot(saved)
            try FileManager.default.removeItem(at: fixture.video)
            let installed = try fixture.library.prepareInstallation(id: entry.id, templateURL: fixture.template, signer: { _ in })
            #expect(try info(installed)["MyWallpaperRuntimeVersion"] as? Int == 2)
            #expect(try snapshot(saved) == before)
            #expect(try fixture.library.list().entries == [entry])
            #expect(throws: ScreenSaverLibraryError.self) {
                try fixture.library.prepareInstallation(id: entry.id, templateURL: nil, signer: { _ in })
            }
        }
    }

    @Test
    func failedInstallPreparationPreservesPreviousInstallerAndCleansTemporaryFiles() throws {
        try withFixture { fixture in
            let entry = try create(fixture, name: "Keep previous")
            _ = try fixture.library.prepareInstallation(id: entry.id, templateURL: fixture.template, signer: { _ in })
            let before = try snapshot(fixture.library.rootURL)
            #expect(throws: ScreenSaverLibraryError.self) {
                try fixture.library.prepareInstallation(id: entry.id, templateURL: fixture.template,
                                                        signer: { _ in throw CocoaError(.fileWriteNoPermission) })
            }
            #expect(try snapshot(fixture.library.rootURL) == before)
            let files = try FileManager.default.contentsOfDirectory(atPath: fixture.library.rootURL.appendingPathComponent(entry.id.uuidString).path)
            #expect(!files.contains { $0.hasPrefix(".installing-") })
        }
    }

    private func info(_ bundle: URL) throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any])
    }

    private func create(_ fixture: LibraryFixture, name: String,
                        options: ScreenSaverExportOptions = .init()) throws -> ScreenSaverLibraryEntry {
        try fixture.library.create(videoURL: fixture.video, posterJPEG: fixture.poster, templateURL: fixture.template,
                                   name: name, options: options, signer: { bundle in
            let signature = bundle.appendingPathComponent("Contents/_CodeSignature")
            try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: false)
            try Data("signed bytes must not change on rename".utf8).write(to: signature.appendingPathComponent("CodeResources"))
        })
    }

    private func metadataURL(_ entry: ScreenSaverLibraryEntry, in library: ScreenSaverLibrary) -> URL {
        library.rootURL.appendingPathComponent(entry.id.uuidString).appendingPathComponent("metadata.json")
    }

    private func withFixture(_ body: (LibraryFixture) throws -> Void) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ScreenSaverLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let template = root.appendingPathComponent("Template.saver", isDirectory: true)
        try manager.createDirectory(at: template.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try manager.createDirectory(at: template.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: false)
        try Data("fake executable; tests inject the signer".utf8).write(to: template.appendingPathComponent("Contents/MacOS/MyWallpaperScreenSaver"))
        let metadata: [String: Any] = ["MyWallpaperRuntimeVersion": 2, "CFBundlePackageType": "BNDL", "CFBundleIdentifier": "app.mywallpaper.screensaver",
                        "CFBundleExecutable": "MyWallpaperScreenSaver", "NSPrincipalClass": "MyWallpaperScreenSaverView"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: template.appendingPathComponent("Contents/Info.plist"))
        let video = root.appendingPathComponent("Original.MOV")
        try Data("fake media; the controller handles decoding".utf8).write(to: video)
        let library = ScreenSaverLibrary(rootURL: root.appendingPathComponent("Support/MyWallpaper/ScreenSavers", isDirectory: true))
        try body(LibraryFixture(root: root, template: template, video: video, poster: makeJPEG(), library: library))
    }

    private func makeJPEG() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let target = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(target, image, nil)
        try #require(CGImageDestinationFinalize(target))
        return data as Data
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
        }
        return result
    }
}

private struct LibraryFixture {
    let root: URL
    let template: URL
    let video: URL
    let poster: Data
    let library: ScreenSaverLibrary
}
