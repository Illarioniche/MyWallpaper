import AppKit
import CryptoKit
import Darwin
import ImageIO

@MainActor
protocol SystemWallpaperSyncing: AnyObject {
    func synchronize(image: CGImage, name: String, target: DisplayTarget, scaling: VideoScaling) async throws
}

struct SystemWallpaperScreen: Equatable, Sendable {
    let id: UInt32
    let name: String
}

/// The system image always scales proportionally and uses black letterboxing.
struct SystemWallpaperOptions: Equatable, Sendable {
    let allowClipping: Bool
    var imageScaling: NSImageScaling { .scaleProportionallyUpOrDown }
    var fillColor: NSColor { .black }
}

@MainActor
protocol SystemWallpaperDesktopAdapting: AnyObject {
    /// Preserves NSScreen.screens order: the first screen owns the menu bar.
    var screens: [SystemWallpaperScreen] { get }
    func matches(imageURL: URL, options: SystemWallpaperOptions, screen: SystemWallpaperScreen) -> Bool
    func apply(imageURL: URL, options: SystemWallpaperOptions, screen: SystemWallpaperScreen) throws
}

struct SystemWallpaperSyncError: Error, Sendable {
    /// The model translates the key and presents external diagnostics separately.
    let ruKey: String
    let detail: String?
    let failedScreenNames: [String]

    init(ruKey: String, detail: String? = nil, failedScreenNames: [String] = []) {
        self.ruKey = ruKey
        self.detail = detail
        self.failedScreenNames = failedScreenNames
    }
}

@MainActor
final class SystemWallpaperSync: SystemWallpaperSyncing {
    typealias Encoder = @Sendable (CGImage) throws -> Data

    nonisolated static var defaultStoreURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("MyWallpaper/SystemWallpapers", isDirectory: true)
    }

    private let storeURL: URL
    private let desktop: any SystemWallpaperDesktopAdapting
    private let encoder: Encoder

    init(storeURL: URL = SystemWallpaperSync.defaultStoreURL,
         desktop: any SystemWallpaperDesktopAdapting = SystemWallpaperDesktopAdapter(),
         encoder: @escaping Encoder = SystemWallpaperSync.encodeJPEG) {
        self.storeURL = storeURL
        self.desktop = desktop
        self.encoder = encoder
    }

    func synchronize(image: CGImage, name: String, target: DisplayTarget, scaling: VideoScaling) async throws {
        try Task.checkCancellation()
        let storeURL = storeURL
        let encoder = encoder
        let preparation = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let data: Data
            do { data = try encoder(image) }
            catch is CancellationError { throw CancellationError() }
            catch {
                throw SystemWallpaperSyncError(ruKey: "Не удалось подготовить статичный кадр системных обоев.",
                                               detail: error.localizedDescription)
            }
            try Task.checkCancellation()
            guard !data.isEmpty,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) as String? == "public.jpeg",
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw SystemWallpaperSyncError(ruKey: "Не удалось подготовить статичный кадр системных обоев.")
            }
            return try SystemWallpaperImageStore.publish(data, name: name, at: storeURL)
        }
        let imageURL = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        try Task.checkCancellation()
        let available = desktop.screens
        let screens = target == .main ? Array(available.prefix(1)) : available
        guard !screens.isEmpty else {
            throw SystemWallpaperSyncError(ruKey: "Нет доступных экранов для системных обоев.")
        }
        let options = SystemWallpaperOptions(allowClipping: scaling == .fill)
        var failures: [(String, String)] = []
        for screen in screens {
            try Task.checkCancellation()
            let matches = desktop.matches(imageURL: imageURL, options: options, screen: screen)
            try Task.checkCancellation()
            if matches { continue }
            do {
                try desktop.apply(imageURL: imageURL, options: options, screen: screen)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append((screen.name, error.localizedDescription))
            }
        }
        try Task.checkCancellation()
        if !failures.isEmpty {
            throw SystemWallpaperSyncError(ruKey: "Не удалось обновить системные обои на некоторых экранах.",
                                           detail: failures.map { "\($0.0): \($0.1)" }.joined(separator: "\n"),
                                           failedScreenNames: failures.map(\.0))
        }
    }

    nonisolated static func encodeJPEG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw SystemWallpaperSyncError(ruKey: "Не удалось подготовить статичный кадр системных обоев.")
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw SystemWallpaperSyncError(ruKey: "Не удалось подготовить статичный кадр системных обоев.")
        }
        return data as Data
    }
}

