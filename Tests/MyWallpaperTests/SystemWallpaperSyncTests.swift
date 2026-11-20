import AppKit
import ImageIO
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct SystemWallpaperSyncTests {
    @Test
    func initializationDoesNotCreateStorageOrChangeTheDesktop() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        _ = SystemWallpaperSync(storeURL: fixture.store, desktop: fixture.desktop)

        #expect(!FileManager.default.fileExists(atPath: fixture.store.path))
        #expect(fixture.desktop.attempts.isEmpty)
        #expect(fixture.desktop.matchesCount == 0)
    }

    @Test
    func aCompleteDecodableJPEGExistsBeforeAnyDesktopWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let image = try poster(red: 0.2, green: 0.6, blue: 0.8)
        fixture.desktop.beforeApply = { call in
            let attributes = try FileManager.default.attributesOfItem(atPath: call.url.path)
            #expect(attributes[.type] as? FileAttributeType == .typeRegular)
            #expect(call.url.standardizedFileURL.pathComponents.starts(with: fixture.store.standardizedFileURL.pathComponents))
            let source = try #require(CGImageSourceCreateWithURL(call.url as CFURL, nil))
            #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
            let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(decoded.width == image.width && decoded.height == image.height)
        }

        try await fixture.sync.synchronize(image: image, name: "Blue Moon", target: .main, scaling: .fill)

        #expect(fixture.desktop.applied.count == 1)
        let url = try #require(fixture.desktop.applied.first?.url)
        #expect(FileManager.default.fileExists(atPath: url.path), "The system must retain a durable image after synchronization returns.")
    }

    @Test
    func identicalImageAndNameReuseTheDurableFileAcrossServiceInstances() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try poster(red: 0.1, green: 0.3, blue: 0.6)
        try await fixture.sync.synchronize(image: original, name: "Night", target: .all, scaling: .fill)
        let originalURL = try #require(fixture.desktop.applied.first?.url)
        let originalBytes = try Data(contentsOf: originalURL)
        let firstWriteCount = fixture.desktop.applied.count

        try await fixture.sync.synchronize(image: original, name: "Night", target: .all, scaling: .fill)
        let reloaded = SystemWallpaperSync(storeURL: fixture.store, desktop: fixture.desktop)
        try await reloaded.synchronize(image: original, name: "Night", target: .all, scaling: .fill)

        #expect(fixture.desktop.applied.count == firstWriteCount, "An unchanged desktop must not be rewritten on every synchronization or launch.")
        #expect(try Data(contentsOf: originalURL) == originalBytes)

        let changed = try poster(red: 0.8, green: 0.2, blue: 0.1)
        try await reloaded.synchronize(image: changed, name: "Night", target: .all, scaling: .fill)
        let changedURL = try #require(fixture.desktop.applied.last?.url)
        #expect(changedURL != originalURL, "A new frame needs a new URL so macOS cannot keep a cached old image.")
        #expect(try Data(contentsOf: originalURL) == originalBytes, "The old desktop asset is retained rather than overwritten or deleted.")
        #expect(try Data(contentsOf: changedURL) != originalBytes)
    }

    @Test
    func mainTargetsTheFirstScreenAndAllAddsTheRemainingScreens() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let image = try poster()

        try await fixture.sync.synchronize(image: image, name: "Screens", target: .main, scaling: .fill)
        #expect(fixture.desktop.applied.map(\.screen.id) == [42])
        try await fixture.sync.synchronize(image: image, name: "Screens", target: .all, scaling: .fill)

        #expect(fixture.desktop.applied.map(\.screen.id) == [42, 7, 99])
        #expect(Set(fixture.desktop.applied.map(\.url)).count == 1)
    }

    @Test
    func changingFitAndFillReappliesTheSameFrameWithMatchingOptions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let image = try poster()
        try await fixture.sync.synchronize(image: image, name: "Scaling", target: .main, scaling: .fill)
        try await fixture.sync.synchronize(image: image, name: "Scaling", target: .main, scaling: .fit)

        let calls = fixture.desktop.applied
        try #require(calls.count == 2)
        #expect(calls[0].url == calls[1].url)
        #expect(calls[0].options.allowClipping)
        #expect(!calls[1].options.allowClipping)
        for call in calls {
            #expect(call.options.imageScaling == .scaleProportionallyUpOrDown)
            #expect(call.options.fillColor == NSColor.black)
        }
    }

    @Test
    func encodingFailureNeverReachesTheDesktopAdapter() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = SystemWallpaperSync(storeURL: fixture.store, desktop: fixture.desktop,
                                          encoder: { _ in throw CocoaError(.fileWriteUnknown) })

        await #expect(throws: (any Error).self) {
            try await service.synchronize(image: poster(), name: "Failed", target: .all, scaling: .fill)
        }

        #expect(fixture.desktop.attempts.isEmpty)
    }

    @Test(arguments: [Data(), Data("This is not a JPEG".utf8)])
    func invalidEncodedDataIsRejectedBeforeDesktopOrStorageWrites(_ data: Data) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = SystemWallpaperSync(storeURL: fixture.store, desktop: fixture.desktop, encoder: { _ in data })

        await #expect(throws: SystemWallpaperSyncError.self) {
            try await service.synchronize(image: poster(), name: "Invalid", target: .all, scaling: .fill)
        }

        #expect(fixture.desktop.attempts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.path))
    }

    @Test
    func cancellationBeforeWorkOrImmediatelyBeforeApplyNeverChangesTheDesktop() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let image = try poster()
        let beforeWork = Task { @MainActor in
            try await fixture.sync.synchronize(image: image, name: "Cancelled", target: .all, scaling: .fill)
        }
        beforeWork.cancel()
        await #expect(throws: CancellationError.self) { try await beforeWork.value }
        #expect(fixture.desktop.attempts.isEmpty)

        fixture.desktop.beforeMatch = { withUnsafeCurrentTask { $0?.cancel() } }
        let beforeApply = Task { @MainActor in
            try await fixture.sync.synchronize(image: image, name: "Cancelled", target: .all, scaling: .fill)
        }
        await #expect(throws: CancellationError.self) { try await beforeApply.value }
        #expect(fixture.desktop.matchesCount == 1)
        #expect(fixture.desktop.attempts.isEmpty)
    }

    @Test
    func cancellationAfterOneDisplayPreventsFurtherWritesAndKeepsItsDurableFrame() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let image = try poster()
        fixture.desktop.beforeApply = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { @MainActor in
            try await fixture.sync.synchronize(image: image, name: "Interrupted", target: .all, scaling: .fill)
        }

        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(fixture.desktop.attempts.map(\.screen.id) == [42])
        #expect(fixture.desktop.applied.map(\.screen.id) == [42])
        let url = try #require(fixture.desktop.applied.first?.url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func sourceNameRemainsAHumanLabelAndCannotEscapeTheStore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try await fixture.sync.synchronize(image: poster(), name: "../Ночное/небо: кадр.mp4", target: .main, scaling: .fill)

        let url = try #require(fixture.desktop.applied.first?.url)
        #expect(url.standardizedFileURL.pathComponents.starts(with: fixture.store.standardizedFileURL.pathComponents))
        #expect(url.pathExtension == "jpg")
        #expect(url.lastPathComponent.contains("кадр"))
        #expect(!url.lastPathComponent.contains(":"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == [fixture.store.lastPathComponent])
    }

    @Test
    func displayFailureIsReportedEvenWhenAnotherDisplaySucceeded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.desktop.failingIDs = [7]

        do {
            try await fixture.sync.synchronize(image: poster(), name: "Partial", target: .all, scaling: .fit)
            Issue.record("A partial desktop failure was reported as success.")
        } catch let error as SystemWallpaperSyncError {
            #expect(error.failedScreenNames == ["External"])
            #expect(!error.ruKey.isEmpty)
        }

        #expect(fixture.desktop.applied.map(\.screen.id) == [42, 99], "One failed screen must not prevent the remaining screens from updating.")
        #expect(fixture.desktop.attempts.contains { $0.screen.id == 7 })
        #expect(!fixture.desktop.applied.contains { $0.screen.id == 7 })
    }

    @Test
    func unsafeStoreCannotReplaceAFileOrFollowADirectorySymlink() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let marker = Data("Keep this unrelated file".utf8)
        let fileRoot = fixture.root.appendingPathComponent("Existing file")
        try marker.write(to: fileRoot)
        let outside = fixture.root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try marker.write(to: sentinel)
        let link = fixture.root.appendingPathComponent("Linked directory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        for store in [fileRoot, link, link.appendingPathComponent("Nested") ] {
            let service = SystemWallpaperSync(storeURL: store, desktop: fixture.desktop)
            await #expect(throws: (any Error).self) {
                try await service.synchronize(image: poster(), name: "Unsafe", target: .main, scaling: .fill)
            }
        }

        #expect(fixture.desktop.attempts.isEmpty)
        #expect(try Data(contentsOf: fileRoot) == marker)
        #expect(try Data(contentsOf: sentinel) == marker)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["sentinel.txt"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
    }

    private func poster(red: CGFloat = 0.25, green: CGFloat = 0.5, blue: CGFloat = 0.75) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 48,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        return try #require(context.makeImage())
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let store: URL
        let desktop: FakeDesktop
        let sync: SystemWallpaperSync

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("MyWallpaperSystemSyncTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            store = root.appendingPathComponent("Posters", isDirectory: true)
            desktop = FakeDesktop()
            sync = SystemWallpaperSync(storeURL: store, desktop: desktop)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor
    private final class FakeDesktop: SystemWallpaperDesktopAdapting {
        struct Call {
            let url: URL
            let options: SystemWallpaperOptions
            let screen: SystemWallpaperScreen
        }

        let screens = [SystemWallpaperScreen(id: 42, name: "Primary"),
                       SystemWallpaperScreen(id: 7, name: "External"),
                       SystemWallpaperScreen(id: 99, name: "Third")]
        var attempts: [Call] = []
        var applied: [Call] = []
        var current: [UInt32: Call] = [:]
        var matchesCount = 0
        var failingIDs: Set<UInt32> = []
        var beforeMatch: (() -> Void)?
        var beforeApply: ((Call) throws -> Void)?

        func matches(imageURL: URL, options: SystemWallpaperOptions, screen: SystemWallpaperScreen) -> Bool {
            matchesCount += 1
            beforeMatch?()
            return current[screen.id].map { $0.url == imageURL && $0.options == options } ?? false
        }

        func apply(imageURL: URL, options: SystemWallpaperOptions, screen: SystemWallpaperScreen) throws {
            let call = Call(url: imageURL, options: options, screen: screen)
            attempts.append(call)
            try beforeApply?(call)
            if failingIDs.contains(screen.id) { throw CocoaError(.fileWriteNoPermission) }
            applied.append(call)
            current[screen.id] = call
        }
    }
}
