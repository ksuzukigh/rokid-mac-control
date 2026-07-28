import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private final class ActivationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class NavigationHighlightView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.65).setStroke()
        let outer = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        outer.lineWidth = 7
        outer.stroke()

        NSColor.systemCyan.setStroke()
        let inner = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
        inner.lineWidth = 3
        inner.stroke()
    }
}

final class RokidControlApp: NSObject, NSApplicationDelegate {
    private enum DisplayMode {
        case standard
        case vision
    }

    private var logger: AppLogger?
    private var runner: ProcessRunner?
    private var connection: RokidConnectionManager?
    private var keyboard: KeyboardController?
    // Main-thread-only UI state.
    private var scrcpyApplication: NSRunningApplication?
    private var visionController: VisionModeController?
    private var visionRecoveryInProgress = false
    private var displayMode: DisplayMode = .standard
    private var scrcpyTerminationObserver: NSObjectProtocol?
    private var scrcpyTerminationSource: DispatchSourceProcess?
    private var connectingWindow: NSWindow?
    private var connectingStatusLabel: NSTextField?
    private var terminationWindow: NSWindow?
    private var activationWindow: NSWindow?
    private var navigationHighlightWindow: NSPanel?
    private var currentNavigationItem: LowerNavigationItem?
    private let stateLock = NSLock()
    private var terminationStarted = false
    private var terminationFinished = false
    private var connectionCancelled = false
    private var scrcpyRestartCount = 0
    private var lastScrcpyStart = Date.distantPast
    private let workQueue = DispatchQueue(label: "RokidControl.MainWork")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        NSApp.activate(ignoringOtherApps: true)

        guard requestAccessibilityIfNeeded() else {
            showFailure(
                title: "キーボード操作の許可が必要です",
                message: "開いた設定画面で「Rokid Control」を許可してから、もう一度起動してください。"
            )
            return
        }

        guard let selectedMode = chooseDisplayMode() else {
            NSApp.terminate(nil)
            return
        }
        displayMode = selectedMode

        if displayMode == .vision && !requestScreenCaptureIfNeeded() {
            showFailure(
                title: "画面収録の許可が必要です",
                message: "「システム設定」→「プライバシーとセキュリティ」→「画面とシステムオーディオ録音」で「Rokid Control」を許可してから、もう一度起動してください。"
            )
            return
        }

