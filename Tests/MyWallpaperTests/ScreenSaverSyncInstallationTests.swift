import Foundation
import Testing
@testable import MyWallpaper

@Suite
struct ScreenSaverSyncInstallationTests {
    @Test
    func checkingMissingDirectoriesDoesNotCreateThem() throws {
        let fixture = try ScreenSaverSyncInstallationFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.scanner.installedBundleURL(syncRootURL: fixture.feed) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    @Test
    func installationAndRemovalAreReflectedWithoutPersistedFlags() throws {
        let fixture = try ScreenSaverSyncInstallationFixture()
        defer { fixture.cleanUp() }
        // An exported installer is not an installed saver.
        let installer = try fixture.makeBundle(in: fixture.root.appendingPathComponent("Private installers"))
        #expect(fixture.scanner.installedBundleURL(syncRootURL: fixture.feed) == nil)
        try FileManager.default.createDirectory(at: fixture.userDirectory, withIntermediateDirectories: true)
        let installed = fixture.userDirectory.appendingPathComponent(installer.lastPathComponent)
        try FileManager.default.copyItem(at: installer, to: installed)
        #expect(fixture.scanner.installedBundleURL(syncRootURL: fixture.feed)?.resolvingSymlinksInPath().path == installed.resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: installed)
        #expect(fixture.scanner.installedBundleURL(syncRootURL: fixture.feed) == nil)
        #expect(FileManager.default.fileExists(atPath: installer.path))
    }

    @Test
    func renamedUserAndAllUsersCopiesAreRecognizedByIdentity() throws {
        let fixture = try ScreenSaverSyncInstallationFixture()
        defer { fixture.cleanUp() }
        let global = try fixture.makeBundle(in: fixture.systemDirectory, name: "My renamed night sky.saver")
        #expect(fixture.scanner.installedBundleURL(syncRootURL: fixture.feed)?.resolvingSymlinksInPath().path == global.resolvingSymlinksInPath().path)
        let local = try fixture.makeBundle(in: fixture.userDirectory, name: "Связанная заставка.saver")
        #expect(fixture.scanner.installedBundleURL(syncRootURL: fixture.feed)?.resolvingSymlinksInPath().path == local.resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: local)
        #expect(fixture.scanner.installedBundleURL(syncRootURL: fixture.feed)?.resolvingSymlinksInPath().path == global.resolvingSymlinksInPath().path)
    }

    @Test
    func anotherUsersFeedDoesNotHideInstallationForTheCurrentUser() throws {
        let fixture = try ScreenSaverSyncInstallationFixture()
        defer { fixture.cleanUp() }
        let global = try fixture.makeBundle(in: fixture.systemDirectory)
        try fixture.editConfiguration(global) { $0["syncRootPath"] = "/Users/someone-else/Library/Application Support/MyWallpaper/ScreenSaverSync" }
        #expect(fixture.scanner.installedBundleURL(syncRootURL: fixture.feed) == nil)
        // Comparing canonical paths also handles /var versus /private/var.
        try fixture.editConfiguration(global) { $0["syncRootPath"] = fixture.feed.resolvingSymlinksInPath().standardizedFileURL.path }
        #expect(fixture.scanner.installedBundleURL(syncRootURL: fixture.feed)?.resolvingSymlinksInPath().path == global.resolvingSymlinksInPath().path)
    }

    @Test(arguments: ["identifier", "principal", "oldRuntime", "executableName", "packageType"])
    func incompatibleBundleMetadataDoesNotConfirmInstallation(_ invalidPart: String) throws {
        let fixture = try ScreenSaverSyncInstallationFixture()
        defer { fixture.cleanUp() }
        let installed = try fixture.makeBundle(in: fixture.userDirectory)
        let infoURL = installed.appendingPathComponent("Contents/Info.plist")
        var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        switch invalidPart {
        case "identifier": info["CFBundleIdentifier"] = "app.mywallpaper.screensaver.some-other-saver"
        case "principal": info["NSPrincipalClass"] = "MyWallpaperScreenSaverView"
        case "oldRuntime": info["MyWallpaperRuntimeVersion"] = 2
        case "executableName": info["CFBundleExecutable"] = "../../Outside"
        default: info["CFBundlePackageType"] = "APPL"
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        #expect(fixture.scanner.installedBundleURL(syncRootURL: fixture.feed) == nil)
    }

    @Test(arguments: ["missingExecutable", "notExecutable", "missingPoster", "invalidJSON", "staticSaver", "wrongConfigVersion", "wrongSettingType"])
    func incompleteOrInvalidInstallationRemainsInstallable(_ invalidPart: String) throws {
        let fixture = try ScreenSaverSyncInstallationFixture()
        defer { fixture.cleanUp() }
        let installed = try fixture.makeBundle(in: fixture.userDirectory)
        let executable = installed.appendingPathComponent("Contents/MacOS/MyWallpaperScreenSaver")
        switch invalidPart {
        case "missingExecutable": try FileManager.default.removeItem(at: executable)
        case "notExecutable": try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        case "missingPoster": try FileManager.default.removeItem(at: installed.appendingPathComponent("Contents/Resources/poster.jpg"))
        case "invalidJSON": try Data("broken".utf8).write(to: installed.appendingPathComponent("Contents/Resources/configuration.json"))
        case "staticSaver": try fixture.editConfiguration(installed) { $0.removeValue(forKey: "syncRootPath") }
        case "wrongConfigVersion": try fixture.editConfiguration(installed) { $0["version"] = 2 }
        default: try fixture.editConfiguration(installed) { $0["animateOnBattery"] = "false" }
        }
        #expect(fixture.scanner.installedBundleURL(syncRootURL: fixture.feed) == nil)
    }

    @Test
    func symlinkToAnUninstalledBundleIsNotAnInstallation() throws {
        let fixture = try ScreenSaverSyncInstallationFixture()
        defer { fixture.cleanUp() }
        let installer = try fixture.makeBundle(in: fixture.root.appendingPathComponent("Private installers"))
        try FileManager.default.createDirectory(at: fixture.userDirectory, withIntermediateDirectories: true)
        let linked = fixture.userDirectory.appendingPathComponent("Linked.saver")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: installer)
        #expect(fixture.scanner.installedBundleURL(syncRootURL: fixture.feed) == nil)
    }
}

/// Metadata fixtures are inspected only; this test never loads or executes code.
struct ScreenSaverSyncInstallationFixture {
    let root: URL
    var feed: URL { root.appendingPathComponent("Sync") }
    var userDirectory: URL { root.appendingPathComponent("User Screen Savers") }
    var systemDirectory: URL { root.appendingPathComponent("System Screen Savers") }
    var scanner: ScreenSaverSyncInstallation { .init(directories: [userDirectory, systemDirectory]) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncInstallationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func makeBundle(in directory: URL, name: String = ScreenSaverSyncInstallation.identity.fileName) throws -> URL {
        let identity = ScreenSaverSyncInstallation.identity
        let bundle = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let executable = bundle.appendingPathComponent("Contents/MacOS/MyWallpaperScreenSaver")
        try Data("Not executed: installation metadata fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info: [String: Any] = ["CFBundlePackageType": "BNDL", "CFBundleIdentifier": identity.bundleIdentifier,
                                  "CFBundleExecutable": "MyWallpaperScreenSaver", "NSPrincipalClass": identity.principalClass,
                                  "MyWallpaperRuntimeVersion": 3]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try Data("Poster fixture".utf8).write(to: bundle.appendingPathComponent("Contents/Resources/poster.jpg"))
        let configuration: [String: Any] = ["version": 1, "videoFileName": "video.mp4", "scaling": "fill",
                                           "animateOnBattery": false, "animateOnExternalPower": true, "pauseInLowPowerMode": true,
                                           "syncRootPath": feed.resolvingSymlinksInPath().standardizedFileURL.path]
        try JSONSerialization.data(withJSONObject: configuration)
            .write(to: bundle.appendingPathComponent("Contents/Resources/configuration.json"))
        return bundle
    }

    func editConfiguration(_ bundle: URL, update: (inout [String: Any]) -> Void) throws {
        let url = bundle.appendingPathComponent("Contents/Resources/configuration.json")
        var configuration = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        update(&configuration)
        try JSONSerialization.data(withJSONObject: configuration).write(to: url)
    }
}
