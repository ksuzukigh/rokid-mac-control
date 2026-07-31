import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class VisionModeController: NSObject, NSWindowDelegate {
    private static let hudVisibilityDefaultsKey = "VisionHUDVisibility"
    private static let legacyBundleIdentifier =
        "io.github.ksuzukigh.rokid-control-vision-test"

    private let connection: RokidConnectionManager
    private let keyboard: KeyboardController
    private let logger: AppLogger
    private let resources: AppResources
    private let environment: [String: String]
    private let deviceSize: CGSize
    private let onClose: () -> Void
    private let onFailure: (String, String) -> Void
    private let onSourceStopped: () -> Void
    private let inputQueue = DispatchQueue(label: "RokidControl.VisionInput")
    private let cameraStateQueue = DispatchQueue(
        label: "RokidControl.CameraState"
    )

    private var hudApplication: NSRunningApplication?
    private var cameraApplication: NSRunningApplication?
    private var window: NSWindow?
    private var displayView: VisionDisplayView?
    private var compositor: VisionFrameCompositor?
    private var capture: VisionCaptureCoordinator?
    private var captureRecoveryScheduled = false
    private var captureRecoveryAttempts = 0
    private var cameraRecoveryScheduled = false
    private var cameraRecoveryAttempts = 0
    private var isShowingOriginalCameraScreen = false
    private var originalCameraStateCheckScheduled = false
    private var originalCameraCaptureAttempts = 0
    private var originalCameraCaptureRecoveryScheduled = false
    private var hudVisibility: Double
    private var sourceRestartRequested = false
    private var isStopping = false

    init(
        connection: RokidConnectionManager,
        keyboard: KeyboardController,
        logger: AppLogger,
        resources: AppResources,
        environment: [String: String],
        deviceSize: CGSize,
        onClose: @escaping () -> Void,
        onFailure: @escaping (String, String) -> Void,
        onSourceStopped: @escaping () -> Void
    ) {
        self.connection = connection
        self.keyboard = keyboard
        self.logger = logger
        self.resources = resources
        self.environment = environment
        self.deviceSize = CGSize(
            width: max(deviceSize.width.rounded(), 1),
            height: max(deviceSize.height.rounded(), 1)
        )
        self.onClose = onClose
        self.onFailure = onFailure
        self.onSourceStopped = onSourceStopped

        let defaults = UserDefaults.standard
        if defaults.object(
            forKey: Self.hudVisibilityDefaultsKey
        ) != nil {
            hudVisibility = min(
                max(defaults.double(forKey: Self.hudVisibilityDefaultsKey), 0),
                1
            )
        } else if let legacyDefaults = UserDefaults(
            suiteName: Self.legacyBundleIdentifier
        ),
        legacyDefaults.object(forKey: "HUDVisibility") != nil {
            hudVisibility = min(
                max(legacyDefaults.double(forKey: "HUDVisibility"), 0),
                1
            )
        } else {
            hudVisibility = 0.9
        }
        defaults.set(
            hudVisibility,
            forKey: Self.hudVisibilityDefaultsKey
        )
        super.init()
    }

    func start() {
        guard !isStopping else { return }
        createVisionWindow()
        displayView?.showStatus("映像を受信しています…")
        launchSources()
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        capture?.onFailure = nil
        capture?.stop()
        capture = nil
        compositor = nil
        if let application = cameraApplication, !application.isTerminated {
            application.terminate()
        }
        if let application = hudApplication, !application.isTerminated {
            application.terminate()
        }
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        displayView = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard !isStopping else { return }
        onClose()
    }

    func setAppSelection(_ isSelectingApp: Bool) {
        displayView?.setAppSelection(isSelectingApp)
    }

    private func createVisionWindow() {
        let size = NSSize(
            width: deviceSize.width,
            height: deviceSize.height
        )
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Rokid AI Glasses RV101（ライブ映像）"
        window.contentMinSize = NSSize(width: 360, height: 480)
        window.contentAspectRatio = size
        window.center()
        window.delegate = self

        let displayView = VisionDisplayView(
            frame: frame,
            deviceSize: deviceSize
        )
        displayView.autoresizingMask = [.width, .height]
        displayView.onTap = { [weak self] x, y in
            self?.keyboard.endAppSelection()
            self?.sendTap(x: x, y: y)
        }
        displayView.onBack = { [weak self] in
            self?.keyboard.endAppSelection()
            self?.sendKey("KEYCODE_BACK")
        }
        window.contentView = displayView
        addVisibilityControl(to: window)
        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.displayView = displayView
    }

    private func addVisibilityControl(to window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom

        let background = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 34)
        )
        background.material = .titlebar
        background.blendingMode = .withinWindow
        background.state = .active

        let title = NSTextField(labelWithString: "文字・アイコンの見やすさ")
        title.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let light = NSTextField(labelWithString: "薄い")
        light.font = NSFont.systemFont(ofSize: 11)
        light.textColor = .secondaryLabelColor
        let strong = NSTextField(labelWithString: "濃い")
        strong.font = NSFont.systemFont(ofSize: 11)
        strong.textColor = .secondaryLabelColor

        let slider = NSSlider(
            value: hudVisibility,
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(visibilityChanged(_:))
        )
        slider.isContinuous = true
        // 左右キーはRokidの操作へ回すため、このスライダーはマウス操作だけにする。
        slider.refusesFirstResponder = true
        slider.toolTip = "文字とアイコンの明るさ・太さを調整します（マウスで動かします）"
        slider.widthAnchor.constraint(equalToConstant: 185).isActive = true

        let stack = NSStackView(views: [title, light, slider, strong])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: background.leadingAnchor,
                constant: 12
            ),
            stack.trailingAnchor.constraint(
                equalTo: background.trailingAnchor,
                constant: -12
            ),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])

        accessory.view = background
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func visibilityChanged(_ sender: NSSlider) {
        let value = min(max(sender.doubleValue, 0), 1)
        hudVisibility = value
        UserDefaults.standard.set(
            value,
            forKey: Self.hudVisibilityDefaultsKey
        )
        compositor?.setHUDVisibility(value)
    }

    private func launchSources() {
        guard !isStopping else { return }
        let serial = connection.currentSerial()
        let sourcePosition = sourceWindowPosition()

        launchScrcpy(
            arguments: [
                "--serial", serial,
                "--no-audio",
                "--max-fps=15",
                "--keyboard=disabled",
                // 画面休止防止はRokidConnectionManagerが受け持つ。
                "--window-title=Rokid Vision HUD Source",
                "--window-borderless",
                "--window-width=\(Int(deviceSize.width))",
                "--window-height=\(Int(deviceSize.height))",
                "--window-x=\(sourcePosition.x)",
                "--window-y=\(sourcePosition.y)",
            ]
        ) { [weak self] application, error in
            guard let self, !self.isStopping else { return }
            guard let application, error == nil else {
                self.fail(
                    title: "Rokid画面を受信できませんでした",
                    message: error?.localizedDescription
                        ?? "画面表示部を起動できませんでした。"
                )
                return
            }
            self.hudApplication = application
            self.keyboard.updateScrcpyProcessIdentifier(
                application.processIdentifier
            )
            self.logger.log(
                "視界表示 HUD受信開始 pid=\(application.processIdentifier)"
            )
            self.launchCameraSource(
                hudApplication: application,
                isRecovery: false
            )
        }
    }

    private func launchCameraSource(
        hudApplication: NSRunningApplication,
        isRecovery: Bool
    ) {
        guard !isStopping else { return }
        let serial = connection.currentSerial()
        let sourcePosition = sourceWindowPosition()

        launchScrcpy(
            arguments: [
                "--serial", serial,
                "--video-source=camera",
                "--camera-ar=4:3",
                "--max-size=\(Int(max(deviceSize.width, deviceSize.height)))",
                "--camera-fps=15",
                "--orientation=270",
                "--no-audio",
                "--no-control",
                "--window-title=Rokid Vision Camera Source",
                "--window-borderless",
                "--window-width=\(Int(deviceSize.width))",
                "--window-height=\(Int(deviceSize.height))",
                "--window-x=\(sourcePosition.x)",
                "--window-y=\(sourcePosition.y)",
            ]
        ) { [weak self] cameraApplication, cameraError in
            guard let self, !self.isStopping else { return }
            guard let cameraApplication, cameraError == nil else {
                if isRecovery {
                    self.scheduleCameraRecovery(
                        cameraError ?? NSError(
                            domain: "RokidVision",
                            code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "カメラ受信部を再起動できませんでした。",
                            ]
                        )
                    )
                } else {
                    self.fail(
                        title: "カメラ映像を受信できませんでした",
                        message: cameraError?.localizedDescription
                            ?? "カメラ受信部を起動できませんでした。"
                    )
                }
                return
            }
            self.cameraApplication = cameraApplication
            self.logger.log(
                "\(isRecovery ? "視界表示 カメラ再受信開始" : "視界表示 カメラ受信開始") pid=\(cameraApplication.processIdentifier)"
            )
            self.startCompositing(
                hudPID: hudApplication.processIdentifier,
                cameraPID: cameraApplication.processIdentifier
            )
        }
    }

    private func sourceWindowPosition() -> (x: Int, y: Int) {
        var result = (x: 40, y: 40)
        let updatePosition = { [weak self] in
            guard
                let window = self?.window,
                let screen = window.screen ?? NSScreen.main
            else {
                return
            }
            result.x = Int(window.frame.minX.rounded())
            result.y = Int((screen.frame.maxY - window.frame.maxY).rounded())
        }
        if Thread.isMainThread {
            updatePosition()
        } else {
            DispatchQueue.main.sync(execute: updatePosition)
        }
        return result
    }

    private func launchScrcpy(
        arguments: [String],
        completion: @escaping (NSRunningApplication?, Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.environment = environment
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopping else { return }
            NSWorkspace.shared.openApplication(
                at: self.resources.scrcpyApp,
                configuration: configuration,
                completionHandler: completion
            )
        }
    }

    private func startCompositing(hudPID: pid_t, cameraPID: pid_t) {
        let delay = captureRecoveryAttempts == 0 ? 1.5 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopping else { return }
            guard self.hudApplication?.isTerminated == false else {
                self.requestSourceRestart(
                    reason: "Rokidとの画面接続が終了しました。"
                )
                return
            }
            guard self.cameraApplication?.isTerminated == false else {
                self.scheduleCameraRecovery(
                    NSError(
                        domain: "RokidVision",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Rokidのカメラが別のアプリで使用されています。",
                        ]
                    )
                )
                return
            }
            let compositor = VisionFrameCompositor(
                outputSize: self.deviceSize,
                hudVisibility: self.hudVisibility
            )
            compositor.onFrame = { [weak self] frame in
                self?.displayView?.show(frame)
            }
            let capture = VisionCaptureCoordinator(compositor: compositor)
            capture.onFailure = { [weak self] error in
                self?.scheduleCaptureRecovery(error)
            }
            self.compositor = compositor
            self.capture = capture
            capture.start(
                hudPID: hudPID,
                cameraPID: cameraPID
            ) { [weak self] error in
                guard let self, !self.isStopping else { return }
                if let error {
                    self.scheduleCaptureRecovery(error)
                    return
                }
                self.captureRecoveryScheduled = false
                self.captureRecoveryAttempts = 0
                self.cameraRecoveryScheduled = false
                self.cameraRecoveryAttempts = 0
                self.logger.log(
                    "視界表示 合成開始 \(Int(self.deviceSize.width))x\(Int(self.deviceSize.height))@15fps"
                )
                self.scheduleSourceWindowHiding()
                self.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func scheduleSourceWindowHiding() {
        for delay in [0.0, 0.25, 0.75, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.hideSourceWindows()
            }
        }
    }

    private func hideSourceWindows() {
        for application in [hudApplication, cameraApplication] {
            guard let application, !application.isTerminated else { continue }
            let accessibilityApplication = AXUIElementCreateApplication(
                application.processIdentifier
            )
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                accessibilityApplication,
                kAXWindowsAttribute as CFString,
                &windowsValue
            ) == .success,
            let sourceWindows = windowsValue as? [AXUIElement],
            !sourceWindows.isEmpty
            else {
                logger.log(
                    "受信用画面の退避待機 pid=\(application.processIdentifier)"
                )
                continue
            }

            var offscreenPosition = CGPoint(x: -10_000, y: -10_000)
            guard let positionValue = AXValueCreate(
                .cgPoint,
                &offscreenPosition
            ) else {
                continue
            }
            for sourceWindow in sourceWindows {
                _ = AXUIElementSetAttributeValue(
                    sourceWindow,
                    kAXPositionAttribute as CFString,
                    positionValue
                )
            }
        }
    }

    private func scheduleCaptureRecovery(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopping else { return }
            guard !self.captureRecoveryScheduled else { return }
            guard self.hudApplication?.isTerminated == false else {
                self.requestSourceRestart(
                    reason: "Rokidとの画面接続が終了しました。"
                )
                return
            }
            guard self.cameraApplication?.isTerminated == false else {
                self.scheduleCameraRecovery(error)
                return
            }

            self.captureRecoveryScheduled = true
            self.captureRecoveryAttempts += 1
            self.logger.log(
                "視界表示 合成再接続 attempt=\(self.captureRecoveryAttempts) reason=\(error.localizedDescription)"
            )

            self.capture?.onFailure = nil
            self.capture?.stop()
            self.capture = nil
            self.compositor = nil
            self.displayView?.showStatus("映像を再接続しています…")

            guard self.captureRecoveryAttempts <= 5 else {
                self.fail(
                    title: "映像を復旧できませんでした",
                    message: error.localizedDescription
                )
                return
            }

            self.captureRecoveryScheduled = false
            guard
                let hudPID = self.hudApplication?.processIdentifier,
                let cameraPID = self.cameraApplication?.processIdentifier
            else {
                self.fail(
                    title: "映像受信が停止しました",
                    message: "Rokidとの映像接続を確認できませんでした。"
                )
                return
            }
            self.startCompositing(hudPID: hudPID, cameraPID: cameraPID)
        }
    }

    private func scheduleCameraRecovery(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopping else { return }
            guard !self.cameraRecoveryScheduled else { return }
            guard let hudApplication = self.hudApplication,
                  !hudApplication.isTerminated
            else {
                self.requestSourceRestart(
                    reason: "Rokidとの画面接続が終了しました。"
                )
                return
            }

            self.cameraRecoveryScheduled = true
            self.captureRecoveryScheduled = false
            self.capture?.onFailure = nil
            self.capture?.stop()
            self.capture = nil
            self.compositor = nil
            self.displayView?.showStatus(
                "撮影中です…\nカメラ映像の復帰を待っています"
            )

            self.readOriginalCameraForeground { [weak self] isForeground in
                guard let self, !self.isStopping else { return }
                self.cameraRecoveryScheduled = false
                if isForeground {
                    self.showOriginalCameraScreen(
                        hudApplication: hudApplication
                    )
                    return
                }

                self.cameraRecoveryAttempts += 1
                self.logger.log(
                    "視界表示 カメラ再受信待機 attempt=\(self.cameraRecoveryAttempts) reason=\(error.localizedDescription)"
                )

                guard self.cameraRecoveryAttempts <= 15 else {
                    self.fail(
                        title: "カメラ映像を復旧できませんでした",
                        message: "カメラを使用しているアプリを終了してから、もう一度お試しください。"
                    )
                    return
                }

                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 2.0
                ) { [weak self] in
                    guard let self, !self.isStopping else { return }
                    self.launchCameraSource(
                        hudApplication: hudApplication,
                        isRecovery: true
                    )
                }
            }
        }
    }

    private func readOriginalCameraForeground(
        completion: @escaping (Bool) -> Void
    ) {
        cameraStateQueue.async { [weak self] in
            guard let self, !self.isStopping else { return }
            let serial = self.connection.currentSerial()
            let result = self.connection.runADB([
                "-s", serial, "shell", "dumpsys", "activity", "activities",
            ], timeout: 3)
            let isForeground = result.succeeded
                && CameraAppPolicy.isOriginalCameraForeground(result.output)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isStopping else { return }
                completion(isForeground)
            }
        }
    }

    /// 純正カメラは背面カメラを専有するが、HUD用の画面転送にはカラーの
    /// プレビューが含まれる。カメラ受信を止め、Rokid画面をそのまま表示する。
    private func showOriginalCameraScreen(
        hudApplication: NSRunningApplication
    ) {
        guard !isStopping else { return }
        guard !isShowingOriginalCameraScreen else {
            scheduleOriginalCameraStateCheck()
            return
        }

        isShowingOriginalCameraScreen = true
        originalCameraCaptureAttempts = 0
        cameraRecoveryAttempts = 0
        if let application = cameraApplication, !application.isTerminated {
            application.terminate()
        }
        cameraApplication = nil
        window?.title = "Rokid AI Glasses RV101（純正カメラ）"
        displayView?.showStatus("純正カメラへ切り替えています…")
        startOriginalCameraScreenCapture(
            hudApplication: hudApplication
        )
    }

    private func startOriginalCameraScreenCapture(
        hudApplication: NSRunningApplication
    ) {
        guard !isStopping, isShowingOriginalCameraScreen else { return }
        guard !hudApplication.isTerminated else {
            requestSourceRestart(
                reason: "Rokidとの画面接続が終了しました。"
            )
            return
        }

        capture?.onFailure = nil
        capture?.stop()
        capture = nil
        compositor = nil

        let compositor = VisionFrameCompositor(
            outputSize: deviceSize,
            hudVisibility: hudVisibility,
            mode: .deviceScreen
        )
        compositor.onFrame = { [weak self] frame in
            self?.displayView?.show(frame)
        }
        let capture = VisionCaptureCoordinator(compositor: compositor)
        capture.onFailure = { [weak self] error in
            self?.recoverOriginalCameraScreen(
                hudApplication: hudApplication,
                error: error
            )
        }
        self.compositor = compositor
        self.capture = capture
        capture.start(
            hudPID: hudApplication.processIdentifier
        ) { [weak self] error in
            guard let self, !self.isStopping,
                  self.isShowingOriginalCameraScreen
            else {
                return
            }
            if let error {
                self.recoverOriginalCameraScreen(
                    hudApplication: hudApplication,
                    error: error
                )
                return
            }
            self.originalCameraCaptureRecoveryScheduled = false
            self.originalCameraCaptureAttempts = 0
            self.logger.log("視界表示 純正カメラ画面へ切替")
            self.scheduleSourceWindowHiding()
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.scheduleOriginalCameraStateCheck()
        }
    }

    private func recoverOriginalCameraScreen(
        hudApplication: NSRunningApplication,
        error: Error
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopping,
                  self.isShowingOriginalCameraScreen,
                  !self.originalCameraCaptureRecoveryScheduled
            else {
                return
            }
            self.originalCameraCaptureRecoveryScheduled = true
            self.originalCameraCaptureAttempts += 1
            self.logger.log(
                "視界表示 純正カメラ画面再接続 attempt=\(self.originalCameraCaptureAttempts) reason=\(error.localizedDescription)"
            )
            self.capture?.onFailure = nil
            self.capture?.stop()
            self.capture = nil
            self.compositor = nil
            self.displayView?.showStatus(
                "純正カメラ画面を再接続しています…"
            )

            guard self.originalCameraCaptureAttempts <= 5 else {
                self.requestSourceRestart(
                    reason: "純正カメラ画面の受信が停止しました。"
                )
                return
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 1.0
            ) { [weak self] in
                guard let self, !self.isStopping,
                      self.isShowingOriginalCameraScreen
                else {
                    return
                }
                self.originalCameraCaptureRecoveryScheduled = false
                self.startOriginalCameraScreenCapture(
                    hudApplication: hudApplication
                )
            }
        }
    }

    private func scheduleOriginalCameraStateCheck() {
        guard !isStopping, isShowingOriginalCameraScreen,
              !originalCameraStateCheckScheduled
        else {
            return
        }
        originalCameraStateCheckScheduled = true
        cameraStateQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.isStopping else { return }
            let serial = self.connection.currentSerial()
            let result = self.connection.runADB([
                "-s", serial, "shell", "dumpsys", "activity", "activities",
            ], timeout: 3)
            let isForeground = result.succeeded
                && CameraAppPolicy.isOriginalCameraForeground(result.output)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isStopping else { return }
                self.originalCameraStateCheckScheduled = false
                // 読み取り失敗時はカメラを横取りせず、次の確認を待つ。
                guard result.succeeded else {
                    self.scheduleOriginalCameraStateCheck()
                    return
                }
                if isForeground {
                    self.scheduleOriginalCameraStateCheck()
                } else {
                    self.restoreLiveCameraBackground()
                }
            }
        }
    }

    private func restoreLiveCameraBackground() {
        guard !isStopping, isShowingOriginalCameraScreen else { return }
        isShowingOriginalCameraScreen = false
        originalCameraCaptureAttempts = 0
        originalCameraCaptureRecoveryScheduled = false
        capture?.onFailure = nil
        capture?.stop()
        capture = nil
        compositor = nil
        window?.title = "Rokid AI Glasses RV101（ライブ映像）"
        displayView?.showStatus("ライブ映像へ戻しています…")
        logger.log("視界表示 純正カメラ終了を検出")

        guard let hudApplication, !hudApplication.isTerminated else {
            requestSourceRestart(
                reason: "Rokidとの画面接続が終了しました。"
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.isStopping,
                  !self.isShowingOriginalCameraScreen
            else {
                return
            }
            self.launchCameraSource(
                hudApplication: hudApplication,
                isRecovery: true
            )
        }
    }

    private func sendTap(x: Int, y: Int) {
        inputQueue.async { [weak self] in
            guard let self else { return }
            let serial = self.connection.currentSerial()
            _ = self.connection.runADB([
                "-s", serial, "shell", "input", "tap", "\(x)", "\(y)",
            ])
            self.logger.log("視界画面タップ \(x),\(y)")
        }
    }

    private func sendKey(_ key: String) {
        inputQueue.async { [weak self] in
            guard let self else { return }
            let serial = self.connection.currentSerial()
            _ = self.connection.runADB([
                "-s", serial, "shell", "input", "keyevent", key,
            ])
            self.logger.log("視界画面キー \(key)")
        }
    }

    private func fail(title: String, message: String) {
        guard !isStopping else { return }
        logger.log("ERROR \(title): \(message)")
        onFailure(title, message)
    }

    private func requestSourceRestart(reason: String) {
        guard !isStopping, !sourceRestartRequested else { return }
        sourceRestartRequested = true
        logger.log("視界表示 全映像再接続 reason=\(reason)")
        displayView?.showStatus("Rokidへ再接続しています…")
        onSourceStopped()
    }
}