        do {
            let logger = try AppLogger()
            self.logger = logger
            let resources = try locateResources()
            terminateOrphanedScrcpy(at: resources.scrcpyApp, logger: logger)
            logger.log(
                "表示モード \(displayMode == .vision ? "視界表示" : "通常表示")"
            )
            let environment = makeEnvironment(resources: resources)
            let runner = ProcessRunner(environment: environment)
            self.runner = runner
            let connection = try RokidConnectionManager(
                adbURL: resources.adb,
                watchdogURL: resources.watchdog,
                runner: runner,
                logger: logger
            )
            self.connection = connection
            showConnectingWindow()

            workQueue.async { [weak self] in
                guard let self else { return }
                do {
                    connection.prepareADBServer()
                    _ = try connection.connectForStartup(
                        onProgress: { [weak self] message in
                            self?.updateConnectingStatus(message)
                        },
                        isCancelled: { [weak self] in
                            self?.shouldCancelConnection() ?? true
                        }
                    )
                    self.updateConnectingStatus(
                        "Mac操作モードを開始しています…"
                    )
                    try self.startMacModeWithRetry()

                    let keyboard = KeyboardController(
                        connection: connection,
                        logger: logger,
                        scrcpyAppURL: resources.scrcpyApp
                    )
                    let deviceSize = keyboard.updateScreenSize()
                    let keyboardStarted = DispatchQueue.main.sync {
                        guard !self.isTerminating else { return false }
                        self.keyboard = keyboard
                        keyboard.setModalPresented(
                            self.connectingWindow != nil
                        )
                        keyboard.onActivate = { [weak self] in
                            self?.activateAfterScrcpyClick()
                        }
                        keyboard.onNavigationSelection = { [weak self] item in
                            self?.updateNavigationSelection(item)
                        }
                        keyboard.onQuit = {
                            NSApp.terminate(nil)
                        }
                        return keyboard.start()
                    }
                    guard keyboardStarted else {
                        if !self.isTerminating {
                            self.failFromWorker(
                                title: "キーボード操作を開始できませんでした",
                                message: "macOSのアクセシビリティ設定を確認してください。"
                            )
                        }
                        return
                    }
                    self.updateConnectingStatus("画面を受信しています…")
                    switch self.displayMode {
                    case .standard:
                        self.launchScrcpy(
                            resources: resources,
                            environment: environment
                        )
                    case .vision:
                        DispatchQueue.main.async { [weak self] in
                            guard let self, !self.isTerminating else { return }
                            self.startVisionController(
                                connection: connection,
                                keyboard: keyboard,
                                logger: logger,
                                resources: resources,
                                environment: environment,
                                deviceSize: CGSize(
                                    width: deviceSize.0,
                                    height: deviceSize.1
                                )
                            )
                        }
                    }
                } catch {
                    if case RokidConnectionError.cancelled = error {
                        DispatchQueue.main.async {
                            NSApp.terminate(nil)
                        }
                        return
                    }
                    self.failFromWorker(
                        title: "Rokid操作を開始できませんでした",
                        message: error.localizedDescription
                    )
                }
            }
        } catch {
            showFailure(
                title: "Rokid Controlを開始できませんでした",
                message: error.localizedDescription
            )
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard beginTermination() else {
            return isTerminationFinished ? .terminateNow : .terminateLater
        }

        stopLocalResources()
        showTerminationWindowIfNeeded()
        let connection = self.connection
        let logger = self.logger
        workQueue.async { [weak self] in
            connection?.stopMacMode()
            // terminateLater中はメインのDispatchQueueが進まない場合がある。
            // RunLoopへ直接積み、終了の返答を必ずAppKitへ返す。
            CFRunLoopPerformBlock(
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue as CFString
            ) {
                logger?.log("Rokid Control終了")
                logger?.close()
                self?.logger = nil
                self?.finishTermination()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeScrcpyTerminationObserver()
        stopLocalResources()
    }

    private func chooseDisplayMode() -> DisplayMode? {
        while true {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "背景を選んでください"
            alert.informativeText =
                "ライブ映像：カメラの映像を背景に表示します。\n"
                + "背景なし（省電力）：黒い背景で表示します。ライブ映像は使いません。"
            alert.addButton(withTitle: "ライブ映像")
            alert.addButton(withTitle: "背景なし（省電力）")
            alert.addButton(withTitle: "キャンセル")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let warning = NSAlert()
                warning.alertStyle = .informational
                warning.messageText = "ライブ映像を開始します"
                warning.informativeText =
                    "カメラを使用するため、背景なし（省電力）より電池を多く消費します。"
                warning.addButton(withTitle: "開始")
                warning.addButton(withTitle: "戻る")
                if warning.runModal() == .alertFirstButtonReturn {
                    return .vision
                }
            case .alertSecondButtonReturn:
                return .standard
            default:
                return nil
            }
        }
    }

    private func launchScrcpy(
        resources: AppResources,
        environment: [String: String]
    ) {
        guard !isTerminating, let connection, let logger else { return }
        let serial = connection.currentSerial()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [
            "--serial", serial,
            "--no-audio",
            "--keyboard=disabled",
            "--window-title=Rokid AI Glasses RV101（Mac操作モード）",
        ]
        configuration.environment = environment
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTerminating else { return }
            NSWorkspace.shared.openApplication(
                at: resources.scrcpyApp,
                configuration: configuration
            ) { [weak self] runningApplication, error in
                guard let self, !self.isTerminating else { return }
                guard let runningApplication, error == nil else {
                    self.failFromWorker(
                        title: "Rokid画面を表示できませんでした",
                        message: error?.localizedDescription ?? "画面表示部を起動できませんでした。"
                    )
                    return
                }

                DispatchQueue.main.async {
                    self.scrcpyApplication = runningApplication
                    self.recordScrcpyStart()
                    self.keyboard?.updateScrcpyProcessIdentifier(
                        runningApplication.processIdentifier
                    )
                    self.registerScrcpyTerminationObserver(
                        for: runningApplication,
                        resources: resources,
                        environment: environment
                    )
                    self.ensureActivationWindow()
                    self.closeConnectingWindow()
                    logger.log(
                        "scrcpy開始 pid=\(runningApplication.processIdentifier) serial=\(serial)"
                    )
                    self.focusScrcpy(
                        processIdentifier: runningApplication.processIdentifier
                    )
                }
            }
        }
    }

