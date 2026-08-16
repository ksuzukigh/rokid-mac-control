import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit

enum VisionFrameKind {
    case camera
    case hud
}

enum VisionCompositionMode {
    case cameraWithHUD
    /// カメラアプリのプレビューを含むRokid画面を、そのままカラー表示する。
    case deviceScreen
}

enum VisionCaptureError: LocalizedError {
    case sourceWindowNotFound(String)
    case streamSetup(String)

    var errorDescription: String? {
        switch self {
        case .sourceWindowNotFound(let name):
            return "\(name)の受信画面を確認できませんでした。"
        case .streamSetup(let detail):
            return "映像合成を開始できませんでした。\(detail)"
        }
    }
}

final class VisionFrameCompositor {
    private let lock = NSLock()
    private let renderQueue = DispatchQueue(label: "RokidVision.Compositor")
    private let context = CIContext(options: [.cacheIntermediates: false])
    let outputSize: CGSize
    private let mode: VisionCompositionMode
    private var hudVisibility: CGFloat
    private var latestCamera: CVPixelBuffer?
    private var latestHUD: CVPixelBuffer?
    private var renderPending = false

    var onFrame: ((CGImage) -> Void)?

    init(
        outputSize: CGSize = CGSize(width: 480, height: 640),
        hudVisibility: Double = 0.55,
        mode: VisionCompositionMode = .cameraWithHUD
    ) {
        self.outputSize = CGSize(
            width: max(outputSize.width.rounded(), 1),
            height: max(outputSize.height.rounded(), 1)
        )
        self.mode = mode
        self.hudVisibility = CGFloat(min(max(hudVisibility, 0), 1))
    }

    func setHUDVisibility(_ value: Double) {
        lock.lock()
        hudVisibility = CGFloat(min(max(value, 0), 1))
        lock.unlock()
    }

    func receive(_ buffer: CVPixelBuffer, kind: VisionFrameKind) {
        lock.lock()
        switch kind {
        case .camera:
            latestCamera = buffer
        case .hud:
            latestHUD = buffer
        }
        let shouldSchedule = !renderPending
        if shouldSchedule {
            renderPending = true
        }
        lock.unlock()

        if shouldSchedule {
            renderQueue.async { [weak self] in
                self?.renderLatest()
            }
        }
    }

    private func renderLatest() {
        lock.lock()
        let cameraBuffer = latestCamera
        let hudBuffer = latestHUD
        let visibility = hudVisibility
        renderPending = false
        lock.unlock()

        let image: CGImage?
        switch mode {
        case .cameraWithHUD:
            guard let cameraBuffer, let hudBuffer else { return }
            image = compose(
                cameraImage: CIImage(cvPixelBuffer: cameraBuffer),
                hudImage: CIImage(cvPixelBuffer: hudBuffer),
                hudVisibility: visibility
            )
        case .deviceScreen:
            guard let hudBuffer else { return }
            image = renderDeviceScreen(
                CIImage(cvPixelBuffer: hudBuffer)
            )
        }
        guard let image else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(image)
        }
    }

    func compose(
        cameraImage: CIImage,
        hudImage: CIImage,
        hudVisibility: CGFloat? = nil
    ) -> CGImage? {
        let target = CGRect(origin: .zero, size: outputSize)
        let camera = aspectFill(cameraImage, into: target)
        let hud = aspectFill(hudImage, into: target)
        let visibility = min(max(hudVisibility ?? self.hudVisibility, 0), 1)
        let intensity = 1 + visibility * 11
        let thickness = visibility * 1.25
        var enhancedHUD = hud.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(
                    x: intensity, y: 0, z: 0, w: 0
                ),
                "inputGVector": CIVector(
                    x: 0, y: intensity, z: 0, w: 0
                ),
                "inputBVector": CIVector(
                    x: 0, y: 0, z: intensity, w: 0
                ),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]
        )
        if thickness > 0.01 {
            enhancedHUD = enhancedHUD.applyingFilter(
                "CIMorphologyMaximum",
                parameters: [kCIInputRadiusKey: thickness]
            )
        }

        // Black HUD pixels emit no light. Green and white pixels add light
        // over the camera image, matching the glasses' waveguide display.
        let composed = enhancedHUD
            .applyingFilter(
                "CIScreenBlendMode",
                parameters: [kCIInputBackgroundImageKey: camera]
            )
            .cropped(to: target)
        return context.createCGImage(composed, from: target)
    }

    func renderDeviceScreen(_ image: CIImage) -> CGImage? {
        let target = CGRect(origin: .zero, size: outputSize)
        let fitted = aspectFill(image, into: target).cropped(to: target)
        return context.createCGImage(fitted, from: target)
    }

    private func aspectFill(_ image: CIImage, into target: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let normalized = image.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )
        let scale = max(
            target.width / extent.width,
            target.height / extent.height
        )
        let scaled = normalized.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let scaledExtent = scaled.extent
        return scaled.transformed(
            by: CGAffineTransform(
                translationX: target.midX - scaledExtent.midX,
                y: target.midY - scaledExtent.midY
            )
        )
    }
}

