import Foundation

/// Finds an actual installed copy, independently of whether the system's
/// installer was opened or this saver is currently selected in System Settings.
/// No bundle is loaded, executed, modified, or installed by this inspection.
struct ScreenSaverSyncInstallation: Sendable {
    static let identity = ScreenSaverInstallationIdentity(
        id: UUID(uuidString: "3F3E7BD1-66F2-4D84-B3B5-2DFE09B53454")!, name: "MyWallpaper — Sync")

    static var defaultDirectories: [URL] {
        let manager = FileManager.default
        let userLibrary = manager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return [userLibrary.appendingPathComponent("Screen Savers", isDirectory: true),
                URL(fileURLWithPath: "/Library/Screen Savers", isDirectory: true)]
    }

    let directories: [URL]

    init(directories: [URL] = Self.defaultDirectories) { self.directories = directories }

    /// Check the bundle identifier instead of its filename: a user can rename
    /// the installed saver. The feed path also distinguishes another user's copy.
    func installedBundleURL(syncRootURL: URL) -> URL? {
        let expectedRoot = syncRootURL.resolvingSymlinksInPath().standardizedFileURL.path
        for directory in directories {
            guard let bundles = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for bundle in bundles.sorted(by: { $0.path < $1.path }) where bundle.pathExtension.lowercased() == "saver" {
                if isInstalledBundle(bundle, expectedRoot: expectedRoot) { return bundle }
            }
        }
        return nil
    }

    private func isInstalledBundle(_ bundle: URL, expectedRoot: String) -> Bool {
        let manager = FileManager.default
        for path in ["", "Contents", "Contents/MacOS", "Contents/Resources"] {
            let directory = path.isEmpty ? bundle : bundle.appendingPathComponent(path, isDirectory: true)
            guard (try? manager.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory else { return false }
        }
        guard let infoData = smallFile(bundle.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundlePackageType"] as? String == "BNDL",
              info["CFBundleIdentifier"] as? String == Self.identity.bundleIdentifier,
              info["NSPrincipalClass"] as? String == Self.identity.principalClass,
              info["CFBundleExecutable"] as? String == "MyWallpaperScreenSaver",
              let runtimeVersion = info["MyWallpaperRuntimeVersion"] as? Int, runtimeVersion >= 3 else { return false }

        let executable = bundle.appendingPathComponent("Contents/MacOS/MyWallpaperScreenSaver")
        guard nonemptyRegularFile(executable), manager.isExecutableFile(atPath: executable.path),
              nonemptyRegularFile(bundle.appendingPathComponent("Contents/Resources/poster.jpg")),
              let data = smallFile(bundle.appendingPathComponent("Contents/Resources/configuration.json")),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
              configuration.version == 1,
              ["video.mp4", "video.mov"].contains(configuration.videoFileName),
              configuration.syncRootPath == expectedRoot else { return false }
        return true
    }

    private func nonemptyRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value > 0 else { return false }
        return true
    }

    private func smallFile(_ url: URL) -> Data? {
        guard nonemptyRegularFile(url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.uint64Value <= 65_536 else { return nil }
        return try? Data(contentsOf: url)
    }

    private struct Configuration: Decodable {
        let version: Int
        let videoFileName: String
        let scaling: ScreenSaverExportOptions.Scaling
        let animateOnBattery: Bool
        let animateOnExternalPower: Bool
        let pauseInLowPowerMode: Bool
        let syncRootPath: String
    }
}