    private func startVisionController(
        connection: RokidConnectionManager,
        keyboard: KeyboardController,
        logger: AppLogger,
        resources: AppResources,
        environment: [String: String],
        deviceSize: CGSize
    ) {
        guard !isTerminating else { return }
        closeConnectingWindow()
        let controller = VisionModeController(
            connection: connection,
            keyboard: keyboard,
            logger: logger,
            resources: resources,
            environment: environment,
            deviceSize: deviceSize,
            onClose: { [weak self] in
                NSApp.terminate(self)
            },
            onFailure: { [weak self] title, message in
                self?.failFromWorker(
                    title: title,
                    message: message
                )
            },
            onSourceStopped: { [weak self] in
                self?.recoverVisionSources(
                    resources: resources,
                    environment: environment
                )
            }
        )
        visionController = controller
        visionRecoveryInProgress = false
        controller.start()
    }

    private func recoverVisionSources(
        resources: AppResources,
        environment: [String: String]
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isTerminating,
                  !self.visionRecoveryInProgress,
                  let connection = self.connection,
                  let keyboard = self.keyboard,
                  let logger = self.logger
            else {
                return
            }
            self.visionRecoveryInProgress = true
            self.visionController?.stop()
            self.visionController = nil
            keyboard.updateScrcpyProcessIdentifier(nil)
            logger.log("視界表示 接続復旧開始")

            self.workQueue.async { [weak self] in
                guard let self, !self.isTerminating else { return }
                if !connection.isCurrentConnectionAlive() {
                    guard connection.reconnect(
                        isCancelled: { [weak self] in
                            self?.isTerminating ?? true
                        }
                    ) != nil else {
                        guard !self.isTerminating else { return }
                        self.failFromWorker(
                            title: "Wi-Fi接続を復旧できませんでした",
                            message: "Rokidで「Wi-Fi ON」を開いてから、もう一度起動してください。"
                        )
                        return
                    }
                    do {
                        try self.startMacModeWithRetry()
                        keyboard.updateScreenSize()
                    } catch {
                        self.failFromWorker(
                            title: "Wi-Fi接続を復旧できませんでした",
                            message: error.localizedDescription
                        )
                        return
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isTerminating else { return }
                    logger.log("視界表示 接続復旧成功")
                    self.startVisionController(
                        connection: connection,
                        keyboard: keyboard,
                        logger: logger,
                        resources: resources,
                        environment: environment,
                        deviceSize: {
                            let size = keyboard.currentScreenSize()
                            return CGSize(width: size.0, height: size.1)
                        }()
                    )
                }
            }
        }
    }

    private func registerScrcpyTerminationObserver(
        for application: NSRunningApplication,
        resources: AppResources,
        environment: [String: String]
    ) {
        removeScrcpyTerminationObserver()
        let processIdentifier = application.processIdentifier
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.handleObservedScrcpyTermination(
                processIdentifier: processIdentifier,
                resources: resources,
                environment: environment
            )
        }
        scrcpyTerminationSource = source
        source.resume()

