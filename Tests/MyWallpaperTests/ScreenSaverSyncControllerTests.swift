import AppKit
import Combine
import Testing
@testable import MyWallpaper

@Suite
@MainActor
struct ScreenSaverSyncControllerTests {
    @Test
    func installedStateIsRediscoveredAfterRelaunchAndClearedAfterExternalDeletion() async throws {
        let fixture = try ScreenSaverSyncInstallationFixture()
        defer { fixture.cleanUp() }
        let installed = try fixture.makeBundle(in: fixture.systemDirectory, name: "Renamed.saver")
        let scanner = fixture.scanner
        let controller = ScreenSaverSyncController(store: .init(rootURL: fixture.feed), templateURL: nil,
            installationLookup: { scanner.installedBundleURL(syncRootURL: $0) })
        await controller.reload()
        #expect(controller.isInstalled && controller.installedBundleURL?.resolvingSymlinksInPath().path == installed.resolvingSymlinksInPath().path)
        #expect(!controller.installationRequested && !controller.isWorking)
        try FileManager.default.removeItem(at: installed)
        await controller.refreshInstallation()
        #expect(!controller.isInstalled && controller.installedBundleURL == nil)
        #expect(controller.failure == nil)
    }

    @Test
    func installerHandoffDoesNotConfirmInstallationAndDeletedCopiesCanBeReinstalled() async throws {
        let fixture = try WallpaperLibraryFixture()
        let installation = try ScreenSaverSyncInstallationFixture()
        defer { fixture.cleanUp(); installation.cleanUp() }
        let scanner = installation.scanner
        let store = ScreenSaverSyncStore(rootURL: installation.feed)
        let template = try makeTemplate(fixture)
        var opened: [URL] = []
        let controller = ScreenSaverSyncController(store: store, templateURL: template, signer: { _ in },
            prepareVideo: { _ in fixture.poster },
            installationLookup: { scanner.installedBundleURL(syncRootURL: $0) },
            openInstaller: { opened.append($0); return true })
        controller.synchronize(videoURL: fixture.video, name: "Night", options: .init())
        await controller.waitForSynchronization()
        await controller.install()
        #expect(opened.count == 1 && controller.installationRequested && !controller.isInstalled)
        #expect(controller.failure == nil && !controller.isWorking)
        // Simulate the system's confirmation by copying only into a temporary
        // install directory. Merely opening or cancelling the dialog leaves setup visible.
        try FileManager.default.createDirectory(at: installation.userDirectory, withIntermediateDirectories: true)
        let installer = try #require(opened.first)
        let installed = installation.userDirectory.appendingPathComponent(installer.lastPathComponent)
        try FileManager.default.copyItem(at: installer, to: installed)
        try await eventually { controller.isInstalled }
        #expect(controller.installedBundleURL?.resolvingSymlinksInPath().path == installed.resolvingSymlinksInPath().path && !controller.installationRequested)
        try FileManager.default.removeItem(at: installed)
        await controller.refreshInstallation()
        #expect(!controller.isInstalled)
        await controller.install()
        #expect(opened.count == 2 && !controller.isInstalled && controller.installationRequested)
        try FileManager.default.copyItem(at: installer, to: installed)
        await controller.refreshInstallation()
        #expect(controller.isInstalled && !controller.installationRequested)
        let installedInfo = try Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        await controller.install()
        #expect(opened.count == 3 && controller.isInstalled && !controller.isWorking)
        #expect(try Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist")) == installedInfo,
                "Reinstallation must hand off to macOS without modifying its installed copy.")
    }

    @Test
    func failedInstallerHandoffDoesNotConfirmOrAwaitInstallation() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let controller = ScreenSaverSyncController(store: makeStore(fixture), templateURL: try makeTemplate(fixture),
            signer: { _ in }, prepareVideo: { _ in fixture.poster }, installationLookup: { _ in nil },
            openInstaller: { _ in false })
        controller.synchronize(videoURL: fixture.video, name: "Night", options: .init())
        await controller.waitForSynchronization()
        await controller.install()
        #expect(controller.failure != nil && !controller.isInstalled && !controller.installationRequested)
        #expect(!controller.isWorking && !controller.isInstalling)
    }

    @Test
    func initializationAndReloadDoNotCreateAFeedOrOpenTheInstaller() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        let controller = makeController(fixture, store: store)
        #expect(controller.snapshot == nil && !controller.isWorking && !controller.isSynchronizing)
        await controller.reload()
        #expect(controller.snapshot == nil && controller.failure == nil && !controller.isWorking)
        #expect(!FileManager.default.fileExists(atPath: store.rootURL.path))
    }

    @Test
    func synchronizationPublishesCopiesAndSettingsChangesReuseTheRevision() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        let controller = makeController(fixture, store: store)
        controller.synchronize(videoURL: fixture.video, name: "First", options: .init())
        await controller.waitForSynchronization()
        let first = try #require(controller.snapshot)
        #expect(try store.snapshot() == first)
        #expect(!controller.isSynchronizing && !controller.isWorking && controller.failure == nil)
        let options = ScreenSaverExportOptions(scaling: .fit, animateOnBattery: true,
                                              animateOnExternalPower: false, pauseInLowPowerMode: false)
        controller.synchronize(videoURL: fixture.video, name: "Renamed", options: options)
        await controller.waitForSynchronization()
        let updated = try #require(controller.snapshot)
        #expect(updated.revision == first.revision && updated.name == "Renamed" && updated.options == options)
        #expect(try store.snapshot() == updated)
        #expect(try Data(contentsOf: fixture.video) == fixture.videoBytes)
    }

    @Test
    func aNewRequestCancelsAnOldPreparationAndOnlyTheLatestResultWins() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        let gate = SyncPreparationGate(poster: fixture.poster)
        let controller = ScreenSaverSyncController(store: store, templateURL: nil,
            prepareVideo: { _ in try await gate.prepare() }, openInstaller: { _ in
                Issue.record("Synchronization must not open an installer."); return false
            })
        controller.synchronize(videoURL: fixture.video, name: "Old", options: .init())
        try await gate.waitUntilStarted()
        controller.synchronize(videoURL: fixture.video, name: "Latest", options: .init(scaling: .fit))
        await controller.waitForSynchronization()
        try await eventually { !controller.isWorking }
        #expect(controller.snapshot?.name == "Latest" && controller.snapshot?.scaling == .fit)
        #expect(try store.snapshot() == controller.snapshot)
        #expect(controller.failure == nil && !controller.isSynchronizing)
        #expect(await gate.count == 2)
    }

    @Test
    func failedPreparationReportsAnErrorAndPreservesTheLastPublishedSnapshot() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        let controller = ScreenSaverSyncController(store: store, templateURL: nil, prepareVideo: { url in
            if url.lastPathComponent == "Bad.mov" { throw CocoaError(.fileReadCorruptFile) }
            return fixture.poster
        }, openInstaller: { _ in Issue.record("Tests must not open an installer."); return false })
        controller.synchronize(videoURL: fixture.video, name: "Good", options: .init())
        await controller.waitForSynchronization()
        let good = try #require(controller.snapshot)
        controller.synchronize(videoURL: fixture.root.appendingPathComponent("Bad.mov"), name: "Bad", options: .init())
        await controller.waitForSynchronization()
        #expect(controller.failure != nil && !controller.isSynchronizing && !controller.isWorking)
        #expect(controller.snapshot == good)
        #expect(try store.snapshot() == good)
        controller.dismissFailure()
        #expect(controller.failure == nil)
    }

    @Test
    func cancellationFreezesTheLastSnapshotAndEventuallyFinishesItsWork() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        let store = makeStore(fixture)
        let frozen = try store.publish(videoURL: fixture.video, posterJPEG: fixture.poster,
                                       options: .init(), name: "Frozen")
        let gate = SyncPreparationGate(poster: fixture.poster)
        let controller = ScreenSaverSyncController(store: store, templateURL: nil,
                                                   prepareVideo: { _ in try await gate.prepare() })
        await controller.reload()
        controller.synchronize(videoURL: fixture.video, name: "Cancelled", options: .init(scaling: .fit))
        try await gate.waitUntilStarted()
        controller.cancelSynchronization()
        #expect(!controller.isSynchronizing)
        try await eventually { !controller.isWorking }
        #expect(controller.snapshot == frozen)
        #expect(try store.snapshot() == frozen)
        #expect(controller.failure == nil)
    }

    @Test
    func modelDefaultsLeaveTheFeedUntouchedWhenSettingsChange() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        try await withModel(fixture) { model, preferences, controller, store in
            #expect(!model.syncScreenSaver && !preferences.syncScreenSaver)
            model.restore()
            model.scaling = .fit
            model.animateOnBattery = true
            model.animateOnExternalPower = false
            model.pauseInLowPowerMode = false
            await controller.waitForSynchronization()
            #expect(controller.snapshot == nil && !controller.isWorking)
            let stored = try store.snapshot()
            #expect(stored == nil)
            #expect(!model.hasWallpaper && !model.isPlaying)
        }
    }

    @Test
    func enablingSyncPublishesAStoppedWallpaperAndFollowsOnlySharedSettings() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        try await withModel(fixture) { model, preferences, controller, store in
            model.restore()
            #expect(model.selectedURL != nil && !model.hasWallpaper)
            model.syncScreenSaver = true
            await controller.waitForSynchronization()
            let first = try #require(controller.snapshot)
            #expect(preferences.syncScreenSaver && !preferences.wallpaperEnabled)
            model.scaling = .fit
            model.animateOnExternalPower = false
            model.animateOnBattery = true
            model.pauseInLowPowerMode = false
            await controller.waitForSynchronization()
            try await eventually { !controller.isWorking }
            let shared = try #require(controller.snapshot)
            #expect(shared.revision == first.revision)
            #expect(shared.options == .init(scaling: .fit, animateOnBattery: true,
                                           animateOnExternalPower: false, pauseInLowPowerMode: false))
            model.isMuted = false
            model.volume = 0.2
            model.target = .main
            model.pauseWhenCovered = false
            model.syncSystemWallpaper = true
            #expect(!controller.isSynchronizing && !controller.isWorking,
                    "Audio, display target and coverage are desktop-only settings.")
            #expect(controller.snapshot == shared)
            #expect(try store.snapshot() == shared)
            #expect(!model.hasWallpaper && !model.isPlaying)
        }
    }

    @Test
    func turningSyncOffPersistsTheChoiceAndFreezesTheLastPublishedSettings() async throws {
        let fixture = try WallpaperLibraryFixture()
        defer { fixture.cleanUp() }
        try await withModel(fixture, enabled: true) { model, preferences, controller, store in
            model.restore()
            await controller.waitForSynchronization()
            let current = try #require(controller.snapshot)
            model.syncScreenSaver = false
            model.scaling = .fit
            model.animateOnBattery = !model.animateOnBattery
            await controller.waitForSynchronization()
            try await eventually { !controller.isWorking }
            #expect(!preferences.syncScreenSaver && !model.syncScreenSaver)
            #expect(controller.snapshot == current)
            #expect(try store.snapshot() == current)
        }
    }

    private func makeStore(_ fixture: WallpaperLibraryFixture) -> ScreenSaverSyncStore {
        ScreenSaverSyncStore(rootURL: fixture.root.appendingPathComponent("Sync"))
    }

    private func makeTemplate(_ fixture: WallpaperLibraryFixture) throws -> URL {
        let template = fixture.root.appendingPathComponent("Template.saver", isDirectory: true)
        try FileManager.default.createDirectory(at: template.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let executable = template.appendingPathComponent("Contents/MacOS/MyWallpaperScreenSaver")
        try Data("Test template; never loaded or executed.".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info: [String: Any] = ["CFBundlePackageType": "BNDL", "CFBundleIdentifier": "app.mywallpaper.screensaver",
                                  "CFBundleExecutable": "MyWallpaperScreenSaver", "NSPrincipalClass": "MyWallpaperScreenSaverView",
                                  "MyWallpaperRuntimeVersion": 3]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: template.appendingPathComponent("Contents/Info.plist"))
        return template
    }

    private func makeController(_ fixture: WallpaperLibraryFixture, store: ScreenSaverSyncStore) -> ScreenSaverSyncController {
        ScreenSaverSyncController(store: store, templateURL: nil, prepareVideo: { _ in fixture.poster },
            openInstaller: { _ in Issue.record("Tests must not open an installer."); return false })
    }

    private func withModel(_ fixture: WallpaperLibraryFixture, enabled: Bool = false,
                           _ body: @MainActor (WallpaperModel, WallpaperPreferences, ScreenSaverSyncController,
                                               ScreenSaverSyncStore) async throws -> Void) async throws {
        let domain = "ScreenSaverSyncModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = WallpaperPreferences(defaults: defaults)
        preferences.restoreOnLaunch = false
        preferences.wallpaperEnabled = false
        preferences.syncScreenSaver = enabled
        preferences.videoBookmark = try fixture.video.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let store = makeStore(fixture)
        let controller = makeController(fixture, store: store)
        let model = WallpaperModel(preferences: preferences,
            loginItems: LoginItemController(service: SyncModelLogin(), notificationCenter: NotificationCenter()),
            powerMonitor: SyncModelPower(), updates: UpdateController(currentVersion: "0.7.0", defaults: defaults, transport: { _ in
                Issue.record("Sync tests must not request updates."); throw URLError(.cancelled)
            }), systemWallpaperSync: SyncModelDesktop(),
            wallpaperLibrary: WallpaperLibraryController(library: fixture.library), screenSaverSync: controller)
        defer { model.shutDown() }
        try await body(model, preferences, controller, store)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "Timed out waiting for synchronization to settle.")
    }
}

private actor SyncPreparationGate {
    let poster: Data
    private(set) var count = 0
    init(poster: Data) { self.poster = poster }
    func prepare() async throws -> Data {
        count += 1
        if count == 1 { try await Task.sleep(for: .seconds(30)) }
        return poster
    }
    func waitUntilStarted() async throws {
        let deadline = Date().addingTimeInterval(5)
        while count == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if count == 0 { throw URLError(.timedOut) }
    }
}

@MainActor private final class SyncModelLogin: LoginItemServicing {
    var status: LoginItemStatus { .disabled }
    func register() throws { Issue.record("Tests must not change login items.") }
    func unregister() throws { Issue.record("Tests must not change login items.") }
    func openSystemSettings() { Issue.record("Tests must not open System Settings.") }
}
@MainActor private final class SyncModelPower: PowerSourceMonitoring {
    var source: PowerSource { .external }
    var sourcePublisher: AnyPublisher<PowerSource, Never> { Just(.external).eraseToAnyPublisher() }
}
@MainActor private final class SyncModelDesktop: SystemWallpaperSyncing {
    func synchronize(image: CGImage, name: String, target: DisplayTarget, scaling: VideoScaling) async throws {
        Issue.record("Sync tests must not change the system wallpaper.")
    }
}