@MainActor
final class SystemWallpaperDesktopAdapter: SystemWallpaperDesktopAdapting {
    var screens: [SystemWallpaperScreen] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
                return nil
            }
            return SystemWallpaperScreen(id: id, name: screen.localizedName)
        }
    }

    func matches(imageURL: URL, options: SystemWallpaperOptions, screen: SystemWallpaperScreen) -> Bool {
        guard let native = nativeScreen(screen),
              NSWorkspace.shared.desktopImageURL(for: native)?.standardizedFileURL == imageURL.standardizedFileURL,
              let current = NSWorkspace.shared.desktopImageOptions(for: native),
              (current[.imageScaling] as? NSNumber)?.uintValue == options.imageScaling.rawValue,
              (current[.allowClipping] as? NSNumber)?.boolValue == options.allowClipping,
              let color = (current[.fillColor] as? NSColor)?.usingColorSpace(.extendedSRGB) else { return false }
        return abs(color.redComponent) < 0.0001 && abs(color.greenComponent) < 0.0001
            && abs(color.blueComponent) < 0.0001 && abs(color.alphaComponent - 1) < 0.0001
    }

    func apply(imageURL: URL, options: SystemWallpaperOptions, screen: SystemWallpaperScreen) throws {
        guard let native = nativeScreen(screen) else { throw CocoaError(.fileNoSuchFile) }
        try NSWorkspace.shared.setDesktopImageURL(imageURL, for: native, options: [
            .imageScaling: options.imageScaling.rawValue,
            .allowClipping: options.allowClipping,
            .fillColor: options.fillColor
        ])
    }

    private func nativeScreen(_ screen: SystemWallpaperScreen) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == screen.id
        }
    }
}

private enum SystemWallpaperImageStore {
    /// Files are immutable and deliberately never pruned: other Spaces or
    /// disconnected displays may still refer to any previously published URL.
    static func publish(_ data: Data, name: String, at storeURL: URL) throws -> URL {
        do {
            try Task.checkCancellation()
            guard storeURL.isFileURL, storeURL.query == nil, storeURL.fragment == nil,
                  storeURL.host == nil || storeURL.host == "" || storeURL.host == "localhost",
                  !storeURL.pathComponents.contains(".."), !storeURL.pathComponents.contains(".") else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            var hasher = SHA256()
            hasher.update(data: data)
            hasher.update(data: Data([0]))
            hasher.update(data: Data(name.utf8))
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            // Put the hash in the directory so the native wallpaper label is
            // the friendly filename, while a changed frame gets a fresh URL.
            let filename = friendlyName(name) + ".jpg"
            let directory = try openDirectoryTree(storeURL)
            defer { close(directory) }
            let contentDirectory = try openChildDirectory(digest, parent: directory)
            defer { close(contentDirectory) }
            let result = storeURL.appendingPathComponent(digest, isDirectory: true).appendingPathComponent(filename)
            try Task.checkCancellation()
            if try existingFileMatches(filename, directory: contentDirectory, data: data) { return result }

            let temporaryName = ".pending-\(UUID().uuidString)"
            let file = openat(contentDirectory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw posixError() }
            defer {
                close(file)
                unlinkat(contentDirectory, temporaryName, 0)
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let count = write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw posixError() }
                    offset += count
                }
            }
            guard fsync(file) == 0 else { throw posixError() }
            try Task.checkCancellation()
            if renameatx_np(contentDirectory, temporaryName, contentDirectory, filename, UInt32(RENAME_EXCL)) != 0 {
                guard errno == EEXIST else { throw posixError() }
                guard try existingFileMatches(filename, directory: contentDirectory, data: data) else {
                    throw CocoaError(.fileWriteFileExists)
                }
            }
            guard fsync(contentDirectory) == 0, fsync(directory) == 0 else { throw posixError() }
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SystemWallpaperSyncError(ruKey: "Не удалось сохранить статичный кадр системных обоев.",
                                           detail: error.localizedDescription)
        }
    }

    private static func friendlyName(_ name: String) -> String {
        let stem = name.precomposedStringWithCanonicalMapping
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = stem.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var result = ""
        for character in cleaned {
            guard result.utf8.count + String(character).utf8.count <= 180 else { break }
            result.append(character)
        }
        return result.isEmpty ? "MyWallpaper" : result
    }

    private static func openDirectoryTree(_ url: URL) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        do {
            let components = url.standardizedFileURL.pathComponents.dropFirst()
            guard !components.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
            for (index, component) in components.enumerated() {
                try Task.checkCancellation()
                let child = try openChildDirectory(component, parent: descriptor,
                                                   allowSystemAlias: index < components.count - 1)
                close(descriptor)
                descriptor = child
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func openChildDirectory(_ name: String, parent: Int32, allowSystemAlias: Bool = false) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw posixError() }
        var child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if child < 0 && allowSystemAlias {
            // macOS /var and /tmp are root-owned aliases. Only aliases in a
            // root-owned, non-writable directory are trusted; user symlinks,
            // the store itself and content directories are never followed.
            var linkInfo = stat()
            var parentInfo = stat()
            if fstatat(parent, name, &linkInfo, AT_SYMLINK_NOFOLLOW) == 0,
               fstat(parent, &parentInfo) == 0,
               linkInfo.st_mode & S_IFMT == S_IFLNK, linkInfo.st_uid == 0,
               parentInfo.st_uid == 0, parentInfo.st_mode & 0o022 == 0 {
                child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            }
        }
        guard child >= 0 else { throw posixError() }
        return child
    }

    private static func existingFileMatches(_ name: String, directory: Int32, data: Data) throws -> Bool {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0 && errno == ENOENT { return false }
        guard file >= 0 else { throw posixError() }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == data.count else { throw CocoaError(.fileReadCorruptFile) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        guard try handle.readToEnd() == data else { throw CocoaError(.fileReadCorruptFile) }
        return true
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
