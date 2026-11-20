import Darwin
import Foundation

struct ScreenSaverLibraryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let createdAt: Date
    let sourceFileName: String?
    let options: ScreenSaverExportOptions
}

struct ScreenSaverLibraryError: Error, Equatable, Sendable {
    let ruKey: String
    let detail: String?

    init(ruKey: String, detail: String? = nil) {
        self.ruKey = ruKey
        self.detail = detail
    }
}

struct ScreenSaverLibraryListing: Sendable {
    let entries: [ScreenSaverLibraryEntry]
    let warnings: [ScreenSaverLibraryError]
}

/// File operations are synchronous and must be called off the main actor.
/// Labels never become paths; every record owns one canonical UUID directory.
struct ScreenSaverLibrary: Sendable {
    let rootURL: URL

    static var defaultRootURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("MyWallpaper/ScreenSavers", isDirectory: true)
    }

    /// Resolves no bookmarks, creates no directories, and reads no records.
    init(rootURL: URL = Self.defaultRootURL) { self.rootURL = rootURL }

    func list() throws -> ScreenSaverLibraryListing {
        try withErrors("Не удалось открыть библиотеку заставок.") {
            guard try validateRoot() else { return ScreenSaverLibraryListing(entries: [], warnings: []) }
            let children = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            var entries: [ScreenSaverLibraryEntry] = []
            var warnings: [ScreenSaverLibraryError] = []
            for directory in children where !directory.lastPathComponent.hasPrefix(".") {
                try Task.checkCancellation()
                let component = directory.lastPathComponent
                guard let id = UUID(uuidString: component), component == id.uuidString else {
                    warnings.append(corruptRecord(component))
                    continue
                }
                do { entries.append(try readEntry(id: id)) }
                catch is CancellationError { throw CancellationError() }
                catch { warnings.append(corruptRecord(component)) }
            }
            entries.sort {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            }
            return ScreenSaverLibraryListing(entries: entries, warnings: warnings)
        }
    }

    func create(videoURL: URL, posterJPEG: Data, templateURL: URL, name: String,
                options: ScreenSaverExportOptions = .init(),
                signer: ScreenSaverExporter.Signer = ScreenSaverExporter.signAndVerify) throws -> ScreenSaverLibraryEntry {
        try withErrors("Не удалось сохранить заставку в библиотеку.") {
            let name = try validatedName(name)
            try Task.checkCancellation()
            try prepareRoot()
            let id = UUID()
            let stage = rootURL.appendingPathComponent(".creating-\(id.uuidString)", isDirectory: true)
            guard mkdir(stage.path, 0o700) == 0 else { throw posixError() }
            defer { try? FileManager.default.removeItem(at: stage) }
            try ScreenSaverExporter.export(videoURL: videoURL, posterJPEG: posterJPEG, templateURL: templateURL,
                                           destinationURL: stage.appendingPathComponent("MyWallpaper.saver", isDirectory: true),
                                           options: options, signer: signer)
            try Task.checkCancellation()
            let entry = ScreenSaverLibraryEntry(id: id, name: name, createdAt: Date(),
                                               sourceFileName: videoURL.lastPathComponent, options: options)
            try writeMetadata(entry, to: stage)
            // Read our serialized metadata and verify safe bundle paths before
            // publishing the entire record in one no-overwrite rename.
            _ = try readEntry(id: id, directory: stage)
            try Task.checkCancellation()
            guard try validateRoot() else { throw invalidRoot() }
            guard renamex_np(stage.path, entryDirectory(id).path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
            return entry
        }
    }

    @discardableResult
    func rename(id: UUID, name: String) throws -> ScreenSaverLibraryEntry {
        try withErrors("Не удалось переименовать заставку.") {
            let name = try validatedName(name)
            try requireRoot()
            let old = try readEntry(id: id)
            let updated = ScreenSaverLibraryEntry(id: old.id, name: name, createdAt: old.createdAt,
                                                 sourceFileName: old.sourceFileName, options: old.options)
            try Task.checkCancellation()
            try writeMetadata(updated, to: entryDirectory(id))
            return updated
        }
    }

    func delete(id: UUID) throws {
        try withErrors("Не удалось удалить заставку.") {
            try requireRoot()
            _ = try readEntry(id: id)
            try Task.checkCancellation()
            // Validate both owned directory boundaries without following links.
            // FileManager removes links inside a directory rather than their targets.
            try requireDirectory(rootURL)
            try requireDirectory(entryDirectory(id))
            try FileManager.default.removeItem(at: entryDirectory(id))
        }
    }

    func bundleURL(for id: UUID) throws -> URL {
        try withErrors("Заставка не найдена в библиотеке.") {
            try requireRoot()
            _ = try readEntry(id: id)
            return entryDirectory(id).appendingPathComponent("MyWallpaper.saver", isDirectory: true)
        }
    }

    func thumbnailURL(for id: UUID) throws -> URL {
        try bundleURL(for: id).appendingPathComponent("Contents/Resources/poster.jpg")
    }

    /// Rebuilds the installer from the saved media, never from the original
    /// user file. This also upgrades records created by the old shared-identity
    /// exporter without modifying their metadata or their saved bundle.
    func prepareInstallation(id: UUID, templateURL: URL?,
                             signer: ScreenSaverExporter.Signer = ScreenSaverExporter.signAndVerify) throws -> URL {
        try withErrors("Не удалось подготовить установку заставки.") {
            try requireRoot()
            let entry = try readEntry(id: id)
            let directory = entryDirectory(id)
            let savedBundle = directory.appendingPathComponent("MyWallpaper.saver", isDirectory: true)
            let resources = savedBundle.appendingPathComponent("Contents/Resources", isDirectory: true)
            let configuration = try JSONDecoder().decode(ExportedConfiguration.self,
                                                         from: smallFile(resources.appendingPathComponent("configuration.json")))
            let identity = ScreenSaverInstallationIdentity(id: id, name: entry.name)
            let installDirectory = directory.appendingPathComponent(".installation", isDirectory: true)
            let stage = directory.appendingPathComponent(".installing-\(UUID().uuidString)", isDirectory: true)
            guard mkdir(stage.path, 0o700) == 0 else { throw posixError() }
            defer { try? FileManager.default.removeItem(at: stage) }
            try ScreenSaverExporter.export(videoURL: resources.appendingPathComponent(configuration.videoFileName),
                                           posterJPEG: Data(contentsOf: resources.appendingPathComponent("poster.jpg")),
                                           templateURL: templateURL ?? savedBundle,
                                           destinationURL: stage.appendingPathComponent(identity.fileName, isDirectory: true),
                                           options: entry.options, identity: identity, signer: signer)
            try Task.checkCancellation()
            try requireDirectory(directory)
            // Keep the previous complete installer if preparation/signing fails.
            // Replacing only this app-owned cache preserves the library record.
            if try itemType(installDirectory) != nil {
                try requireDirectory(installDirectory)
                guard renamex_np(stage.path, installDirectory.path, UInt32(RENAME_SWAP)) == 0 else { throw posixError() }
            } else {
                guard renamex_np(stage.path, installDirectory.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
            }
            return installDirectory.appendingPathComponent(identity.fileName, isDirectory: true)
        }
    }

    private func readEntry(id: UUID, directory: URL? = nil) throws -> ScreenSaverLibraryEntry {
        let directory = directory ?? entryDirectory(id)
        try requireDirectory(directory)
        let metadata = directory.appendingPathComponent("metadata.json")
        let entry = try JSONDecoder().decode(ScreenSaverLibraryEntry.self, from: smallFile(metadata))
        guard entry.id == id, entry.name == (try validatedName(entry.name)), entry.createdAt.timeIntervalSince1970.isFinite else {
            throw corruptRecord(id.uuidString)
        }
        let bundle = directory.appendingPathComponent("MyWallpaper.saver", isDirectory: true)
        try requireDirectory(bundle)
        try requireDirectory(bundle.appendingPathComponent("Contents", isDirectory: true))
        try requireDirectory(bundle.appendingPathComponent("Contents/MacOS", isDirectory: true))
        try requireDirectory(bundle.appendingPathComponent("Contents/Resources", isDirectory: true))
        let infoData = try smallFile(bundle.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundlePackageType"] as? String == "BNDL",
              info["CFBundleIdentifier"] as? String == "app.mywallpaper.screensaver",
              info["NSPrincipalClass"] as? String == "MyWallpaperScreenSaverView",
              info["CFBundleExecutable"] as? String == "MyWallpaperScreenSaver" else { throw corruptRecord(id.uuidString) }
        try requireRegularFile(bundle.appendingPathComponent("Contents/MacOS/MyWallpaperScreenSaver"))
        try requireRegularFile(bundle.appendingPathComponent("Contents/Resources/poster.jpg"))
        let configurationURL = bundle.appendingPathComponent("Contents/Resources/configuration.json")
        let configuration = try JSONDecoder().decode(ExportedConfiguration.self, from: smallFile(configurationURL))
        // Every exported media resource is a direct, fixed-name local file.
        // sourceFileName is display-only and never participates in path lookup.
        guard configuration.version == 1, ["video.mp4", "video.mov"].contains(configuration.videoFileName),
              configuration.scaling == entry.options.scaling,
              configuration.animateOnBattery == entry.options.animateOnBattery,
              configuration.animateOnExternalPower == entry.options.animateOnExternalPower,
              configuration.pauseInLowPowerMode == entry.options.pauseInLowPowerMode else {
            throw corruptRecord(id.uuidString)
        }
        try requireRegularFile(bundle.appendingPathComponent("Contents/Resources/\(configuration.videoFileName)"))
        return entry
    }

    private struct ExportedConfiguration: Decodable {
        let version: Int
        let videoFileName: String
        let scaling: ScreenSaverExportOptions.Scaling
        let animateOnBattery: Bool
        let animateOnExternalPower: Bool
        let pauseInLowPowerMode: Bool
    }

    private func smallFile(_ url: URL) throws -> Data {
        try requireRegularFile(url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size, size.intValue > 0, size.intValue <= 65_536 else { throw corruptRecord(url.lastPathComponent) }
        return try Data(contentsOf: url)
    }

    private func writeMetadata(_ entry: ScreenSaverLibraryEntry, to directory: URL) throws {
        try requireDirectory(directory)
        let metadata = directory.appendingPathComponent("metadata.json")
        if try itemType(metadata) != nil { try requireRegularFile(metadata) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entry).write(to: metadata, options: .atomic)
    }

    private func validatedName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ScreenSaverLibraryError(ruKey: "Введи название заставки.") }
        guard normalized.count <= 80, !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ScreenSaverLibraryError(ruKey: "Название заставки должно быть не длиннее 80 символов и не содержать управляющих символов.")
        }
        return normalized
    }

    private func entryDirectory(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func validateRoot() throws -> Bool {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/"),
              rootURL.host == nil || rootURL.host == "" || rootURL.host == "localhost",
              !rootURL.pathComponents.contains(".."), !rootURL.pathComponents.contains("."),
              rootURL.query == nil, rootURL.fragment == nil else { throw invalidRoot() }
        guard let type = try itemType(rootURL) else { return false }
        guard type == .typeDirectory else { throw invalidRoot() }
        return true
    }

    private func requireRoot() throws {
        guard try validateRoot() else { throw ScreenSaverLibraryError(ruKey: "Заставка не найдена в библиотеке.") }
    }

    private func prepareRoot() throws {
        if try validateRoot() { return }
        var missing: [URL] = []
        var current = rootURL
        while try itemType(current) == nil {
            missing.append(current)
            current = current.deletingLastPathComponent()
        }
        try requireDirectory(current)
        for directory in missing.reversed() {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                // Another library instance may have created the same parent.
                try requireDirectory(directory)
            }
        }
        try requireRoot()
    }

    private func itemType(_ url: URL) throws -> FileAttributeType? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .typeDirectory
        case S_IFREG: return .typeRegular
        case S_IFLNK: return .typeSymbolicLink
        default: return .typeUnknown
        }
    }

    private func requireDirectory(_ url: URL) throws {
        guard try itemType(url) == .typeDirectory else { throw corruptRecord(url.lastPathComponent) }
    }

    private func requireRegularFile(_ url: URL) throws {
        guard try itemType(url) == .typeRegular else { throw corruptRecord(url.lastPathComponent) }
    }

    private func invalidRoot() -> ScreenSaverLibraryError {
        ScreenSaverLibraryError(ruKey: "Папка библиотеки заставок недоступна или является ссылкой.")
    }

    private func corruptRecord(_ component: String) -> ScreenSaverLibraryError {
        ScreenSaverLibraryError(ruKey: "Запись библиотеки заставок повреждена.", detail: component)
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private func withErrors<T>(_ key: String, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch is CancellationError { throw CancellationError() }
        catch let error as ScreenSaverLibraryError { throw error }
        catch let error as ScreenSaverExportError {
            throw ScreenSaverLibraryError(ruKey: error.ruKey, detail: error.detail)
        } catch {
            throw ScreenSaverLibraryError(ruKey: key, detail: error.localizedDescription)
        }
    }
}
