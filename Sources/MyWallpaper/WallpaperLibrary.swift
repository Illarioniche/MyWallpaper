import Darwin
import Foundation
import ImageIO

struct WallpaperLibraryOptions: Codable, Equatable, Sendable {
    var target: DisplayTarget = .all
    var scaling: VideoScaling = .fill
    var isMuted = true
    var volume: Double = 1
    var animateOnExternalPower = true
    var animateOnBattery = false
    var pauseInLowPowerMode = true
    var pauseWhenCovered = true
    var syncSystemWallpaper = false
    var usesGlobalPowerRules = true

    var powerRules: WallpaperPowerRules {
        get {
            WallpaperPowerRules(animateOnExternalPower: animateOnExternalPower,
                animateOnBattery: animateOnBattery, pauseInLowPowerMode: pauseInLowPowerMode,
                pauseWhenCovered: pauseWhenCovered)
        }
        set {
            animateOnExternalPower = newValue.animateOnExternalPower
            animateOnBattery = newValue.animateOnBattery
            pauseInLowPowerMode = newValue.pauseInLowPowerMode
            pauseWhenCovered = newValue.pauseWhenCovered
        }
    }

    func effectivePowerRules(defaults: WallpaperPowerRules) -> WallpaperPowerRules {
        usesGlobalPowerRules ? defaults : powerRules
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target == rhs.target && lhs.scaling == rhs.scaling && lhs.isMuted == rhs.isMuted
            && Float(lhs.volume) == Float(rhs.volume)
            && lhs.animateOnExternalPower == rhs.animateOnExternalPower
            && lhs.animateOnBattery == rhs.animateOnBattery
            && lhs.pauseInLowPowerMode == rhs.pauseInLowPowerMode
            && lhs.pauseWhenCovered == rhs.pauseWhenCovered
            && lhs.syncSystemWallpaper == rhs.syncSystemWallpaper
            && lhs.usesGlobalPowerRules == rhs.usesGlobalPowerRules
    }
}

extension WallpaperLibraryOptions {
    private enum CodingKeys: String, CodingKey {
        case target, scaling, isMuted, volume, animateOnExternalPower, animateOnBattery
        case pauseInLowPowerMode, pauseWhenCovered, syncSystemWallpaper, usesGlobalPowerRules
    }

    /// Version 0.8 saved explicit power settings in every entry. Missing the
    /// inheritance marker means those exact settings remain an exception.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decode(DisplayTarget.self, forKey: .target)
        scaling = try values.decode(VideoScaling.self, forKey: .scaling)
        isMuted = try values.decode(Bool.self, forKey: .isMuted)
        volume = try values.decode(Double.self, forKey: .volume)
        animateOnExternalPower = try values.decode(Bool.self, forKey: .animateOnExternalPower)
        animateOnBattery = try values.decode(Bool.self, forKey: .animateOnBattery)
        pauseInLowPowerMode = try values.decode(Bool.self, forKey: .pauseInLowPowerMode)
        pauseWhenCovered = try values.decode(Bool.self, forKey: .pauseWhenCovered)
        syncSystemWallpaper = try values.decode(Bool.self, forKey: .syncSystemWallpaper)
        usesGlobalPowerRules = values.contains(.usesGlobalPowerRules)
            ? try values.decode(Bool.self, forKey: .usesGlobalPowerRules) : false
    }
}

struct WallpaperLibraryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let createdAt: Date
    let sourceFileName: String
    let options: WallpaperLibraryOptions
}

struct WallpaperLibraryError: Error, Equatable, Sendable {
    let ruKey: String
    let detail: String?

    init(ruKey: String, detail: String? = nil) {
        self.ruKey = ruKey
        self.detail = detail
    }
}

struct WallpaperLibraryListing: Sendable {
    let entries: [WallpaperLibraryEntry]
    let warnings: [WallpaperLibraryError]
}

/// Synchronous file operations, called outside the main actor by the controller.
/// Each UUID owns a directory; user-facing names never become filesystem paths.
struct WallpaperLibrary: Sendable {
    let rootURL: URL

