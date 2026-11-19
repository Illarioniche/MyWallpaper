import AppKit

/// One drawing supplies the app bundle, in-app branding and runtime app icon.
@MainActor
enum AppIconArtwork {
    static func image(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        for scale in [1, 2] {
            image.addRepresentation(bitmap(size: size, scale: scale, coordinateSize: 1_024, draw: drawLandscape))
        }
        image.accessibilityDescription = "MyWallpaper"
        return image
    }

    static func menuBarImage(hasUpdate: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for scale in [1, 2] {
            image.addRepresentation(bitmap(size: 18, scale: scale, coordinateSize: 18) {
                drawMenuBarMark()
                if hasUpdate {
                    // Keep the status item compact so the update badge does not need extra menu-bar space.
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current?.compositingOperation = .clear
                    NSBezierPath(ovalIn: NSRect(x: 11, y: 11, width: 7, height: 7)).fill()
                    NSGraphicsContext.restoreGraphicsState()
                    NSColor.black.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 12.5, y: 12.5, width: 4, height: 4)).fill()
                }
            })
        }
        image.isTemplate = true
        image.accessibilityDescription = hasUpdate ? "MyWallpaper — доступно обновление" : "MyWallpaper"
        return image
    }

    private static func bitmap(size: CGFloat, scale: Int, coordinateSize: CGFloat,
                               draw: () -> Void) -> NSBitmapImageRep {
        let pixels = max(1, Int((size * CGFloat(scale)).rounded(.up)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            preconditionFailure("Unable to create the app icon bitmap.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / coordinateSize)
        transform.concat()
        draw()
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: size, height: size)
        return bitmap
    }

    private static func drawLandscape() {
        let canvas = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                                  xRadius: 204, yRadius: 204)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
        shadow.shadowBlurRadius = 23
        shadow.shadowOffset = NSSize(width: 0, height: -9)
        shadow.set()
        color(0.025, 0.10, 0.19).setFill()
        canvas.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        canvas.addClip()
        NSGradient(colors: [color(0.025, 0.13, 0.25), color(0.07, 0.30, 0.45), color(0.22, 0.57, 0.64)])!
            .draw(in: canvas, angle: 68)

        let glow = NSBezierPath(ovalIn: NSRect(x: 681, y: 696, width: 154, height: 154))
        color(0.79, 0.99, 0.94, 0.06).setFill()
        glow.fill()
        let moon = NSBezierPath(ovalIn: NSRect(x: 708, y: 723, width: 100, height: 100))
        NSGradient(starting: color(0.77, 0.96, 0.91), ending: color(0.94, 1.0, 0.95))!
            .draw(in: moon, angle: 90)

        let distant = NSBezierPath()
        distant.move(to: NSPoint(x: 0, y: 477))
        distant.curve(to: NSPoint(x: 373, y: 604), controlPoint1: NSPoint(x: 143, y: 499), controlPoint2: NSPoint(x: 231, y: 663))
        distant.curve(to: NSPoint(x: 677, y: 556), controlPoint1: NSPoint(x: 463, y: 556), controlPoint2: NSPoint(x: 547, y: 495))
        distant.curve(to: NSPoint(x: 1_024, y: 658), controlPoint1: NSPoint(x: 814, y: 621), controlPoint2: NSPoint(x: 927, y: 697))
        finishWave(distant)
        NSGradient(starting: color(0.035, 0.32, 0.43), ending: color(0.30, 0.80, 0.75))!
            .draw(in: distant, angle: 85)

        let middle = NSBezierPath()
        middle.move(to: NSPoint(x: 0, y: 353))
        middle.curve(to: NSPoint(x: 388, y: 465), controlPoint1: NSPoint(x: 119, y: 471), controlPoint2: NSPoint(x: 256, y: 494))
        middle.curve(to: NSPoint(x: 733, y: 434), controlPoint1: NSPoint(x: 528, y: 435), controlPoint2: NSPoint(x: 594, y: 379))
        middle.curve(to: NSPoint(x: 1_024, y: 523), controlPoint1: NSPoint(x: 851, y: 488), controlPoint2: NSPoint(x: 953, y: 558))
        finishWave(middle)
        NSGradient(starting: color(0.015, 0.30, 0.42), ending: color(0.04, 0.66, 0.63))!
            .draw(in: middle, angle: 95)

        let near = NSBezierPath()
        near.move(to: NSPoint(x: 0, y: 284))
        near.curve(to: NSPoint(x: 423, y: 273), controlPoint1: NSPoint(x: 155, y: 358), controlPoint2: NSPoint(x: 274, y: 281))
        near.curve(to: NSPoint(x: 752, y: 351), controlPoint1: NSPoint(x: 547, y: 266), controlPoint2: NSPoint(x: 636, y: 322))
        near.curve(to: NSPoint(x: 1_024, y: 318), controlPoint1: NSPoint(x: 871, y: 382), controlPoint2: NSPoint(x: 948, y: 384))
        finishWave(near)
        NSGradient(starting: color(0.025, 0.17, 0.34), ending: color(0.065, 0.46, 0.61))!
            .draw(in: near, angle: 95)

        let foreground = NSBezierPath()
        foreground.move(to: NSPoint(x: 0, y: 147))
        foreground.curve(to: NSPoint(x: 480, y: 168), controlPoint1: NSPoint(x: 171, y: 223), controlPoint2: NSPoint(x: 309, y: 122))
        foreground.curve(to: NSPoint(x: 1_024, y: 203), controlPoint1: NSPoint(x: 728, y: 239), controlPoint2: NSPoint(x: 821, y: 268))
        finishWave(foreground)
        NSGradient(starting: color(0.018, 0.085, 0.19), ending: color(0.035, 0.25, 0.38))!
            .draw(in: foreground, angle: 90)

        // A quiet play marker, secondary to the landscape even at larger sizes.
        let badge = NSBezierPath(ovalIn: NSRect(x: 659, y: 286, width: 158, height: 158))
        color(0.89, 1.0, 0.98, 0.16).setFill()
        badge.fill()
        color(0.91, 1.0, 1.0, 0.27).setStroke()
        badge.lineWidth = 2
        badge.stroke()
        let play = NSBezierPath()
        play.move(to: NSPoint(x: 718, y: 329))
        play.line(to: NSPoint(x: 718, y: 401))
        play.curve(to: NSPoint(x: 729, y: 407), controlPoint1: NSPoint(x: 718, y: 408), controlPoint2: NSPoint(x: 723, y: 410))
        play.line(to: NSPoint(x: 779, y: 373))
        play.curve(to: NSPoint(x: 779, y: 358), controlPoint1: NSPoint(x: 786, y: 368), controlPoint2: NSPoint(x: 786, y: 363))
        play.line(to: NSPoint(x: 729, y: 323))
        play.curve(to: NSPoint(x: 718, y: 329), controlPoint1: NSPoint(x: 723, y: 319), controlPoint2: NSPoint(x: 718, y: 322))
        play.close()
        color(0.92, 1.0, 0.98, 0.96).setFill()
        play.fill()

        let rim = NSBezierPath(roundedRect: NSRect(x: 65, y: 65, width: 894, height: 894), xRadius: 203, yRadius: 203)
        NSColor.white.withAlphaComponent(0.16).setStroke()
        rim.lineWidth = 2
        rim.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func finishWave(_ path: NSBezierPath) {
        path.line(to: NSPoint(x: 1_024, y: 0))
        path.line(to: .zero)
        path.close()
    }

    private static func drawMenuBarMark() {
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let frame = NSBezierPath(roundedRect: NSRect(x: 1, y: 2.5, width: 16, height: 13), xRadius: 2.3, yRadius: 2.3)
        frame.lineWidth = 1.35
        frame.stroke()
        NSBezierPath(ovalIn: NSRect(x: 3.4, y: 10.4, width: 2.1, height: 2.1)).fill()
        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: 2.5, y: 5.1))
        wave.curve(to: NSPoint(x: 7.0, y: 7.2), controlPoint1: NSPoint(x: 3.7, y: 5.5), controlPoint2: NSPoint(x: 5.3, y: 8.7))
        wave.curve(to: NSPoint(x: 9.6, y: 5.7), controlPoint1: NSPoint(x: 7.8, y: 6.5), controlPoint2: NSPoint(x: 8.6, y: 5.8))
        wave.lineWidth = 1.25
        wave.lineCapStyle = .round
        wave.stroke()
        let play = NSBezierPath()
        play.move(to: NSPoint(x: 11, y: 6.0))
        play.line(to: NSPoint(x: 11, y: 11.5))
        play.line(to: NSPoint(x: 15, y: 8.75))
        play.close()
        play.fill()
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
