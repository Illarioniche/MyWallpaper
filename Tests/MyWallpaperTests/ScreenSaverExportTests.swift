import Foundation
import ImageIO
import Testing
@testable import MyWallpaper

@Suite
struct ScreenSaverExportTests {
    @Test(arguments: ["mp4", "MOV"])
    func createsIndependentBundleAndPreservesSources(_ fileExtension: String) throws {
        try withFixture(videoExtension: fileExtension) { fixture in
            let source = try Data(contentsOf: fixture.video)
            let originalTemplate = try snapshot(fixture.template)
            let poster = try makeJPEG()
            let options = ScreenSaverExportOptions(scaling: .fit, animateOnBattery: true,
                                                  animateOnExternalPower: false, pauseInLowPowerMode: false)
            let output = try ScreenSaverExporter.export(
                videoURL: fixture.video, posterJPEG: poster, templateURL: fixture.template,
                destinationURL: fixture.destination, options: options,
                signer: { stage in
                    #expect(stage.pathExtension == "saver")
                    #expect(stage.deletingLastPathComponent().deletingLastPathComponent() == fixture.destination.deletingLastPathComponent())
                    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path), "No incomplete final bundle may be visible.")
                    #expect(FileManager.default.fileExists(atPath: stage.appendingPathComponent("Contents/Resources/configuration.json").path))
                })

