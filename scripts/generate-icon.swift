import AppKit
import ImageIO

// A small vector illustration, rasterized at Apple's standard app icon sizes.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func drawIcon(pixels: Int, filename: String) throws {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()

    let canvas = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 205, yRadius: 205)
    canvas.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.08, green: 0.10, blue: 0.24, alpha: 1),
        NSColor(srgbRed: 0.17, green: 0.31, blue: 0.53, alpha: 1),
        NSColor(srgbRed: 0.33, green: 0.66, blue: 0.72, alpha: 1)
    ])!.draw(in: canvas, angle: 65)

    let moon = NSBezierPath(ovalIn: NSRect(x: 658, y: 636, width: 136, height: 136))
    NSColor(srgbRed: 0.85, green: 0.98, blue: 0.93, alpha: 0.94).setFill()
    moon.fill()

    let back = NSBezierPath()
    back.move(to: NSPoint(x: 30, y: 300))
    back.curve(to: NSPoint(x: 483, y: 529), controlPoint1: NSPoint(x: 201, y: 330), controlPoint2: NSPoint(x: 310, y: 620))
    back.curve(to: NSPoint(x: 990, y: 458), controlPoint1: NSPoint(x: 670, y: 437), controlPoint2: NSPoint(x: 827, y: 550))
    back.line(to: NSPoint(x: 990, y: 0))
    back.line(to: NSPoint(x: 30, y: 0))
    back.close()
    NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.68, blue: 0.62, alpha: 1), ending: NSColor(srgbRed: 0.10, green: 0.39, blue: 0.49, alpha: 1))!.draw(in: back, angle: 110)

    let front = NSBezierPath()
    front.move(to: NSPoint(x: 20, y: 250))
    front.curve(to: NSPoint(x: 556, y: 310), controlPoint1: NSPoint(x: 206, y: 430), controlPoint2: NSPoint(x: 367, y: 190))
    front.curve(to: NSPoint(x: 996, y: 364), controlPoint1: NSPoint(x: 710, y: 420), controlPoint2: NSPoint(x: 871, y: 440))
    front.line(to: NSPoint(x: 996, y: 0))
    front.line(to: NSPoint(x: 20, y: 0))
    front.close()
    NSGradient(starting: NSColor(srgbRed: 0.05, green: 0.15, blue: 0.28, alpha: 1), ending: NSColor(srgbRed: 0.10, green: 0.35, blue: 0.43, alpha: 1))!.draw(in: front, angle: 85)

    let play = NSBezierPath()
    play.move(to: NSPoint(x: 420, y: 393))
    play.line(to: NSPoint(x: 420, y: 628))
    play.curve(to: NSPoint(x: 447, y: 642), controlPoint1: NSPoint(x: 420, y: 643), controlPoint2: NSPoint(x: 435, y: 650))
    play.line(to: NSPoint(x: 625, y: 527))
    play.curve(to: NSPoint(x: 625, y: 497), controlPoint1: NSPoint(x: 639, y: 519), controlPoint2: NSPoint(x: 639, y: 505))
    play.line(to: NSPoint(x: 447, y: 380))
    play.curve(to: NSPoint(x: 420, y: 393), controlPoint1: NSPoint(x: 435, y: 373), controlPoint2: NSPoint(x: 420, y: 379))
    play.close()
    NSColor.white.withAlphaComponent(0.96).setFill()
    play.fill()

    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    try png.write(to: directory.appendingPathComponent(filename))
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: size, filename: "icon_\(size)x\(size).png")
    try drawIcon(pixels: size * 2, filename: "icon_\(size)x\(size)@2x.png")
}

// ImageIO writes the ICNS container directly, without requiring Xcode assets.
if CommandLine.arguments.count > 2 {
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.apple.icns" as CFString, 10, nil) else {
        fatalError("Не удалось создать файл иконки: \(output.path)")
    }
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
            let url = directory.appendingPathComponent(filename)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                fatalError("Не удалось прочитать изображение: \(url.path)")
            }
            let properties = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        }
    }
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Не удалось записать файл иконки: \(output.path)")
    }
}