        scrcpyTerminationObserver = NSWorkspace.shared.notificationCenter
            .addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let self,
                    let terminated = notification.userInfo?[
                        NSWorkspace.applicationUserInfoKey
                    ] as? NSRunningApplication,
                    terminated.processIdentifier == processIdentifier
                else {
                    return
                }
                self.handleObservedScrcpyTermination(
                    processIdentifier: processIdentifier,
                    resources: resources,
                    environment: environment
                )
            }
    }

    private func handleObservedScrcpyTermination(
        processIdentifier: pid_t,
        resources: AppResources,
        environment: [String: String]
    ) {
        guard
            scrcpyApplication?.processIdentifier == processIdentifier
        else {
            return
        }
        removeScrcpyTerminationObserver()
        scrcpyApplication = nil
        keyboard?.updateScrcpyProcessIdentifier(nil)
        guard !isTerminating else { return }
        workQueue.async { [weak self] in
            self?.handleScrcpyTermination(
                resources: resources,
                environment: environment
            )
        }
    }

    private func removeScrcpyTerminationObserver() {
        if let observer = scrcpyTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            scrcpyTerminationObserver = nil
        }
        scrcpyTerminationSource?.cancel()
        scrcpyTerminationSource = nil
    }

    private func focusScrcpy(processIdentifier: pid_t) {
        for delay in [1.0, 2.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.isTerminating == false else { return }
                let activated = NSRunningApplication(
                    processIdentifier: processIdentifier
                )?.activate(options: [.activateAllWindows]) ?? false

                let applicationElement = AXUIElementCreateApplication(
                    processIdentifier
                )
                AXUIElementSetAttributeValue(
                    applicationElement,
                    kAXFrontmostAttribute as CFString,
                    kCFBooleanTrue
                )

                var windowsValue: CFTypeRef?
                let windowsResult = AXUIElementCopyAttributeValue(
                    applicationElement,
                    kAXWindowsAttribute as CFString,
                    &windowsValue
                )
                var raised = false
                if windowsResult == .success,
                   let windows = windowsValue as? [AXUIElement],
                   let window = windows.first {
                    AXUIElementSetAttributeValue(
                        window,
                        kAXMainAttribute as CFString,
                        kCFBooleanTrue
                    )
                    AXUIElementSetAttributeValue(
                        window,
                        kAXFocusedAttribute as CFString,
                        kCFBooleanTrue
                    )
                    raised = AXUIElementPerformAction(
                        window,
                        kAXRaiseAction as CFString
                    ) == .success
                }
                self?.activateRokidControl()
                self?.logger?.log(
                    "scrcpy画面を最前面へ移動 activated=\(activated) raised=\(raised)"
                )
            }
        }
    }

    private func handleScrcpyTermination(
        resources: AppResources,
        environment: [String: String]
    ) {
        logger?.log("scrcpy終了")
        guard !isTerminating else { return }

        guard let connection else { return }
        if connection.isCurrentConnectionAlive() {
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return
        }

        if shouldAskBeforeRestartingScrcpy() {
            askUserWhetherToReconnect(
                resources: resources,
                environment: environment
            )
            return
        }

        reconnectScrcpy(resources: resources, environment: environment)
    }

    private func reconnectScrcpy(
        resources: AppResources,
        environment: [String: String]
    ) {
        guard !isTerminating, let connection else { return }
        logger?.log("Wi-Fi再接続開始")
        guard connection.reconnect(
            isCancelled: { [weak self] in
                self?.isTerminating ?? true
            }
        ) != nil else {
            guard !isTerminating else { return }
            failFromWorker(
                title: "Wi-Fi接続を復旧できませんでした",
                message: "Rokidで「Wi-Fi ON」を開いてから、もう一度起動してください。"
            )
            return
        }

        do {
            try startMacModeWithRetry()
            keyboard?.updateScreenSize()
            logger?.log("Wi-Fi再接続成功")
            launchScrcpy(resources: resources, environment: environment)
        } catch {
            failFromWorker(
                title: "Wi-Fi接続を復旧できませんでした",
                message: error.localizedDescription
            )
        }
    }

    private func askUserWhetherToReconnect(
        resources: AppResources,
        environment: [String: String]
    ) {
        logger?.log("scrcpyの短時間終了が続いたため自動再接続を停止")
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTerminating else { return }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Rokid画面が繰り返し閉じました"
            alert.informativeText =
                "Wi-Fi接続が不安定な可能性があります。再接続しますか？"
            alert.addButton(withTitle: "再接続")
            alert.addButton(withTitle: "終了")

            self.keyboard?.setModalPresented(true)
            let response = alert.runModal()
            self.keyboard?.setModalPresented(false)
            if response == .alertFirstButtonReturn {
                self.resetScrcpyRestartCount()
                self.workQueue.async { [weak self] in
                    self?.reconnectScrcpy(
                        resources: resources,
                        environment: environment
                    )
                }
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem(
            title: "Rokid Control",
            action: nil,
            keyEquivalent: ""
        )
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "Rokid Control")
        appMenu.addItem(
            withTitle: "Rokid Controlを終了",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func startMacModeWithRetry() throws {
        guard let connection else {
            throw RokidConnectionError.watchdogFailed
        }
        var lastError: Error = RokidConnectionError.watchdogFailed
        for attempt in 1...3 {
            if isTerminating {
                throw RokidConnectionError.cancelled
            }
            do {
                try connection.startMacMode()
                return
            } catch {
                lastError = error
                logger?.log("Mac操作モード開始失敗 attempt=\(attempt)")
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 2)
                }
            }
        }
        throw lastError
    }

    private var isTerminating: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return terminationStarted
    }

    private var isTerminationFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return terminationFinished
    }

    private func beginTermination() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !terminationStarted else { return false }
        terminationStarted = true
        connectionCancelled = true
        return true
    }

    private func finishTermination() {
        stateLock.lock()
        terminationFinished = true
        stateLock.unlock()
        terminationWindow?.orderOut(nil)
        terminationWindow = nil
    }

    private func shouldCancelConnection() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connectionCancelled || terminationStarted
    }

    private func recordScrcpyStart() {
        stateLock.lock()
        lastScrcpyStart = Date()
        stateLock.unlock()
    }

    private func shouldAskBeforeRestartingScrcpy() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let elapsed = Date().timeIntervalSince(lastScrcpyStart)
        if elapsed < 5 {
            scrcpyRestartCount += 1
        } else {
            scrcpyRestartCount = 0
        }
        return scrcpyRestartCount >= 2
    }

    private func resetScrcpyRestartCount() {
        stateLock.lock()
        scrcpyRestartCount = 0
        stateLock.unlock()
    }

    private func stopLocalResources() {
        dispatchPrecondition(condition: .onQueue(.main))
        closeConnectingWindow()
        removeScrcpyTerminationObserver()
        keyboard?.stop()
        keyboard?.onActivate = nil
        keyboard?.onNavigationSelection = nil
        keyboard?.onQuit = nil
        keyboard = nil
        visionController?.stop()
        visionController = nil
        visionRecoveryInProgress = false
        activationWindow?.orderOut(nil)
        activationWindow = nil
        navigationHighlightWindow?.orderOut(nil)
        navigationHighlightWindow = nil
        currentNavigationItem = nil

        if let application = scrcpyApplication, !application.isTerminated {
            application.terminate()
        }
        scrcpyApplication = nil
    }

    private func ensureActivationWindow() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activationWindow == nil else { return }

        let visibleFrame = NSScreen.main?.visibleFrame ?? .zero
        let window = ActivationWindow(
            contentRect: NSRect(
                x: visibleFrame.minX + 1,
                y: visibleFrame.minY + 1,
                width: 1,
                height: 1
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        activationWindow = window
        window.orderFront(nil)
    }

    private func activateRokidControl() {
        dispatchPrecondition(condition: .onQueue(.main))
        ensureActivationWindow()
        activationWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func activateAfterScrcpyClick() {
        dispatchPrecondition(condition: .onQueue(.main))
        // The system finishes activating the clicked LSUIElement window after
        // the event tap callback. Reclaim the regular app menu just afterward.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, !self.isTerminating else { return }
            self.activateRokidControl()
            if let item = self.currentNavigationItem {
                self.showStandardNavigationHighlight(for: item)
            }
            self.logger?.log("Rokid画面クリックでアプリを前面化")
        }
    }

    private func updateNavigationSelection(
        _ item: LowerNavigationItem?
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        currentNavigationItem = item
        visionController?.setNavigationSelection(item)
        guard displayMode == .standard, let item else {
            navigationHighlightWindow?.orderOut(nil)
            return
        }
        showStandardNavigationHighlight(for: item)
    }

    private func showStandardNavigationHighlight(
        for item: LowerNavigationItem
    ) {
        guard
            let processIdentifier = scrcpyApplication?.processIdentifier,
            let screenSize = keyboard?.currentScreenSize(),
            let center = standardNavigationCenter(
                processIdentifier: processIdentifier,
                item: item,
                screenSize: screenSize
            )
        else {
            navigationHighlightWindow?.orderOut(nil)
            return
        }

        let window: NSPanel
        if let existing = navigationHighlightWindow {
            window = existing
        } else {
            window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 44, height: 44),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isFloatingPanel = true
            window.becomesKeyOnlyIfNeeded = true
            window.hidesOnDeactivate = true
            window.level = .floating
            window.ignoresMouseEvents = true
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.transient, .ignoresCycle]
            window.contentView = NavigationHighlightView(
                frame: NSRect(x: 0, y: 0, width: 44, height: 44)
            )
            navigationHighlightWindow = window
        }
        window.setFrameOrigin(
            NSPoint(
                x: center.x - window.frame.width / 2,
                y: center.y - window.frame.height / 2
            )
        )
        window.orderFrontRegardless()
    }

    private func standardNavigationCenter(
        processIdentifier: pid_t,
        item: LowerNavigationItem,
        screenSize: (Int, Int)
    ) -> NSPoint? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        guard let window = windows.first(where: {
            guard
                let owner = $0[kCGWindowOwnerPID as String] as? NSNumber,
                owner.int32Value == processIdentifier,
                let layer = $0[kCGWindowLayer as String] as? NSNumber
            else {
                return false
            }
            return layer.intValue == 0
        }),
        let boundsDictionary = window[
            kCGWindowBounds as String
        ] as? NSDictionary,
        let bounds = CGRect(
            dictionaryRepresentation: boundsDictionary as CFDictionary
        ) else {
            return nil
        }

        let width = CGFloat(max(screenSize.0, 1))
        let height = CGFloat(max(screenSize.1, 1))
        let contentHeight = min(bounds.height, bounds.width * height / width)
        let contentWidth = contentHeight * width / height
        let contentLeft = bounds.midX - contentWidth / 2
        let contentTop = bounds.maxY - contentHeight
        let devicePoint = item.devicePoint(
            forScreenWidth: screenSize.0,
            height: screenSize.1
        )
        let quartzPoint = CGPoint(
            x: contentLeft + devicePoint.x / width * contentWidth,
            y: contentTop + devicePoint.y / height * contentHeight
        )
        return cocoaPoint(fromQuartzPoint: quartzPoint)
    }

    private func cocoaPoint(
        fromQuartzPoint point: CGPoint
    ) -> NSPoint? {
        for screen in NSScreen.screens {
            guard
                let screenNumber = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber
            else {
                continue
            }
            let quartzBounds = CGDisplayBounds(
                CGDirectDisplayID(screenNumber.uint32Value)
            )
            guard quartzBounds.contains(point) else { continue }
            return NSPoint(
                x: screen.frame.minX + point.x - quartzBounds.minX,
                y: screen.frame.maxY - (point.y - quartzBounds.minY)
            )
        }
        return nil
    }

    private func showConnectingWindow() {
        dispatchPrecondition(condition: .onQueue(.main))
        closeConnectingWindow()
        keyboard?.setModalPresented(true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Rokid Control"
        window.isReleasedWhenClosed = false
        window.center()

        let status = NSTextField(labelWithString: "Rokidを探しています…")
        status.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        status.alignment = .center
        status.maximumNumberOfLines = 2

        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .regular
        indicator.startAnimation(nil)

        let cancel = NSButton(
            title: "キャンセル",
            target: self,
            action: #selector(cancelConnecting)
        )
        cancel.bezelStyle = .rounded

        let stack = NSStackView(views: [indicator, status, cancel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: content.leadingAnchor,
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor,
                constant: -24
            ),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 360),
        ])

        connectingWindow = window
        connectingStatusLabel = status
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateConnectingStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTerminating else { return }
            self.connectingStatusLabel?.stringValue = message
        }
    }

    @objc private func cancelConnecting() {
        stateLock.lock()
        connectionCancelled = true
        stateLock.unlock()
        connectingStatusLabel?.stringValue = "キャンセルしています…"
        NSApp.terminate(nil)
    }

    private func closeConnectingWindow() {
        dispatchPrecondition(condition: .onQueue(.main))
        connectingWindow?.orderOut(nil)
        connectingWindow = nil
        connectingStatusLabel = nil
        keyboard?.setModalPresented(false)
    }

    private func showTerminationWindowIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self,
                  self.isTerminating,
                  !self.isTerminationFinished
            else {
                return
            }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 110),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.title = "Rokid Control"
            window.isReleasedWhenClosed = false
            window.center()

            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.startAnimation(nil)
            let label = NSTextField(labelWithString: "終了しています…")
            label.font = NSFont.systemFont(ofSize: 15, weight: .medium)
            let stack = NSStackView(views: [indicator, label])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            guard let content = window.contentView else { return }
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])

            self.terminationWindow = window
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func terminateOrphanedScrcpy(
        at scrcpyAppURL: URL,
        logger: AppLogger
    ) {
        let expectedURL = scrcpyAppURL.standardizedFileURL
        for application in NSWorkspace.shared.runningApplications
        where application.bundleURL?.standardizedFileURL == expectedURL {
            logger.log(
                "前回の残存scrcpyを終了 pid=\(application.processIdentifier)"
            )
            application.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if !application.isTerminated {
                    application.forceTerminate()
                }
            }
        }
    }

    private func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
        return false
    }

    private func requestScreenCaptureIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    private func locateResources() throws -> AppResources {
        guard let resources = Bundle.main.resourceURL else {
            throw RokidConnectionError.missingResource("Resources")
        }
        let bin = resources.appendingPathComponent("bin", isDirectory: true)
        let scrcpy = resources
            .appendingPathComponent("Scrcpy.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS/scrcpy")
        let scrcpyApp = resources
            .appendingPathComponent("Scrcpy.app", isDirectory: true)
        let scrcpyIcons = resources
            .appendingPathComponent("Scrcpy.app", isDirectory: true)
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        let values = AppResources(
            adb: bin.appendingPathComponent("adb"),
            scrcpy: scrcpy,
            scrcpyApp: scrcpyApp,
            scrcpyIcons: scrcpyIcons,
            server: resources.appendingPathComponent("scrcpy-server"),
            watchdog: resources.appendingPathComponent("rokid_wifi_watchdog.sh")
        )
        for url in [values.adb, values.scrcpy, values.server, values.watchdog] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw RokidConnectionError.missingResource(url.lastPathComponent)
            }
        }
        return values
    }

    private func makeEnvironment(resources: AppResources) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = resources.adb.deletingLastPathComponent().path
            + ":/usr/bin:/bin:/usr/sbin:/sbin"
        environment["ADB"] = resources.adb.path
        environment["SCRCPY_ICON_DIR"] = resources.scrcpyIcons.path
        environment["SCRCPY_SERVER_PATH"] = resources.server.path
        environment["ANDROID_ADB_SERVER_PORT"] = "5037"
        // Keep scrcpy's SDL helper out of the Dock. Rokid Control remains the
        // foreground application and raises the scrcpy window via Accessibility.
        environment["SDL_MAC_BACKGROUND_APP"] = "1"
        environment.removeValue(forKey: "DYLD_LIBRARY_PATH")
        environment.removeValue(forKey: "DYLD_FALLBACK_LIBRARY_PATH")
        return environment
    }

    private func failFromWorker(title: String, message: String) {
        logger?.log("ERROR \(title): \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.showFailure(title: title, message: message)
        }
    }

    private func showFailure(title: String, message: String) {
        closeConnectingWindow()
        keyboard?.setModalPresented(true)
        defer { keyboard?.setModalPresented(false) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "閉じる")
        if let logURL = logger?.logURL {
            alert.addButton(withTitle: "ログを表示")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([logURL])
            }
        } else {
            alert.runModal()
        }
        NSApp.terminate(nil)
    }
}

struct AppResources {
    let adb: URL
    let scrcpy: URL
    let scrcpyApp: URL
    let scrcpyIcons: URL
    let server: URL
    let watchdog: URL
}

@main
enum RokidControlMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = RokidControlApp()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