            #expect(output == fixture.destination)
            let resources = output.appendingPathComponent("Contents/Resources")
            #expect(try Data(contentsOf: resources.appendingPathComponent("video.\(fileExtension.lowercased())")) == source)
            #expect(try Data(contentsOf: resources.appendingPathComponent("poster.jpg")) == poster)
            let config = try configuration(at: output)
            #expect(config["version"] as? Int == 1)
            #expect(config["videoFileName"] as? String == "video.\(fileExtension.lowercased())")
            #expect(config["scaling"] as? String == "fit")
            #expect(config["animateOnBattery"] as? Bool == true)
            #expect(config["animateOnExternalPower"] as? Bool == false)
            #expect(config["pauseInLowPowerMode"] as? Bool == false)
            #expect(!String(decoding: try Data(contentsOf: resources.appendingPathComponent("configuration.json")), as: UTF8.self).contains(fixture.root.path))
            #expect(try Data(contentsOf: fixture.video) == source)
            #expect(try snapshot(fixture.template) == originalTemplate)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path) == ["Aurora.saver"])
        }
    }

    @Test(arguments: [1, 6])
    func thumbnailsPreserveAspectAndOrientationBeforeSigning(_ orientation: Int) throws {
        try withFixture { fixture in
            let poster = try makeJPEG(width: 1_920, height: 1_080, orientation: orientation)
            let originalTemplate = try snapshot(fixture.template)
            try ScreenSaverExporter.export(
                videoURL: fixture.video, posterJPEG: poster, templateURL: fixture.template,
                destinationURL: fixture.destination,
                signer: { stage in
                    let resources = stage.appendingPathComponent("Contents/Resources")
                    #expect(try Data(contentsOf: resources.appendingPathComponent("poster.jpg")) == poster)
                    for (name, longestSide) in [("thumbnail.png", 640), ("thumbnail@2x.png", 1_280)] {
                        let source = try #require(CGImageSourceCreateWithURL(resources.appendingPathComponent(name) as CFURL, nil))
                        #expect(CGImageSourceGetType(source) as String? == "public.png")
                        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
                        let shorterSide = longestSide * 9 / 16
                        #expect(image.width == (orientation == 6 ? shorterSide : longestSide))
                        #expect(image.height == (orientation == 6 ? longestSide : shorterSide))
                    }
                })

            let resources = fixture.destination.appendingPathComponent("Contents/Resources")
            #expect(try Data(contentsOf: resources.appendingPathComponent("poster.jpg")) == poster)
            #expect(try snapshot(fixture.template) == originalTemplate)
        }
    }

    @Test
    func defaultExportKeepsBatteryStaticAndExternalPowerAnimated() throws {
        try withFixture { fixture in
            try export(fixture)
            let config = try configuration(at: fixture.destination)
            #expect(config["scaling"] as? String == "fill")
            #expect(config["animateOnBattery"] as? Bool == false)
            #expect(config["animateOnExternalPower"] as? Bool == true)
            #expect(config["pauseInLowPowerMode"] as? Bool == true)
        }
    }

    @Test
    func existingDestinationIsNeverOverwritten() throws {
        try withFixture { fixture in
            let original = Data("a user-owned file".utf8)
            try original.write(to: fixture.destination)
            #expect(throws: ScreenSaverExportError.self) {
                try export(fixture, signer: { _ in Issue.record("An existing destination must fail before signing.") })
            }
            #expect(try Data(contentsOf: fixture.destination) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path) == ["Aurora.saver"])
        }
    }

    @Test
    func publicationRaceDoesNotReplaceACompetingFileAndCleansStaging() throws {
        try withFixture { fixture in
            let competing = Data("created while signing".utf8)
            #expect(throws: ScreenSaverExportError.self) {
                try export(fixture, signer: { _ in try competing.write(to: fixture.destination) })
            }
            let preserved = try Data(contentsOf: fixture.destination)
            #expect(preserved == competing)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path) == ["Aurora.saver"])
        }
    }

    @Test
    func failedSignerLeavesNoPartialBundleAndKeepsEverySource() throws {
        try withFixture { fixture in
            let before = try snapshot(fixture.root)
            #expect(throws: ScreenSaverExportError.self) {
                try export(fixture, signer: { _ in throw CocoaError(.fileWriteNoPermission) })
            }
            #expect(try snapshot(fixture.root) == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path).isEmpty)
        }
    }

    @Test
    func cancellationBetweenStagesDoesNotPublishAndCleansStaging() throws {
        try withFixture { fixture in
            #expect(throws: CancellationError.self) {
                try export(fixture, signer: { _ in throw CancellationError() })
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
            let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path)
            #expect(remaining.isEmpty)
        }
    }

    @Test
    func invalidVideoExtensionAndInvalidPosterFailBeforeSigning() throws {
        try withFixture(videoExtension: "txt") { fixture in
            #expect(throws: ScreenSaverExportError.self) {
                try export(fixture, signer: { _ in Issue.record("Unsupported video extension reached signing.") })
            }
        }
        try withFixture { fixture in
            #expect(throws: ScreenSaverExportError.self) {
                try ScreenSaverExporter.export(videoURL: fixture.video, posterJPEG: Data("not JPEG".utf8),
                                               templateURL: fixture.template, destinationURL: fixture.destination,
                                               signer: { _ in Issue.record("Invalid poster reached signing.") })
            }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path)
            #expect(remaining.isEmpty)
        }
    }

    @Test
    func templateMetadataAndExecutableMustDescribeTheExpectedSaver() throws {
        for badMetadata in [["CFBundleExecutable": "../outside"], ["NSPrincipalClass": "OtherView"],
                            ["CFBundlePackageType": "APPL"], ["CFBundleIdentifier": "evil.example"]] {
            try withFixture { fixture in
                try writeInfo(fixture.template, overrides: badMetadata)
                #expect(throws: ScreenSaverExportError.self) {
                    try export(fixture, signer: { _ in Issue.record("An invalid template reached signing.") })
                }
                #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path).isEmpty)
            }
        }
        try withFixture { fixture in
            try FileManager.default.removeItem(at: fixture.template.appendingPathComponent("Contents/MacOS/MyWallpaperScreenSaver"))
            #expect(throws: ScreenSaverExportError.self) { try export(fixture) }
        }
    }

    @Test
    func symlinkedMediaAndTemplateResourcesNeverWriteOutsideStaging() throws {
        try withFixture { fixture in
            let linkedVideo = fixture.root.appendingPathComponent("linked.mp4")
            try FileManager.default.createSymbolicLink(at: linkedVideo, withDestinationURL: fixture.video)
            #expect(throws: ScreenSaverExportError.self) {
                try ScreenSaverExporter.export(videoURL: linkedVideo, posterJPEG: makeJPEG(),
                                               templateURL: fixture.template, destinationURL: fixture.destination,
                                               signer: { _ in Issue.record("A symbolic link reached signing.") })
            }
            let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let sentinel = outside.appendingPathComponent("poster.jpg")
            let original = Data("must remain untouched".utf8)
            try original.write(to: sentinel)
            let resources = fixture.template.appendingPathComponent("Contents/Resources")
            try FileManager.default.removeItem(at: resources)
            try FileManager.default.createSymbolicLink(at: resources, withDestinationURL: outside)
            #expect(throws: ScreenSaverExportError.self) { try export(fixture) }
            #expect(try Data(contentsOf: sentinel) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["poster.jpg"])
            let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path)
            #expect(remaining.isEmpty)
        }
    }

    @Test
    func rejectsDestinationSymlinksWrongExtensionAndPathsInsideTemplate() throws {
        try withFixture { fixture in
            let missing = fixture.root.appendingPathComponent("missing-target.saver")
            try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: missing)
            #expect(throws: ScreenSaverExportError.self) { try export(fixture) }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path) == missing.path)
            #expect(!FileManager.default.fileExists(atPath: missing.path))

            let before = try snapshot(fixture.template)
            for destination in [fixture.root.appendingPathComponent("Wrong.app"),
                                fixture.template.appendingPathComponent("Nested.saver"),
                                fixture.template.appendingPathComponent("Contents/Nested.saver")] {
                #expect(throws: ScreenSaverExportError.self) {
                    try ScreenSaverExporter.export(videoURL: fixture.video, posterJPEG: makeJPEG(),
                                                   templateURL: fixture.template, destinationURL: destination, signer: { _ in })
                }
            }
            #expect(try snapshot(fixture.template) == before)
        }
    }

    @Test
    func rejectsRemoteMediaAndExplicitParentTraversal() throws {
        try withFixture { fixture in
            for video in [URL(string: "https://example.com/video.mp4")!,
                          URL(fileURLWithPath: fixture.root.path + "/Exports/../original.mp4")] {
                #expect(throws: ScreenSaverExportError.self) {
                    try ScreenSaverExporter.export(videoURL: video, posterJPEG: makeJPEG(),
                                                   templateURL: fixture.template, destinationURL: fixture.destination, signer: { _ in })
                }
            }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path)
            #expect(remaining.isEmpty)
        }
    }

    private func export(_ fixture: ExportFixture, signer: ScreenSaverExporter.Signer = { _ in }) throws {
        try ScreenSaverExporter.export(videoURL: fixture.video, posterJPEG: makeJPEG(),
                                       templateURL: fixture.template, destinationURL: fixture.destination, signer: signer)
    }

    private func withFixture(videoExtension: String = "mp4", _ body: (ExportFixture) throws -> Void) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ScreenSaverExportTests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let template = root.appendingPathComponent("Template.saver", isDirectory: true)
        try manager.createDirectory(at: template.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try manager.createDirectory(at: template.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: false)
        try Data("fake executable; only the injected signer sees it".utf8)
            .write(to: template.appendingPathComponent("Contents/MacOS/MyWallpaperScreenSaver"))
        try Data("template resource".utf8).write(to: template.appendingPathComponent("Contents/Resources/Keep.txt"))
        try writeInfo(template)
        let video = root.appendingPathComponent("original.\(videoExtension)")
        try Data("fake video; decoding is the caller's responsibility".utf8).write(to: video)
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try manager.createDirectory(at: exports, withIntermediateDirectories: false)
        try body(ExportFixture(root: root, video: video, template: template,
                               destination: exports.appendingPathComponent("Aurora.saver", isDirectory: true)))
    }

    private func writeInfo(_ template: URL, overrides: [String: String] = [:]) throws {
        var metadata = ["CFBundlePackageType": "BNDL", "CFBundleIdentifier": "app.mywallpaper.screensaver",
                        "CFBundleExecutable": "MyWallpaperScreenSaver", "NSPrincipalClass": "MyWallpaperScreenSaverView"]
        metadata.merge(overrides) { _, replacement in replacement }
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: template.appendingPathComponent("Contents/Info.plist"))
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in files where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
        }
        return result
    }

    private func configuration(at bundle: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/configuration.json"))) as? [String: Any])
    }

    private func makeJPEG(width: Int = 2, height: Int = 2, orientation: Int = 1) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private struct ExportFixture: Sendable {
    let root: URL
    let video: URL
    let template: URL
    let destination: URL
}
