import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// Original, reproducible artwork for documentation screenshots. No GUI or external assets.
@main
enum DemoVideoGenerator {
    static func main() async {
        do { try await generate() }
        catch {
            FileHandle.standardError.write(Data("Demo generation failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func generate() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw DemoFailure(message: "Usage: generate-demo-video <output-directory>")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let movie = directory.appendingPathComponent("Aurora.mp4")
        let image = try AuroraArtwork.makeImage()
        let preview = directory.appendingPathComponent("Aurora.png")
        try writePNG(image, to: preview)
        print("Artwork preview: \(preview.path)")
        try await writeVideo(image, to: movie)

        // Validate the actual encoded file and preview the frame the app will receive.
        let asset = AVURLAsset(url: movie)
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        guard playable, abs(duration.seconds - 2) < 0.1 else {
            throw DemoFailure(message: "Generated movie failed playback/duration validation.")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let poster = try await generator.image(at: .zero).image
        try writePNG(poster, to: preview)
        print("Video: \(movie.path)")
        print("Preview: \(preview.path)")
        print("Validated: \(poster.width)×\(poster.height), 2 seconds, silent H.264")
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw DemoFailure(message: "Cannot create the video preview.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DemoFailure(message: "Cannot save the video preview.")
        }
    }

    private static func writeVideo(_ image: CGImage, to url: URL) async throws {
        // Replace only this generator's named output, never a directory or input asset.
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: image.width,
            AVVideoHeightKey: image.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: image.width,
            kCVPixelBufferHeightKey as String: image.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                          sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw DemoFailure(message: "Cannot configure H.264 output.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? DemoFailure(message: "Cannot start video encoding.") }
        writer.startSession(atSourceTime: .zero)

        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                        kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard result == kCVReturnSuccess, let buffer else {
            throw DemoFailure(message: "Cannot allocate the movie frame.")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width,
                                      height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                        | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            throw DemoFailure(message: "Cannot draw the movie frame.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        // The immutable frame is reused for a small, silent two-second sample.
        let deadline = Date().addingTimeInterval(30)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else {
                    writer.cancelWriting()
                    throw writer.error ?? DemoFailure(message: "Video encoding stalled.")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? DemoFailure(message: "Cannot encode frame \(frame).")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? DemoFailure(message: "Cannot finish the demo movie.")
        }
    }
}

private enum AuroraArtwork {
    private static let width = 1_600
    private static let height = 900

    static func makeImage() throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DemoFailure(message: "Cannot allocate the landscape canvas.")
        }
        context.setShouldAntialias(true)
        gradient([color(0x061B2C), color(0x164B5D), color(0x437F83)],
                 from: CGPoint(x: 800, y: 900), to: CGPoint(x: 800, y: 300), in: context)

        var random = SeededRandom()
        for index in 0..<95 {
            let x = 30 + random.next() * 1_540
            let y = 480 + random.next() * 390
            if hypot(x - 1_188, y - 704) < 115 { continue }
            let radius = 0.6 + random.next() * 1.4
            context.setFillColor(color(0xD8F6EF, alpha: 0.25 + random.next() * 0.5))
            context.fillEllipse(in: CGRect(x: x, y: y, width: radius * 2, height: radius * 2))
            if index % 24 == 0 {
                context.setStrokeColor(color(0xD8F6EF, alpha: 0.25))
                context.setLineWidth(0.8)
                context.move(to: CGPoint(x: x + radius - 5, y: y + radius))
                context.addLine(to: CGPoint(x: x + radius + 5, y: y + radius))
                context.move(to: CGPoint(x: x + radius, y: y + radius - 5))
                context.addLine(to: CGPoint(x: x + radius, y: y + radius + 5))
                context.strokePath()
            }
        }

        for index in 0..<3 {
            let offset = CGFloat(index) * 28
            let ribbon = CGMutablePath()
            ribbon.move(to: CGPoint(x: -100, y: 790 + offset))
            ribbon.addCurve(to: CGPoint(x: 820, y: 670 + offset),
                            control1: CGPoint(x: 320, y: 940 + offset), control2: CGPoint(x: 420, y: 600 + offset))
            ribbon.addCurve(to: CGPoint(x: 1_720, y: 820 + offset),
                            control1: CGPoint(x: 1_180, y: 720 + offset), control2: CGPoint(x: 1_360, y: 850 + offset))
            context.saveGState()
            context.setBlendMode(.screen)
            context.setShadow(offset: .zero, blur: 35, color: color(0x37DDB6, alpha: 0.3))
            context.setStrokeColor(color(index == 1 ? 0x62D6D0 : 0x57E9B7, alpha: 0.055))
            context.setLineWidth(index == 1 ? 44 : 24)
            context.addPath(ribbon)
            context.strokePath()
            context.restoreGState()
        }

        let moon = CGPoint(x: 1_188, y: 704)
        if let glow = CGGradient(colorsSpace: nil, colors: [color(0x9CF5DC, alpha: 0.22),
                                                           color(0x78D5D1, alpha: 0.045),
                                                           color(0x78D5D1, alpha: 0)] as CFArray,
                                 locations: [0, 0.45, 1]) {
            context.drawRadialGradient(glow, startCenter: moon, startRadius: 42,
                                       endCenter: moon, endRadius: 190, options: [])
        }
        context.saveGState()
        context.addEllipse(in: CGRect(x: moon.x - 57, y: moon.y - 57, width: 114, height: 114))
        context.clip()
        gradient([color(0xDEF9E7), color(0xA7DBD6)],
                 from: CGPoint(x: moon.x - 25, y: moon.y + 57),
                 to: CGPoint(x: moon.x + 30, y: moon.y - 57), in: context)
        context.setFillColor(color(0x6EA7B3, alpha: 0.065))
        context.fillEllipse(in: CGRect(x: moon.x + 8, y: moon.y - 23, width: 28, height: 30))
        context.fillEllipse(in: CGRect(x: moon.x - 30, y: moon.y + 12, width: 17, height: 15))
        context.restoreGState()

        mountains([(0, 444), (120, 480), (218, 456), (332, 544), (396, 518), (506, 644),
                   (555, 587), (606, 610), (744, 460), (844, 480), (947, 531), (1_024, 487),
                   (1_127, 573), (1_194, 526), (1_278, 553), (1_392, 624), (1_465, 570), (1_600, 482)],
                  base: 325, colors: [color(0x2D6572), color(0x315E67)], in: context)
        mountains([(0, 458), (84, 493), (168, 565), (240, 518), (304, 536), (414, 433),
                   (516, 402), (642, 445), (744, 385), (879, 407), (984, 462), (1_092, 428),
                   (1_196, 503), (1_284, 450), (1_420, 539), (1_503, 505), (1_600, 461)],
                  base: 315, colors: [color(0x174655), color(0x1D505B)], in: context)
        mountains([(0, 405), (78, 426), (172, 402), (276, 348), (399, 361), (510, 331),
                   (690, 341), (821, 326), (1_008, 343), (1_150, 365), (1_289, 407), (1_362, 422),
                   (1_475, 385), (1_600, 436)],
                  base: 300, colors: [color(0x103543), color(0x174550)], in: context)

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: width, height: 325))
        gradient([color(0x255C68), color(0x0F3448), color(0x092737)],
                 from: CGPoint(x: 800, y: 325), to: CGPoint(x: 800, y: 0), in: context)
        for index in 0..<38 {
            let y = 14 + CGFloat(index) * 7.9
            let distance = (325 - y) / 325
            let span = 10 + distance * 130 + random.next() * 15
            let center = moon.x + (random.next() - 0.5) * 35
            context.setStrokeColor(color(0xB4E7D9, alpha: 0.035 + (1 - distance) * 0.12))
            context.setLineWidth(1 + distance * 1.8)
            context.move(to: CGPoint(x: center - span, y: y))
            context.addLine(to: CGPoint(x: center + span, y: y))
            context.strokePath()
        }
        for _ in 0..<54 {
            let x = random.next() * 1_600
            let y = 20 + random.next() * 280
            context.setStrokeColor(color(0x69A7AC, alpha: 0.045))
            context.setLineWidth(1)
            context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x + 15 + random.next() * 85, y: y))
            context.strokePath()
        }
        context.restoreGState()

        mountains([(0, 167), (85, 193), (158, 180), (223, 137), (302, 110), (394, 44), (493, 0)],
                  base: 0, colors: [color(0x09232F), color(0x071E2B)], in: context)
        mountains([(1_280, 0), (1_348, 57), (1_416, 77), (1_491, 121), (1_600, 151)],
                  base: 0, colors: [color(0x0A2734), color(0x071E2B)], in: context)
        for (x, y, height) in [(43.0, 172.0, 122.0), (105.0, 181.0, 91.0),
                                (177.0, 160.0, 73.0), (1_533.0, 125.0, 80.0)] {
            pine(at: CGPoint(x: x, y: y), height: height, in: context)
        }

        guard let image = context.makeImage() else { throw DemoFailure(message: "Cannot finish the landscape.") }
        return image
    }

    private static func mountains(_ ridge: [(Double, Double)], base: CGFloat,
                                  colors: [CGColor], in context: CGContext) {
        guard let first = ridge.first, let last = ridge.last else { return }
        context.saveGState()
        context.move(to: CGPoint(x: first.0, y: base))
        for (x, y) in ridge { context.addLine(to: CGPoint(x: x, y: y)) }
        context.addLine(to: CGPoint(x: last.0, y: base))
        context.closePath()
        context.clip()
        gradient(colors, from: CGPoint(x: 0, y: ridge.map(\.1).max() ?? 0),
                 to: CGPoint(x: 0, y: base), in: context)
        context.restoreGState()
    }

    private static func pine(at base: CGPoint, height: CGFloat, in context: CGContext) {
        context.setFillColor(color(0x071F2B))
        context.fill(CGRect(x: base.x - 2, y: base.y, width: 4, height: height * 0.85))
        for tier in 0..<4 {
            let top = base.y + height * (1 - CGFloat(tier) * 0.17)
            let halfWidth = height * (0.10 + CGFloat(tier) * 0.045)
            context.move(to: CGPoint(x: base.x, y: top))
            context.addLine(to: CGPoint(x: base.x - halfWidth, y: top - height * 0.32))
            context.addLine(to: CGPoint(x: base.x + halfWidth, y: top - height * 0.32))
            context.closePath()
            context.fillPath()
        }
    }

    private static func gradient(_ colors: [CGColor], from start: CGPoint, to end: CGPoint, in context: CGContext) {
        guard let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil) else { return }
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: alpha)
    }
}

private struct SeededRandom {
    private var state: UInt64 = 0x4155524F5241
    mutating func next() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return CGFloat((state >> 32) & 0xFF_FFFF) / CGFloat(0xFF_FFFF)
    }
}

private struct DemoFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
