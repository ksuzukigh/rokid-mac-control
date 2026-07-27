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
    }
}
