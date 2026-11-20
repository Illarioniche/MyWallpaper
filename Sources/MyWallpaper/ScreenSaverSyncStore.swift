import CryptoKit
import Darwin
import Foundation
import ImageIO

struct ScreenSaverSyncSnapshot: Codable, Equatable, Sendable {
    var version = 1
    let revision: UUID
    let name: String
    let videoFileName: String
    let scaling: ScreenSaverExportOptions.Scaling
    let animateOnBattery: Bool
    let animateOnExternalPower: Bool
    let pauseInLowPowerMode: Bool

    var options: ScreenSaverExportOptions {
        ScreenSaverExportOptions(scaling: scaling, animateOnBattery: animateOnBattery,
            animateOnExternalPower: animateOnExternalPower, pauseInLowPowerMode: pauseInLowPowerMode)
    }
}

struct ScreenSaverSyncError: Error, Equatable, Sendable {
    let ruKey: String
    let detail: String?

    init(ruKey: String, detail: String? = nil) {
        self.ruKey = ruKey
        self.detail = detail
    }
}

/// A current.json manifest selects immutable media. Existing revisions remain
/// available to screen-saver hosts which have already opened their URLs.
/// Synchronous I/O belongs on a background task; initialization never writes.
struct ScreenSaverSyncStore: Sendable {
    let rootURL: URL

