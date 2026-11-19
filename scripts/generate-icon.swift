import AppKit
import ImageIO

@main
@MainActor
enum IconGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 3 || CommandLine.arguments.count == 4 else {
            throw GenerationFailure(message: "Usage: generate-icon <iconset-directory> <output.icns> [preview.png]")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let preview = CommandLine.arguments.count == 4
            ? URL(fileURLWithPath: CommandLine.arguments[3])
            : directory.deletingLastPathComponent().appendingPathComponent("app-icon-preview1024.png")
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, "com.apple.icns" as CFString, 10, nil
        ) else {
            throw GenerationFailure(message: "Не удалось создать файл иконки: \(output.path)")
        }

        for size in [16, 32, 128, 256, 512] {
            let artwork = AppIconArtwork.image(size: CGFloat(size))
            for scale in [1, 2] {
                let pixels = size * scale
                guard let bitmap = artwork.representations.compactMap({ $0 as? NSBitmapImageRep })
                    .first(where: { $0.pixelsWide == pixels && $0.pixelsHigh == pixels }),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw GenerationFailure(message: "Не удалось отрисовать иконку \(pixels) × \(pixels).")
                }
                let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
                let file = directory.appendingPathComponent(filename)
                try png.write(to: file)
                if size == 512 && scale == 2 { try png.write(to: preview) }

                guard let source = CGImageSourceCreateWithData(png as CFData, nil) else {
                    throw GenerationFailure(message: "Не удалось подготовить изображение: \(filename)")
                }
                let properties = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
                CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else {
            throw GenerationFailure(message: "Не удалось записать файл иконки: \(output.path)")
        }
        print("Icon preview: \(preview.path)")
    }
}

private struct GenerationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