    static var defaultRootURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("MyWallpaper/Wallpapers", isDirectory: true)
    }

    init(rootURL: URL = Self.defaultRootURL) { self.rootURL = rootURL }

    func list() throws -> WallpaperLibraryListing {
        try withErrors("Не удалось открыть библиотеку обоев.") {
            guard try validateRoot() else { return WallpaperLibraryListing(entries: [], warnings: []) }
            var entries: [WallpaperLibraryEntry] = []
            var warnings: [WallpaperLibraryError] = []
            for directory in try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
                where !directory.lastPathComponent.hasPrefix(".") {
                try Task.checkCancellation()
                let component = directory.lastPathComponent
                guard let id = UUID(uuidString: component), id.uuidString == component else {
                    warnings.append(corruptRecord(component)); continue
                }
                do { entries.append(try readRecord(id: id).entry) }
                catch is CancellationError { throw CancellationError() }
                catch { warnings.append(corruptRecord(component)) }
            }
            entries.sort {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            }
            return WallpaperLibraryListing(entries: entries, warnings: warnings)
        }
    }

    func create(videoURL: URL, posterJPEG: Data, name: String,
                options: WallpaperLibraryOptions = .init()) throws -> WallpaperLibraryEntry {
        try withErrors("Не удалось сохранить обои в библиотеку.") {
            let name = try validatedName(name)
            try validate(options)
            try Task.checkCancellation()
            guard videoURL.isFileURL, let imageSource = CGImageSourceCreateWithData(posterJPEG as CFData, nil),
                  CGImageSourceGetType(imageSource) as String? == "public.jpeg",
                  CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil else {
                throw WallpaperLibraryError(ruKey: "Не удалось подготовить кадр обоев.")
            }
            let suffix = videoURL.pathExtension.lowercased()
            guard !suffix.isEmpty, suffix.count <= 12,
                  suffix.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else {
                throw WallpaperLibraryError(ruKey: "Выбери локальное видео для обоев.")
            }
            try prepareRoot()
            let id = UUID()
            let stage = rootURL.appendingPathComponent(".creating-\(id.uuidString)", isDirectory: true)
            guard mkdir(stage.path, 0o700) == 0 else { throw posixError() }
            defer { try? FileManager.default.removeItem(at: stage) }
            let mediaName = "video.\(suffix)"
            try copyVideo(videoURL, to: stage.appendingPathComponent(mediaName))
            try posterJPEG.write(to: stage.appendingPathComponent("poster.jpg"), options: .atomic)
            let entry = WallpaperLibraryEntry(id: id, name: name, createdAt: Date(),
                                              sourceFileName: videoURL.lastPathComponent, options: options)
            let record = Record(version: 1, entry: entry, videoFileName: mediaName)
            try write(record, directory: stage)
            _ = try readRecord(id: id, directory: stage)
            try Task.checkCancellation()
            try requireRoot()
            guard renamex_np(stage.path, entryDirectory(id).path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
            return entry
        }
    }

    @discardableResult
    func rename(id: UUID, name: String) throws -> WallpaperLibraryEntry {
        try withErrors("Не удалось переименовать обои.") {
            let name = try validatedName(name)
            try requireRoot()
            let record = try readRecord(id: id)
            let old = record.entry
            let entry = WallpaperLibraryEntry(id: old.id, name: name, createdAt: old.createdAt,
                                              sourceFileName: old.sourceFileName, options: old.options)
            try Task.checkCancellation()
            try write(Record(version: 1, entry: entry, videoFileName: record.videoFileName), directory: entryDirectory(id))
            return entry
        }
    }

    @discardableResult
    func updateOptions(id: UUID, options: WallpaperLibraryOptions) throws -> WallpaperLibraryEntry {
        try withErrors("Не удалось сохранить настройки обоев.") {
            try validate(options)
            try requireRoot()
            let record = try readRecord(id: id)
            let old = record.entry
            let entry = WallpaperLibraryEntry(id: old.id, name: old.name, createdAt: old.createdAt,
                                              sourceFileName: old.sourceFileName, options: options)
            try Task.checkCancellation()
            try write(Record(version: 1, entry: entry, videoFileName: record.videoFileName), directory: entryDirectory(id))
            return entry
        }
    }

    func delete(id: UUID) throws {
        try withErrors("Не удалось удалить обои из библиотеки.") {
            try requireRoot()
            _ = try readRecord(id: id)
            try Task.checkCancellation()
            try requireDirectory(entryDirectory(id))
            try FileManager.default.removeItem(at: entryDirectory(id))
        }
    }

    func entry(for id: UUID) throws -> WallpaperLibraryEntry {
        try withErrors("Обои не найдены в библиотеке.") {
            try requireRoot()
            return try readRecord(id: id).entry
        }
    }

    func videoURL(for id: UUID) throws -> URL {
        try withErrors("Обои не найдены в библиотеке.") {
            try requireRoot()
            let record = try readRecord(id: id)
            return entryDirectory(id).appendingPathComponent(record.videoFileName)
        }
    }

    func thumbnailURL(for id: UUID) throws -> URL {
        try withErrors("Обои не найдены в библиотеке.") {
            try requireRoot()
            _ = try readRecord(id: id)
            return entryDirectory(id).appendingPathComponent("poster.jpg")
        }
    }

    private struct Record: Codable {
        let version: Int
        let entry: WallpaperLibraryEntry
        let videoFileName: String
    }

    private func readRecord(id: UUID, directory: URL? = nil) throws -> Record {
        let directory = directory ?? entryDirectory(id)
        try requireDirectory(directory)
        let metadata = directory.appendingPathComponent("metadata.json")
        try requireFile(metadata)
        let size = try FileManager.default.attributesOfItem(atPath: metadata.path)[.size] as? NSNumber
        guard let size, size.intValue > 0, size.intValue <= 65_536 else { throw corruptRecord(id.uuidString) }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: metadata))
        let entry = record.entry
        let suffix = String(record.videoFileName.dropFirst("video.".count))
        guard record.version == 1, entry.id == id, entry.name == (try validatedName(entry.name)),
              entry.createdAt.timeIntervalSince1970.isFinite,
              record.videoFileName.hasPrefix("video."), !suffix.isEmpty, suffix.count <= 12,
              suffix.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else {
            throw corruptRecord(id.uuidString)
        }
        try validate(entry.options)
        try requireFile(directory.appendingPathComponent(record.videoFileName))
        try requireFile(directory.appendingPathComponent("poster.jpg"))
        return record
    }

    private func copyVideo(_ source: URL, to destination: URL) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw posixError() }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else {
            throw WallpaperLibraryError(ruKey: "Выбери локальное видео для обоев.")
        }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw posixError() }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw posixError()
                    }
                    guard written > 0 else { throw POSIXError(.EIO) }
                    offset += written
                }
            }
        }
        guard fsync(output) == 0 else { throw posixError() }
    }

    private func write(_ record: Record, directory: URL) throws {
        try requireDirectory(directory)
        let metadata = directory.appendingPathComponent("metadata.json")
        if try itemType(metadata) != nil { try requireFile(metadata) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: metadata, options: .atomic)
    }

    private func validate(_ options: WallpaperLibraryOptions) throws {
        guard options.volume.isFinite, (0...1).contains(options.volume) else {
            throw WallpaperLibraryError(ruKey: "Некорректные настройки обоев.")
        }
    }

    private func validatedName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw WallpaperLibraryError(ruKey: "Введи название обоев.") }
        guard normalized.count <= 80, !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WallpaperLibraryError(ruKey: "Название обоев должно быть не длиннее 80 символов и не содержать управляющих символов.")
        }
        return normalized
    }

    private func entryDirectory(_ id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }

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
        guard try validateRoot() else { throw WallpaperLibraryError(ruKey: "Обои не найдены в библиотеке.") }
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
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700]) }
            catch { try requireDirectory(directory) }
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

    private func requireFile(_ url: URL) throws {
        guard try itemType(url) == .typeRegular else { throw corruptRecord(url.lastPathComponent) }
    }

    private func invalidRoot() -> WallpaperLibraryError {
        WallpaperLibraryError(ruKey: "Папка библиотеки обоев недоступна или является ссылкой.")
    }

    private func corruptRecord(_ component: String) -> WallpaperLibraryError {
        WallpaperLibraryError(ruKey: "Запись библиотеки обоев повреждена.", detail: component)
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private func withErrors<T>(_ key: String, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch is CancellationError { throw CancellationError() }
        catch let error as WallpaperLibraryError { throw error }
        catch { throw WallpaperLibraryError(ruKey: key, detail: error.localizedDescription) }
    }
}
