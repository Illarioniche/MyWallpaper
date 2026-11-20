import Darwin
import Foundation
import ImageIO

struct ScreenSaverExportOptions: Codable, Sendable, Equatable {
    enum Scaling: String, Codable, Sendable { case fill, fit }

    var scaling: Scaling = .fill
    var animateOnBattery = false
    var animateOnExternalPower = true
    var pauseInLowPowerMode = true
}

struct ScreenSaverExportError: Error, Sendable {
    /// The caller translates this key; external diagnostics remain separate.
    let ruKey: String
    let detail: String?

    init(ruKey: String, detail: String? = nil) {
        self.ruKey = ruKey
        self.detail = detail
    }
}

enum ScreenSaverExporter {
    typealias Signer = @Sendable (URL) throws -> Void

    /// Run off the main actor. Only the final, verified bundle becomes visible
    /// at destinationURL; an existing file or symlink is never overwritten.
    @discardableResult
    static func export(videoURL: URL, posterJPEG: Data, templateURL: URL, destinationURL: URL,
                       options: ScreenSaverExportOptions = .init(),
                       identity: ScreenSaverInstallationIdentity? = nil,
                       signer: Signer = signAndVerify) throws -> URL {
        let manager = FileManager.default
        var temporaryRoot: URL?
        defer { if let temporaryRoot { try? manager.removeItem(at: temporaryRoot) } }

        do {
            try Task.checkCancellation()
            try validateLocalURL(videoURL)
            try validateLocalURL(templateURL)
            try validateLocalURL(destinationURL)
            let videoExtension = videoURL.pathExtension.lowercased()
            guard ["mp4", "mov"].contains(videoExtension), try isRegularFile(videoURL),
                  (try manager.attributesOfItem(atPath: videoURL.path)[.size] as? NSNumber)?.uint64Value ?? 0 > 0 else {
                throw ScreenSaverExportError(ruKey: "Для заставки выбери локальное видео MP4 или MOV.")
            }
            guard destinationURL.pathExtension.lowercased() == "saver" else {
                throw ScreenSaverExportError(ruKey: "Сохрани заставку с расширением .saver.")
            }
            guard !entryExists(destinationURL) else { throw destinationExists() }
            let parent = destinationURL.deletingLastPathComponent()
            guard try isDirectory(parent) else {
                throw ScreenSaverExportError(ruKey: "Папка для экспорта заставки недоступна.")
            }
            try validateTemplate(templateURL)
            // Staging inside the template would recursively copy itself and
            // would modify a source that this operation promises to preserve.
            let templatePath = templateURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard !parentPath.starts(with: templatePath) else {
                throw ScreenSaverExportError(ruKey: "Выбери папку за пределами шаблона заставки.")
            }
            guard !posterJPEG.isEmpty, posterJPEG.count <= 32 * 1_024 * 1_024,
                  let imageSource = CGImageSourceCreateWithData(posterJPEG as CFData, nil),
                  CGImageSourceGetType(imageSource) as String? == "public.jpeg",
                  CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil else {
                throw ScreenSaverExportError(ruKey: "Не удалось подготовить неподвижный кадр заставки.")
            }

            let root = parent.appendingPathComponent(".MyWallpaper-export-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: root, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            temporaryRoot = root
            let staged = root.appendingPathComponent("MyWallpaper.saver", isDirectory: true)
            try manager.copyItem(at: templateURL, to: staged)
            try Task.checkCancellation()

            let resources = staged.appendingPathComponent("Contents/Resources", isDirectory: true)
            if !entryExists(resources) {
                try manager.createDirectory(at: resources, withIntermediateDirectories: false)
            }
            // A saved record may serve as its own runtime template. Replace
            // only the fixed export resources in the private staging copy.
            for oldResource in ["video.mp4", "video.mov", "poster.jpg", "configuration.json", "thumbnail.png", "thumbnail@2x.png"] {
                let oldURL = resources.appendingPathComponent(oldResource)
                if entryExists(oldURL) { try manager.removeItem(at: oldURL) }
            }
            let filename = "video.\(videoExtension)"
            try manager.copyItem(at: videoURL, to: resources.appendingPathComponent(filename))
            try posterJPEG.write(to: resources.appendingPathComponent("poster.jpg"), options: .atomic)
            // The system picker uses these conventional resource names. Keep
            // the original poster for playback, and sign both previews with it.
            try writeThumbnail(from: imageSource, maximumPixelSize: 640,
                               to: resources.appendingPathComponent("thumbnail.png"))
            try writeThumbnail(from: imageSource, maximumPixelSize: 1_280,
                               to: resources.appendingPathComponent("thumbnail@2x.png"))
            let configuration = Configuration(version: 1, videoFileName: filename,
                                              scaling: options.scaling, animateOnBattery: options.animateOnBattery,
                                              animateOnExternalPower: options.animateOnExternalPower,
                                              pauseInLowPowerMode: options.pauseInLowPowerMode)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: resources.appendingPathComponent("configuration.json"), options: .atomic)
            if let identity { try personalize(staged, identity: identity) }
            try Task.checkCancellation()
            try validateTemplate(staged, identity: identity)
            try signer(staged)
            try Task.checkCancellation()
            try validateTemplate(staged, identity: identity)

            // RENAME_EXCL makes the no-overwrite promise atomic, including a
            // competing export creating destinationURL after the initial check.
            guard renamex_np(staged.path, destinationURL.path, UInt32(RENAME_EXCL)) == 0 else {
                let code = errno
                if code == EEXIST { throw destinationExists() }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            return destinationURL
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ScreenSaverExportError {
            throw error
        } catch {
            throw ScreenSaverExportError(ruKey: "Не удалось экспортировать заставку.", detail: error.localizedDescription)
        }
    }

    static func signAndVerify(_ bundleURL: URL) throws {
        for arguments in [["--force", "--sign", "-", bundleURL.path],
                          ["--verify", "--strict", bundleURL.path]] {
            try Task.checkCancellation()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            do { try process.run() }
            catch {
                throw ScreenSaverExportError(ruKey: "Не удалось подписать заставку.", detail: error.localizedDescription)
            }
            // Drain the pipe while the child runs, so diagnostics cannot fill
            // its pipe buffer and deadlock waitUntilExit().
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                let detail = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ScreenSaverExportError(ruKey: "Не удалось подписать или проверить заставку.",
                                             detail: String(detail.prefix(2_000)))
            }
        }
    }

    private static func writeThumbnail(from source: CGImageSource, maximumPixelSize: Int, to url: URL) throws {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        let data = NSMutableData()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ScreenSaverExportError(ruKey: "Не удалось подготовить неподвижный кадр заставки.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenSaverExportError(ruKey: "Не удалось подготовить неподвижный кадр заставки.")
        }
        try (data as Data).write(to: url, options: .atomic)
    }

    private static func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"),
              url.host == nil || url.host == "" || url.host == "localhost",
              !url.pathComponents.contains(".."), !url.pathComponents.contains("."),
              url.query == nil, url.fragment == nil else {
            throw ScreenSaverExportError(ruKey: "Для экспорта нужны обычные локальные файлы и папки.")
        }
    }

