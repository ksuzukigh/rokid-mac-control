import AppKit
import CoreImage
import Foundation

@main
enum VisionCompositorSelfTest {
    static func main() throws {
        let size = NSSize(width: 480, height: 640)
        guard
            let camera = makeCameraImage(size: size),
            let hud = makeHUDImage(size: size)
        else {
            throw TestError.imageCreation
        }

        let compositor = VisionFrameCompositor(hudVisibility: 0.8)
        guard let result = compositor.compose(
            cameraImage: CIImage(cgImage: camera),
            hudImage: CIImage(cgImage: hud)
        ) else {
            throw TestError.composition
        }
        try verify(result, expectedSize: CGSize(width: 480, height: 640))

        let alternateCompositor = VisionFrameCompositor(
            outputSize: CGSize(width: 320, height: 240),
            hudVisibility: 0.8
        )
        guard let alternate = alternateCompositor.compose(
            cameraImage: CIImage(cgImage: camera),
            hudImage: CIImage(cgImage: hud)
        ) else {
            throw TestError.composition
        }
        try verify(
            alternate,
            expectedSize: CGSize(width: 320, height: 240)
        )

        let output = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst().first
                ?? "vision-compositor-self-test.png"
        )
        let representation = NSBitmapImageRep(cgImage: result)
        guard let data = representation.representation(
            using: .png,
            properties: [:]
        ) else {
            throw TestError.encoding
        }
        try data.write(to: output, options: .atomic)
        print(output.path)
    }

    private static func verify(
        _ image: CGImage,
        expectedSize: CGSize
    ) throws {
        guard image.width == Int(expectedSize.width),
              image.height == Int(expectedSize.height)
        else {
            throw TestError.unexpectedSize(image.width, image.height)
        }

        let bytesPerPixel = 4
        let rowBytes = image.width * bytesPerPixel
        var pixels = [UInt8](
            repeating: 0,
            count: rowBytes * image.height
        )
        let context = CIContext(options: [.cacheIntermediates: false])
        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(
                CIImage(cgImage: image),
                toBitmap: baseAddress,
                rowBytes: rowBytes,
                bounds: CGRect(
                    x: 0,
                    y: 0,
                    width: image.width,
                    height: image.height
                ),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }

        var visiblePixels = 0
        var greenHUDPixels = 0
        for index in stride(
            from: 0,
            to: pixels.count,
            by: bytesPerPixel
        ) {
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            if max(red, green, blue) >= 24 {
                visiblePixels += 1
            }
            if green >= 96, green > red + 24, green > blue + 24 {
                greenHUDPixels += 1
            }
        }

        let totalPixels = image.width * image.height
        guard visiblePixels > totalPixels / 2 else {
            throw TestError.outputTooDark(visiblePixels)
        }
        guard greenHUDPixels > max(totalPixels / 1_000, 100) else {
            throw TestError.hudMissing(greenHUDPixels)
        }
    }

    private static func makeCameraImage(size: NSSize) -> CGImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        let bounds = NSRect(origin: .zero, size: size)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.38, alpha: 1),
            NSColor(calibratedRed: 0.78, green: 0.42, blue: 0.16, alpha: 1),
        ])?.draw(in: bounds, angle: 90)
        NSColor(calibratedRed: 0.16, green: 0.48, blue: 0.22, alpha: 1)
            .setFill()
        NSBezierPath(
            rect: NSRect(x: 0, y: 0, width: 480, height: 180)
        ).fill()
        NSColor(calibratedWhite: 0.8, alpha: 1).setFill()
        NSBezierPath(
            ovalIn: NSRect(x: 170, y: 235, width: 140, height: 180)
        ).fill()
        image.unlockFocus()
        var rect = bounds
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func makeHUDImage(size: NSSize) -> CGImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        let bounds = NSRect(origin: .zero, size: size)
        NSColor.black.setFill()
        bounds.fill()

        let green = NSColor(
            calibratedRed: 0.16,
            green: 1,
            blue: 0.14,
            alpha: 1
        )
        green.setStroke()
        green.setFill()

        let frame = NSBezierPath(
            rect: NSRect(x: 18, y: 18, width: 444, height: 604)
        )
        frame.lineWidth = 3
        frame.stroke()
        let target = NSBezierPath(
            ovalIn: NSRect(x: 170, y: 250, width: 140, height: 140)
        )
        target.lineWidth = 4
        target.stroke()

        let horizontal = NSBezierPath()
        horizontal.move(to: NSPoint(x: 130, y: 320))
        horizontal.line(to: NSPoint(x: 350, y: 320))
        horizontal.lineWidth = 3
        horizontal.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .bold),
            .foregroundColor: green,
        ]
        "TARGET LOCK".draw(
            at: NSPoint(x: 32, y: 570),
            withAttributes: attributes
        )
        "POWER 9001".draw(
            at: NSPoint(x: 280, y: 60),
            withAttributes: attributes
        )

        image.unlockFocus()
        var rect = bounds
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    enum TestError: Error {
        case imageCreation
        case composition
        case encoding
        case unexpectedSize(Int, Int)
        case outputTooDark(Int)
        case hudMissing(Int)
    }
}