final class VisionStreamReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    let kind: VisionFrameKind
    private let compositor: VisionFrameCompositor
    var onFailure: ((Error) -> Void)?

    init(kind: VisionFrameKind, compositor: VisionFrameCompositor) {
        self.kind = kind
        self.compositor = compositor
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let buffer = sampleBuffer.imageBuffer
        else {
            return
        }
        compositor.receive(buffer, kind: kind)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error)
    }
}

final class VisionCaptureCoordinator {
    private let compositor: VisionFrameCompositor
    private let captureQueue = DispatchQueue(label: "RokidVision.Capture")
    private var streams: [SCStream] = []
    private var receivers: [VisionStreamReceiver] = []

    var onFailure: ((Error) -> Void)?

    init(compositor: VisionFrameCompositor) {
        self.compositor = compositor
    }

    func start(
        hudPID: pid_t,
        cameraPID: pid_t? = nil,
        completion: @escaping (Error?) -> Void
    ) {
        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) { [weak self] content, error in
            guard let self else { return }
            if let error {
                completion(error)
                return
            }
            guard let content else {
                completion(VisionCaptureError.streamSetup("共有可能な画面がありません。"))
                return
            }

            do {
                guard let hudWindow = self.bestWindow(
                    for: hudPID,
                    in: content
                ) else {
                    throw VisionCaptureError.sourceWindowNotFound("HUD")
                }
                let hudStream = try self.makeStream(
                    window: hudWindow,
                    kind: .hud
                )
                if let cameraPID {
                    guard let cameraWindow = self.bestWindow(
                        for: cameraPID,
                        in: content
                    ) else {
                        throw VisionCaptureError.sourceWindowNotFound("カメラ")
                    }
                    let cameraStream = try self.makeStream(
                        window: cameraWindow,
                        kind: .camera
                    )
                    self.streams = [hudStream, cameraStream]
                } else {
                    self.streams = [hudStream]
                }

                let group = DispatchGroup()
                let startErrorLock = NSLock()
                var startError: Error?
                for stream in self.streams {
                    group.enter()
                    stream.startCapture { error in
                        startErrorLock.lock()
                        if startError == nil {
                            startError = error
                        }
                        startErrorLock.unlock()
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    startErrorLock.lock()
                    let result = startError
                    startErrorLock.unlock()
                    completion(result)
                }
            } catch {
                completion(error)
            }
        }
    }

    func stop() {
        let active = streams
        streams = []
        receivers = []
        for stream in active {
            stream.stopCapture()
        }
    }

    private func bestWindow(
        for processID: pid_t,
        in content: SCShareableContent
    ) -> SCWindow? {
        content.windows
            .filter { $0.owningApplication?.processID == processID }
            .max { lhs, rhs in
                lhs.frame.width * lhs.frame.height
                    < rhs.frame.width * rhs.frame.height
            }
    }

    private func makeStream(
        window: SCWindow,
        kind: VisionFrameKind
    ) throws -> SCStream {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(compositor.outputSize.width)
        configuration.height = Int(compositor.outputSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.showsCursor = false
        if #available(macOS 14.0, *) {
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.shouldBeOpaque = true
        }

        let receiver = VisionStreamReceiver(
            kind: kind,
            compositor: compositor
        )
        receiver.onFailure = { [weak self] error in
            self?.onFailure?(error)
        }
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: receiver
        )
        do {
            try stream.addStreamOutput(
                receiver,
                type: .screen,
                sampleHandlerQueue: captureQueue
            )
        } catch {
            throw VisionCaptureError.streamSetup(error.localizedDescription)
        }
        receivers.append(receiver)
        return stream
    }
}

final class VisionDisplayView: NSView {
    private let deviceSize: CGSize
    private var image: CGImage?
    private var status = "Rokidへ接続しています…"
    var onTap: ((Int, Int) -> Void)?
    var onBack: (() -> Void)?

    init(frame frameRect: NSRect, deviceSize: CGSize) {
        self.deviceSize = CGSize(
            width: max(deviceSize.width.rounded(), 1),
            height: max(deviceSize.height.rounded(), 1)
        )
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        deviceSize = CGSize(width: 480, height: 640)
        super.init(coder: coder)
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()

        if let image {
            NSGraphicsContext.current?.imageInterpolation = .high
            let nsImage = NSImage(
                cgImage: image,
                size: deviceSize
            )
            nsImage.draw(
                in: bounds,
                from: .zero,
                operation: .copy,
                fraction: 1
            )
            return
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium),
            .foregroundColor: NSColor(
                calibratedRed: 0.3,
                green: 1,
                blue: 0.35,
                alpha: 1
            ),
            .paragraphStyle: paragraph,
        ]
        let textRect = NSRect(
            x: 30,
            y: bounds.midY - 30,
            width: bounds.width - 60,
            height: 60
        )
        status.draw(in: textRect, withAttributes: attributes)
    }

    func show(_ image: CGImage) {
        self.image = image
        needsDisplay = true
    }

    func showStatus(_ text: String) {
        status = text
        image = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let x = Int(
            (location.x / bounds.width * deviceSize.width).rounded()
        )
        let y = Int(
            ((1 - location.y / bounds.height) * deviceSize.height).rounded()
        )
        onTap?(
            min(max(x, 0), Int(deviceSize.width) - 1),
            min(max(y, 0), Int(deviceSize.height) - 1)
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        onBack?()
    }
}
