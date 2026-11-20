import AppKit
import Foundation
import ImageIO
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct ScreenSaverLibraryControllerTests {
    @Test
    func reloadRestoresSavedEntriesAndThumbnailsWithoutOriginalVideo() async throws {
        try await withFixture { fixture in
            let library = ScreenSaverLibrary(rootURL: fixture.libraryRoot)
            let first = try await create(fixture, in: library, name: "Океан")
            let second = try await create(fixture, in: library, name: "Forest")
            try FileManager.default.removeItem(at: fixture.video)

            for _ in 0..<2 {
                let controller = ScreenSaverController(templateURL: nil, library: library, installerSigner: { _ in }, openInstaller: { _ in
                    Issue.record("Reloading must not open the installer.")
                    return false
                })
                await controller.reloadLibrary()
                #expect(Set(controller.entries.map(\.id)) == Set([first.id, second.id]))
                #expect(controller.thumbnails[first.id] != nil && controller.thumbnails[second.id] != nil)
                #expect(controller.failure == nil && controller.libraryWarnings.isEmpty)
                #expect(controller.installationRequestedName == nil)
                #expect(!controller.isWorking)
            }
        }
    }

    @Test
    func selectingSavedEntriesKeepsTheirOptionsAndDoesNotOverwriteNewSaverDraft() async throws {
        try await withFixture { fixture in
            let library = ScreenSaverLibrary(rootURL: fixture.libraryRoot)
            let custom = ScreenSaverExportOptions(scaling: .fit, animateOnBattery: true,
                                                  animateOnExternalPower: false, pauseInLowPowerMode: false)
            let first = try await create(fixture, in: library, name: "Night / Ночь", options: custom)
            let second = try await create(fixture, in: library, name: "Day")
            let controller = ScreenSaverController(templateURL: nil, library: library, installerSigner: { _ in }, openInstaller: { _ in
                Issue.record("Selecting a library entry must not install it.")
                return false
            })
            await controller.reloadLibrary()
            controller.name = "Unsaved draft"
            controller.scaling = .fit
            controller.animateOnBattery = true
            controller.pauseInLowPowerMode = false

            controller.selectEntry(first.id)
            #expect(controller.selectedEntryID == first.id)
            let selected = try #require(controller.entries.first { $0.id == controller.selectedEntryID })
            #expect(selected.name == "Night / Ночь" && selected.options == custom)

            controller.selectEntry(second.id)
            #expect(controller.selectedEntryID == second.id)
            #expect(controller.entries.first { $0.id == second.id }?.options == ScreenSaverExportOptions())
            #expect(controller.name == "Unsaved draft" && controller.scaling == .fit)
            #expect(controller.animateOnBattery && controller.animateOnExternalPower && !controller.pauseInLowPowerMode)
            #expect(controller.installationRequestedName == nil)
        }
    }

    @Test
    func renamingUpdatesSelectedMetadataWithoutMovingOrRewritingBundle() async throws {
        try await withFixture { fixture in
            let library = ScreenSaverLibrary(rootURL: fixture.libraryRoot)
            let entry = try await create(fixture, in: library, name: "Before")
            let bundle = fixture.bundleURL(for: entry.id)
            let configuration = bundle.appendingPathComponent("Contents/Resources/configuration.json")
            let originalConfiguration = try Data(contentsOf: configuration)
            let controller = ScreenSaverController(templateURL: nil, library: library, installerSigner: { _ in }, openInstaller: { _ in false })
            await controller.reloadLibrary()
            controller.selectEntry(entry.id)
            controller.name = "Unrelated draft"

            await controller.rename(id: entry.id, name: "  After / После 🌙  ")

            #expect(controller.selectedEntryID == entry.id)
            #expect(controller.name == "Unrelated draft")
            #expect(controller.entries.first?.name == "After / После 🌙")
            #expect(controller.failure == nil)
            #expect(FileManager.default.fileExists(atPath: bundle.path))
            #expect(bundle.lastPathComponent == "MyWallpaper.saver")
            #expect(try Data(contentsOf: configuration) == originalConfiguration)

            let restored = ScreenSaverController(templateURL: nil, library: library, installerSigner: { _ in }, openInstaller: { _ in false })
            await restored.reloadLibrary()
            #expect(restored.entries.first?.id == entry.id)
            #expect(restored.entries.first?.name == "After / После 🌙")
        }
    }

    @Test
    func deletingSelectedEntryPreservesOtherEntriesAndOriginalVideo() async throws {
        try await withFixture { fixture in
            let library = ScreenSaverLibrary(rootURL: fixture.libraryRoot)
            let keep = try await create(fixture, in: library, name: "Keep")
            let remove = try await create(fixture, in: library, name: "Remove")
            let controller = ScreenSaverController(templateURL: nil, library: library, installerSigner: { _ in }, openInstaller: { _ in
                Issue.record("Deleting a library entry must not contact the installer.")
                return false
            })
            await controller.reloadLibrary()
            controller.selectEntry(remove.id)

            await controller.delete(id: remove.id)

            #expect(controller.entries.map(\.id) == [keep.id])
            #expect(controller.selectedEntryID != remove.id)
            #expect(controller.thumbnails[remove.id] == nil)
            #expect(controller.thumbnails[keep.id] != nil)
            #expect(controller.failure == nil)
            #expect(!FileManager.default.fileExists(atPath: fixture.bundleURL(for: remove.id).path))
            #expect(FileManager.default.fileExists(atPath: fixture.bundleURL(for: keep.id).path))
            #expect(FileManager.default.fileExists(atPath: fixture.video.path))
        }
    }

    @Test
    func existingEntryCanBeHandedToInstallerWithoutBundledTemplate() async throws {
        try await withFixture { fixture in
            let library = ScreenSaverLibrary(rootURL: fixture.libraryRoot)
            let first = try await create(fixture, in: library, name: "First")
            let second = try await create(fixture, in: library, name: "Second")
            var opened: [URL] = []
            let controller = ScreenSaverController(templateURL: nil, library: library, installerSigner: { _ in }, openInstaller: { url in
                opened.append(url)
                return true
            })
            await controller.reloadLibrary()
            controller.selectEntry(first.id)
            #expect(!controller.hasTemplate)

            await controller.install(id: second.id)

            #expect(opened == [fixture.libraryRoot.appendingPathComponent(second.id.uuidString)
                .appendingPathComponent(".installation").appendingPathComponent(ScreenSaverInstallationIdentity(id: second.id, name: second.name).fileName)])
            #expect(controller.installationRequestedName == "Second")
            #expect(controller.failure == nil && !controller.isWorking)
            #expect(controller.entries.count == 2, "Installer handoff must not remove the persistent source record.")
        }
    }

    @Test
    func installerOpenFailureIsReportedWithoutClaimingAnInstallation() async throws {
        try await withFixture { fixture in
            let library = ScreenSaverLibrary(rootURL: fixture.libraryRoot)
            let entry = try await create(fixture, in: library, name: "Unavailable handler")
            var attempts = 0
            let controller = ScreenSaverController(templateURL: nil, library: library, installerSigner: { _ in }, openInstaller: { _ in
                attempts += 1
                return false
            })
            await controller.reloadLibrary()

            await controller.install(id: entry.id)

            #expect(attempts == 1)
            #expect(controller.failure != nil)
            #expect(controller.installationRequestedName == nil)
            #expect(!controller.isWorking)
            #expect(FileManager.default.fileExists(atPath: fixture.bundleURL(for: entry.id).path))
        }
    }

    @Test
    func disappearedBundleNeverReachesInstaller() async throws {
        try await withFixture { fixture in
            let library = ScreenSaverLibrary(rootURL: fixture.libraryRoot)
            let entry = try await create(fixture, in: library, name: "Missing")
            var opened = false
            let controller = ScreenSaverController(templateURL: nil, library: library, installerSigner: { _ in }, openInstaller: { _ in
                opened = true
                return true
            })
            await controller.reloadLibrary()
            try FileManager.default.removeItem(at: fixture.bundleURL(for: entry.id))

            await controller.install(id: entry.id)

            #expect(!opened)
            #expect(controller.failure != nil)
            #expect(controller.installationRequestedName == nil)
            #expect(!controller.isWorking)
        }
    }

    @Test
    func damagedRecordProducesWarningWhileHealthyRecordRemainsUsable() async throws {
        try await withFixture { fixture in
            let library = ScreenSaverLibrary(rootURL: fixture.libraryRoot)
            let healthy = try await create(fixture, in: library, name: "Healthy")
            let damaged = try await create(fixture, in: library, name: "Damaged")
            let metadata = fixture.libraryRoot.appendingPathComponent(damaged.id.uuidString).appendingPathComponent("metadata.json")
            try Data("broken JSON".utf8).write(to: metadata)
            let controller = ScreenSaverController(templateURL: nil, library: library, installerSigner: { _ in }, openInstaller: { _ in false })

            await controller.reloadLibrary()

            #expect(controller.entries.map(\.id) == [healthy.id])
            #expect(controller.thumbnails[healthy.id] != nil && controller.thumbnails[damaged.id] == nil)
            #expect(!controller.libraryWarnings.isEmpty)
            #expect(controller.failure == nil)
            controller.selectEntry(healthy.id)
            #expect(controller.selectedEntryID == healthy.id)
            #expect(controller.entries.first?.name == "Healthy")
        }
    }

    private func create(_ fixture: ControllerLibraryFixture, in library: ScreenSaverLibrary,
                        name: String, options: ScreenSaverExportOptions = .init()) async throws -> ScreenSaverLibraryEntry {
        try await Task.detached {
            try library.create(videoURL: fixture.video, posterJPEG: fixture.poster, templateURL: fixture.template,
                               name: name, options: options, signer: { _ in })
        }.value
    }

    private func withFixture(_ body: (ControllerLibraryFixture) async throws -> Void) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ScreenSaverControllerTests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let template = root.appendingPathComponent("Template.saver", isDirectory: true)
        try manager.createDirectory(at: template.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try manager.createDirectory(at: template.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: false)
        try Data("Test fixture, never loaded or executed.".utf8)
            .write(to: template.appendingPathComponent("Contents/MacOS/MyWallpaperScreenSaver"))
        let info: [String: Any] = ["MyWallpaperRuntimeVersion": 2, "CFBundlePackageType": "BNDL", "CFBundleIdentifier": "app.mywallpaper.screensaver",
                    "CFBundleExecutable": "MyWallpaperScreenSaver", "NSPrincipalClass": "MyWallpaperScreenSaverView"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: template.appendingPathComponent("Contents/Info.plist"))
        let video = root.appendingPathComponent("original.mp4")
        try Data("Media is deliberately not decoded by controller library tests.".utf8).write(to: video)
        try await body(ControllerLibraryFixture(root: root, libraryRoot: root.appendingPathComponent("Library", isDirectory: true),
                                               template: template, video: video, poster: makeJPEG()))
    }

    private func makeJPEG() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private struct ControllerLibraryFixture: Sendable {
    let root: URL
    let libraryRoot: URL
    let template: URL
    let video: URL
    let poster: Data

    func bundleURL(for id: UUID) -> URL {
        libraryRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("MyWallpaper.saver", isDirectory: true)
    }
}