    static var defaultRootURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("MyWallpaper/ScreenSaverSync", isDirectory: true)
    }

    init(rootURL: URL = Self.defaultRootURL) { self.rootURL = rootURL }

    func publish(videoURL: URL, posterJPEG: Data, options: ScreenSaverExportOptions,
                 name: String) throws -> ScreenSaverSyncSnapshot {
        try translate("Не удалось обновить синхронизированную заставку.") {
            try Task.checkCancellation()
            let name = try validatedName(name)
            try validateURL(videoURL)
            let suffix = videoURL.pathExtension.lowercased()
            guard ["mp4", "mov"].contains(suffix) else {
                throw ScreenSaverSyncError(ruKey: "Для синхронизации заставки выбери видео MP4 или MOV.")
            }
            guard !posterJPEG.isEmpty, posterJPEG.count <= 32 * 1_024 * 1_024,
                  let source = CGImageSourceCreateWithData(posterJPEG as CFData, nil),
                  CGImageSourceGetType(source) as String? == "public.jpeg",
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw ScreenSaverSyncError(ruKey: "Не удалось подготовить кадр синхронизированной заставки.")
            }
            let input = open(videoURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard input >= 0 else { throw posixError() }
            defer { close(input) }
            let fingerprint = try sourceFingerprint(input, url: videoURL, poster: posterJPEG)
            guard let root = try openRoot(create: true) else { throw corruptFeed() }
            defer { close(root) }
            let filename = "video.\(suffix)"

            let current = try readSnapshot(root: root)
            if let revision = try matchingRevision(fingerprint, filename: filename, current: current, root: root) {
                let updated = snapshot(revision: revision, name: name, filename: filename, options: options)
                if current != updated {
                    try Task.checkCancellation()
                    try atomicWrite(try encode(updated), name: "current.json", directory: root)
                }
                return updated
            }

            let id = UUID()
            let pending = ".creating-\(id.uuidString)"
            guard mkdirat(root, pending, 0o700) == 0 else { throw posixError() }
            var directoryName = pending
            var published = false
            defer {
                if !published {
                    // Only this attempt's fixed, app-owned files are removed.
                    if let directory = try? openDirectory(directoryName, parent: root) {
                        for name in [filename, "poster.jpg", "source.json"] { unlinkat(directory, name, 0) }
                        close(directory)
                        unlinkat(root, directoryName, AT_REMOVEDIR)
                    }
                }
            }
            let directory = try openDirectory(pending, parent: root)
            defer { close(directory) }
            try copyVideo(input, name: filename, directory: directory)
            guard try sourceFingerprint(input, url: videoURL, poster: posterJPEG) == fingerprint else {
                throw ScreenSaverSyncError(ruKey: "Видео изменилось во время синхронизации. Попробуй ещё раз.")
            }
            try writeNew(posterJPEG, name: "poster.jpg", directory: directory)
            try writeNew(try encode(fingerprint), name: "source.json", directory: directory)
            guard fsync(directory) == 0 else { throw posixError() }
            try Task.checkCancellation()
            guard renameatx_np(root, pending, root, id.uuidString, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
            directoryName = id.uuidString
            let result = snapshot(revision: id, name: name, filename: filename, options: options)
            try atomicWrite(try encode(result), name: "current.json", directory: root)
            published = true
            return result
        }
    }

    func snapshot() throws -> ScreenSaverSyncSnapshot? {
        try translate("Не удалось прочитать синхронизированную заставку.") {
            guard let root = try openRoot(create: false) else { return nil }
            defer { close(root) }
            return try readSnapshot(root: root)
        }
    }

    func videoURL(for snapshot: ScreenSaverSyncSnapshot) throws -> URL {
        try resourceURL(snapshot.videoFileName, snapshot: snapshot)
    }

    func posterURL(for snapshot: ScreenSaverSyncSnapshot) throws -> URL {
        try resourceURL("poster.jpg", snapshot: snapshot)
    }

    /// A stable identity is installed once; later playback reads current.json.
    /// A newly prepared, signed installer replaces only our private cache.
    func prepareInstaller(templateURL: URL,
                          signer: ScreenSaverExporter.Signer = ScreenSaverExporter.signAndVerify) throws -> URL {
        try translate("Не удалось подготовить синхронизированную заставку к установке.") {
            guard let root = try openRoot(create: false) else { throw corruptFeed() }
            defer { close(root) }
            guard let current = try readSnapshot(root: root) else { throw corruptFeed() }
            let identity = ScreenSaverSyncInstallation.identity
            let stageName = ".installing-\(UUID().uuidString)"
            guard mkdirat(root, stageName, 0o700) == 0 else { throw posixError() }
            let stage = rootURL.appendingPathComponent(stageName, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            let video = try videoURL(for: current)
            let poster = try posterURL(for: current)
            _ = try ScreenSaverExporter.export(videoURL: video, posterJPEG: Data(contentsOf: poster),
                templateURL: templateURL, destinationURL: stage.appendingPathComponent(identity.fileName, isDirectory: true),
                options: current.options, identity: identity, syncRootURL: rootURL, signer: signer)
            try Task.checkCancellation()
            let destinationName = ".installation"
            if try itemExists(destinationName, directory: root) {
                let previous = try openDirectory(destinationName, parent: root)
                close(previous)
                guard renameatx_np(root, stageName, root, destinationName, UInt32(RENAME_SWAP)) == 0 else { throw posixError() }
            } else {
                guard renameatx_np(root, stageName, root, destinationName, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
            }
            _ = fsync(root)
            return rootURL.appendingPathComponent(destinationName, isDirectory: true)
                .appendingPathComponent(identity.fileName, isDirectory: true)
        }
    }

    private func resourceURL(_ filename: String, snapshot: ScreenSaverSyncSnapshot) throws -> URL {
        try translate("Не удалось прочитать синхронизированную заставку.") {
            try validate(snapshot)
            guard let root = try openRoot(create: false) else { throw corruptFeed() }
            defer { close(root) }
            let revision = try openDirectory(snapshot.revision.uuidString, parent: root)
            defer { close(revision) }
            try requireFile(filename, directory: revision)
            return rootURL.appendingPathComponent(snapshot.revision.uuidString, isDirectory: true).appendingPathComponent(filename)
        }
    }

    private func snapshot(revision: UUID, name: String, filename: String,
                          options: ScreenSaverExportOptions) -> ScreenSaverSyncSnapshot {
        ScreenSaverSyncSnapshot(revision: revision, name: name, videoFileName: filename, scaling: options.scaling,
            animateOnBattery: options.animateOnBattery, animateOnExternalPower: options.animateOnExternalPower,
            pauseInLowPowerMode: options.pauseInLowPowerMode)
    }

    private func readSnapshot(root: Int32) throws -> ScreenSaverSyncSnapshot? {
        guard try itemExists("current.json", directory: root) else { return nil }
        let snapshot = try JSONDecoder().decode(ScreenSaverSyncSnapshot.self, from: readSmallFile("current.json", directory: root))
        try validate(snapshot)
        let revision = try openDirectory(snapshot.revision.uuidString, parent: root)
        defer { close(revision) }
        try requireFile(snapshot.videoFileName, directory: revision)
        try requireFile("poster.jpg", directory: revision)
        return snapshot
    }

    private func validate(_ snapshot: ScreenSaverSyncSnapshot) throws {
        guard snapshot.version == 1, ["video.mp4", "video.mov"].contains(snapshot.videoFileName),
              snapshot.name == (try validatedName(snapshot.name)) else { throw corruptFeed() }
    }

    private struct SourceFingerprint: Codable, Equatable {
        let pathHash: String
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let posterHash: String
    }

    private func matchingRevision(_ fingerprint: SourceFingerprint, filename: String,
                                  current: ScreenSaverSyncSnapshot?, root: Int32) throws -> UUID? {
        func matches(_ id: UUID) -> Bool {
            guard let directory = try? openDirectory(id.uuidString, parent: root) else { return false }
            defer { close(directory) }
            guard let data = try? readSmallFile("source.json", directory: directory),
                  let source = try? JSONDecoder().decode(SourceFingerprint.self, from: data), source == fingerprint else { return false }
            do {
                try requireFile(filename, directory: directory)
                try requireFile("poster.jpg", directory: directory)
                return true
            } catch { return false }
        }
        if let current, current.videoFileName == filename, matches(current.revision) { return current.revision }
        for name in try FileManager.default.contentsOfDirectory(atPath: rootURL.path).sorted() {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: name), name == id.uuidString, id != current?.revision else { continue }
            if matches(id) { return id }
        }
        return nil
    }

    private func sourceFingerprint(_ file: Int32, url: URL, poster: Data) throws -> SourceFingerprint {
        var info = stat()
        guard fstat(file, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else {
            throw ScreenSaverSyncError(ruKey: "Для синхронизации заставки выбери видео MP4 или MOV.")
        }
        return SourceFingerprint(pathHash: digest(Data(url.standardizedFileURL.path.utf8)),
            device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec),
            posterHash: digest(poster))
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func copyVideo(_ input: Int32, name: String, directory: Int32) throws {
        let output = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw posixError() }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(input, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            try buffer.withUnsafeBytes { bytes in
                try writeBytes(UnsafeRawBufferPointer(start: bytes.baseAddress, count: count), to: output)
            }
        }
        guard fsync(output) == 0 else { throw posixError() }
    }

    private func atomicWrite(_ data: Data, name: String, directory: Int32) throws {
        if try itemExists(name, directory: directory) { try requireFile(name, directory: directory) }
        let pending = ".pending-\(UUID().uuidString)"
        defer { unlinkat(directory, pending, 0) }
        try writeNew(data, name: pending, directory: directory)
        try Task.checkCancellation()
        if try itemExists(name, directory: directory) { try requireFile(name, directory: directory) }
        guard renameat(directory, pending, directory, name) == 0 else { throw posixError() }
        // The manifest is committed; cancellation must not report a stale result.
        // A best-effort directory flush does not undo an already visible rename.
        _ = fsync(directory)
    }

    private func writeNew(_ data: Data, name: String, directory: Int32) throws {
        let file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw posixError() }
        defer { close(file) }
        try data.withUnsafeBytes { try writeBytes($0, to: file) }
        guard fsync(file) == 0 else { throw posixError() }
    }

    private func writeBytes(_ bytes: UnsafeRawBufferPointer, to file: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw posixError() }
            offset += count
        }
    }

    private func readSmallFile(_ name: String, directory: Int32) throws -> Data {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw posixError() }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 65_536 else { throw corruptFeed() }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        let data = try handle.read(upToCount: 65_537) ?? Data()
        guard data.count == info.st_size, data.count <= 65_536 else { throw corruptFeed() }
        return data
    }

    private func requireFile(_ name: String, directory: Int32) throws {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { throw corruptFeed() }
    }

    private func itemExists(_ name: String, directory: Int32) throws -> Bool {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw posixError()
    }

    private func openRoot(create: Bool) throws -> Int32? {
        try validateURL(rootURL)
        let components = rootURL.pathComponents.dropFirst()
        guard !components.isEmpty else { throw corruptFeed() }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        do {
            for (index, component) in components.enumerated() {
                if create && mkdirat(descriptor, component, 0o700) != 0 && errno != EEXIST { throw posixError() }
                var child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0 && index < components.count - 1 {
                    // Trust only macOS's root-owned aliases, such as /var -> /private/var.
                    var linkInfo = stat()
                    var parentInfo = stat()
                    if fstatat(descriptor, component, &linkInfo, AT_SYMLINK_NOFOLLOW) == 0,
                       fstat(descriptor, &parentInfo) == 0, linkInfo.st_mode & S_IFMT == S_IFLNK,
                       linkInfo.st_uid == 0, parentInfo.st_uid == 0, parentInfo.st_mode & 0o022 == 0 {
                        child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                    }
                }
                if child < 0 && !create && errno == ENOENT { close(descriptor); return nil }
                guard child >= 0 else { throw posixError() }
                close(descriptor)
                descriptor = child
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private func openDirectory(_ name: String, parent: Int32) throws -> Int32 {
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw posixError() }
        return directory
    }

    private func validateURL(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "" || url.host == "localhost",
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw corruptFeed() }
    }

    private func validatedName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ScreenSaverSyncError(ruKey: "Некорректное название синхронизированной заставки.")
        }
        return value
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private func corruptFeed() -> ScreenSaverSyncError {
        ScreenSaverSyncError(ruKey: "Данные синхронизированной заставки недоступны или повреждены.")
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private func translate<T>(_ key: String, _ action: () throws -> T) throws -> T {
        do { return try action() }
        catch is CancellationError { throw CancellationError() }
        catch let error as ScreenSaverSyncError { throw error }
        catch let error as ScreenSaverExportError {
            throw ScreenSaverSyncError(ruKey: error.ruKey, detail: error.detail)
        }
        catch { throw ScreenSaverSyncError(ruKey: key, detail: error.localizedDescription) }
    }
}