    private static func personalize(_ bundle: URL, identity: ScreenSaverInstallationIdentity) throws {
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              info["MyWallpaperRuntimeVersion"] as? Int == 2 else { throw invalidTemplate() }
        info["CFBundleIdentifier"] = identity.bundleIdentifier
        info["NSPrincipalClass"] = identity.principalClass
        info["CFBundleName"] = identity.name
        info["CFBundleDisplayName"] = identity.name
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL, options: .atomic)
    }

    private static func validateTemplate(_ url: URL, identity: ScreenSaverInstallationIdentity? = nil) throws {
        let manager = FileManager.default
        guard url.pathExtension.lowercased() == "saver", try isDirectory(url) else { throw invalidTemplate() }
        var enumerationError: Error?
        guard let files = manager.enumerator(at: url, includingPropertiesForKeys: nil, errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw invalidTemplate() }
        for case let item as URL in files {
            let type = try manager.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory else { throw invalidTemplate() }
        }
        if let enumerationError { throw enumerationError }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard try isRegularFile(infoURL),
              let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              info["CFBundlePackageType"] as? String == "BNDL",
              info["CFBundleIdentifier"] as? String == (identity?.bundleIdentifier ?? "app.mywallpaper.screensaver"),
              info["NSPrincipalClass"] as? String == (identity?.principalClass ?? "MyWallpaperScreenSaverView"),
              info["CFBundleExecutable"] as? String == "MyWallpaperScreenSaver",
              try isRegularFile(url.appendingPathComponent("Contents/MacOS/MyWallpaperScreenSaver")) else {
            throw invalidTemplate()
        }
        let resources = url.appendingPathComponent("Contents/Resources")
        if entryExists(resources), try !isDirectory(resources) { throw invalidTemplate() }
    }

    private static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isRegularFile(_ url: URL) throws -> Bool {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular
    }

    private static func isDirectory(_ url: URL) throws -> Bool {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory
    }

    private static func invalidTemplate() -> ScreenSaverExportError {
        ScreenSaverExportError(ruKey: "Шаблон заставки повреждён или отсутствует. Переустанови MyWallpaper.")
    }

    private static func destinationExists() -> ScreenSaverExportError {
        ScreenSaverExportError(ruKey: "В этой папке уже есть файл заставки. Выбери другую папку.")
    }

    private struct Configuration: Codable {
        let version: Int
        let videoFileName: String
        let scaling: ScreenSaverExportOptions.Scaling
        let animateOnBattery: Bool
        let animateOnExternalPower: Bool
        let pauseInLowPowerMode: Bool
    }
}
