import AppKit
import ApplicationServices
import Foundation

final class KeyboardController {
    private let connection: RokidConnectionManager
    private let logger: AppLogger
    private let scrcpyAppURL: URL
    private let actionQueue = DispatchQueue(label: "RokidControl.KeyboardActions")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingSpace: DispatchWorkItem?
    private let screenSizeLock = NSLock()
    private var width = 480
    private var height = 640
    private let targetPIDLock = NSLock()
    private var scrcpyProcessIdentifier: pid_t?
    private let modalLock = NSLock()
    private var isModalPresented = false
    // Access only from actionQueue.
    private var launcherStateCache: (value: Bool, checkedAt: Date)?
    // Access only from actionQueue.
    private var navigationState = KeyboardNavigationState()
    var onActivate: (() -> Void)?
    var onNavigationSelection: ((LowerNavigationItem?) -> Void)?
    var onQuit: (() -> Void)?

    init(
        connection: RokidConnectionManager,
        logger: AppLogger,
        scrcpyAppURL: URL
    ) {
        self.connection = connection
        self.logger = logger
        self.scrcpyAppURL = scrcpyAppURL.standardizedFileURL
    }

    @discardableResult
    func updateScreenSize() -> (Int, Int) {
        let size = connection.getScreenSize()
        screenSizeLock.lock()
        width = size.0
        height = size.1
        screenSizeLock.unlock()
        logger.log("画面サイズ \(size.0)x\(size.1)")
        return size
    }

    func currentScreenSize() -> (Int, Int) {
        screenSizeLock.lock()
        defer { screenSizeLock.unlock() }
        return (width, height)
    }

    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        let callback: CGEventTapCallBack = {
            _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let controller = Unmanaged<KeyboardController>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            return controller.handle(type: type, event: event)
        }

        // The event tap stores an unretained pointer. RokidControlApp must call
        // stop() before releasing this controller.
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let eventTap else { return false }

        let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        )
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        logger.log("Swiftキーボード制御開始")
        return true
    }

    func stop() {
        pendingSpace?.cancel()
        pendingSpace = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    func updateScrcpyProcessIdentifier(_ processIdentifier: pid_t?) {
        targetPIDLock.lock()
        scrcpyProcessIdentifier = processIdentifier
        targetPIDLock.unlock()
    }

    /// アプリ自身の確認・接続待ち画面では、キーをRokidへ転送しない。
    func setModalPresented(_ presented: Bool) {
        modalLock.lock()
        isModalPresented = presented
        modalLock.unlock()
    }

    private func isAppModalPresented() -> Bool {
        modalLock.lock()
        defer { modalLock.unlock() }
        return isModalPresented
    }

    private func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                logger.log("キーボード入力監視を自動復旧")
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown || type == .rightMouseDown {
            // During a click, eventTargetUnixProcessID may still identify the
            // previously active app. Use the actual frontmost window under the
            // pointer so covered scrcpy regions do not steal focus.
            if pointTargetsScrcpyWindow(event.location) {
                resetNavigationMode()
                DispatchQueue.main.async { [weak self] in
                    self?.onActivate?()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return Unmanaged.passUnretained(event)
        }
        guard eventTargetsScrcpy(event) else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 12, event.flags.contains(.maskCommand) {
            DispatchQueue.main.async { [weak self] in
                self?.onQuit?()
            }
            return nil
        }

        let handled: Bool
        switch keyCode {
        case 123:
            handleHorizontalNavigation(
                offset: -1,
                upperRowKey: "KEYCODE_DPAD_LEFT"
            )
            handled = true
        case 124:
            handleHorizontalNavigation(
                offset: 1,
                upperRowKey: "KEYCODE_DPAD_RIGHT"
            )
            handled = true
        case 125:
            handleDownNavigation()
            handled = true
        case 126:
            handleUpNavigation()
            handled = true
        case 49:
            resetNavigationMode()
            handleSpace()
            handled = true
        case 36, 76:
            handleEnter()
            handled = true
        case 53:
            handleBack()
            handled = true
        case 4:
            openHome()
            handled = true
        default:
            handled = false
        }

        return handled ? nil : Unmanaged.passUnretained(event)
    }

    private func eventTargetsScrcpy(_ event: CGEvent) -> Bool {
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        targetPIDLock.lock()
        let currentScrcpyPID = scrcpyProcessIdentifier
        targetPIDLock.unlock()

        // An LSUIElement helper may deliver keystrokes to either its own PID or
        // the regular parent app. Both belong to Rokid Control, while another
        // foreground app retains its own PID and is left untouched.
        if pid == currentScrcpyPID {
            return true
        }
        if pid == ProcessInfo.processInfo.processIdentifier {
            return !isAppModalPresented()
        }
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        return application.bundleURL?.standardizedFileURL == scrcpyAppURL
    }

    private func pointTargetsScrcpyWindow(_ point: CGPoint) -> Bool {
        targetPIDLock.lock()
        let currentScrcpyPID = scrcpyProcessIdentifier
        targetPIDLock.unlock()
        guard let currentScrcpyPID else { return false }

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        // CGWindowList is ordered front to back. Only the first normal,
        // visible window under the pointer is the window the user clicked.
        for window in windows {
            guard
                let layer = window[kCGWindowLayer as String] as? NSNumber,
                layer.intValue == 0,
                let boundsDictionary = window[
                    kCGWindowBounds as String
                ] as? NSDictionary,
                let bounds = CGRect(
                    dictionaryRepresentation:
                        boundsDictionary as CFDictionary
                ),
                bounds.contains(point)
            else {
                continue
            }
            if let alpha = window[
                kCGWindowAlpha as String
            ] as? NSNumber, alpha.doubleValue <= 0 {
                continue
            }
            guard let owner = window[
                kCGWindowOwnerPID as String
            ] as? NSNumber else {
                return false
            }
            return owner.int32Value == currentScrcpyPID
        }
        return false
    }

    func resetNavigationMode() {
        actionQueue.async { [weak self] in
            guard let self else { return }
            if navigationState.leaveLowerRow() {
                publishNavigationStatus(nil)
                logger.log("キーボード選択 上段")
            }
        }
    }

    private func handleHorizontalNavigation(
        offset: Int,
        upperRowKey: String
    ) {
        actionQueue.async { [weak self] in
            guard let self else { return }
            if let item = navigationState.moveLowerRow(by: offset) {
                publishNavigationStatus(item)
                logger.log("キーボード選択 下段 \(item.title)")
                return
            }
            sendKeyEvent(upperRowKey)
        }
    }

    private func handleDownNavigation() {
        actionQueue.async { [weak self] in
            guard let self else { return }
            if let item = navigationState.lowerItem {
                // 下段が最下段なので、これ以上は移動しない。
                publishNavigationStatus(item)
                return
            }
            guard isLauncherActive() else {
                sendKeyEvent("KEYCODE_DPAD_DOWN")
                return
            }
            let item = navigationState.enterLowerRow()
            publishNavigationStatus(item)
            logger.log("キーボード選択 下段 \(item.title)")
        }
    }

    private func handleUpNavigation() {
        actionQueue.async { [weak self] in
            guard let self else { return }
            if navigationState.leaveLowerRow() {
                publishNavigationStatus(nil)
                logger.log("キーボード選択 上段")
                return
            }
            sendKeyEvent("KEYCODE_DPAD_UP")
        }
    }

    private func handleEnter() {
        actionQueue.async { [weak self] in
            guard let self else { return }
            guard let item = navigationState.lowerItem else {
                sendKeyEvent("KEYCODE_ENTER")
                return
            }
            _ = navigationState.leaveLowerRow()
            publishNavigationStatus(nil)
            wakeAndTapHomeRowItem(item)
        }
    }

    private func handleBack() {
        actionQueue.async { [weak self] in
            guard let self else { return }
            if navigationState.leaveLowerRow() {
                publishNavigationStatus(nil)
                logger.log("キーボード選択 上段")
                return
            }
            sendKeyEvent("KEYCODE_BACK")
        }
    }

    private func openHome() {
        actionQueue.async { [weak self] in
            guard let self else { return }
            _ = navigationState.leaveLowerRow()
            publishNavigationStatus(nil)
            wakeAndTapHomeRowItem(.home)
        }
    }

    private func isLauncherActive() -> Bool {
        if let cache = launcherStateCache,
           Date().timeIntervalSince(cache.checkedAt) < 2 {
            return cache.value
        }
        let serial = connection.currentSerial()
        let result = connection.runADB([
            "-s", serial, "shell",
            "dumpsys activity activities | grep 'ResumedActivity:'",
        ], timeout: 3)
        if result.timedOut {
            logger.log("ホーム画面判定がタイムアウト（前回の判定を使用）")
            return launcherStateCache?.value ?? false
        }
        let isLauncher = result.output.contains(
            "com.rokid.os.sprite.launcher/"
        )
        launcherStateCache = (isLauncher, Date())
        return isLauncher
    }

    private func sendKeyEvent(_ androidKey: String) {
        let serial = connection.currentSerial()
        _ = connection.runADB([
            "-s", serial, "shell", "input", "keyevent", androidKey,
        ])
        logger.log("キー \(androidKey)")
    }

    private func wakeAndTapHomeRowItem(_ item: LowerNavigationItem) {
        let screenSize = currentScreenSize()
        let serial = connection.currentSerial()
        _ = connection.runADB([
            "-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP",
        ])
        _ = connection.runADB([
            "-s", serial, "shell", "input", "keyevent", "KEYCODE_HOME",
        ])
        Thread.sleep(forTimeInterval: 0.35)
        let point = item.devicePoint(
            forScreenWidth: screenSize.0,
            height: screenSize.1
        )
        _ = connection.runADB([
            "-s", serial, "shell", "input", "tap",
            "\(Int(point.x))", "\(Int(point.y))",
        ])
        logger.log("下段を開く \(item.title)")
    }

    private func publishNavigationStatus(_ item: LowerNavigationItem?) {
        DispatchQueue.main.async { [weak self] in
            self?.onNavigationSelection?(item)
        }
    }

    private func handleSpace() {
        if let pendingSpace {
            pendingSpace.cancel()
            self.pendingSpace = nil
            doubleTapCenter()
            return
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSpace = nil
            self.tapCenter()
        }
        pendingSpace = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func tapCenter() {
        actionQueue.async { [weak self] in
            guard let self else { return }
            let screenSize = currentScreenSize()
            let serial = connection.currentSerial()
            _ = connection.runADB([
                "-s", serial, "shell", "input", "tap",
                "\(screenSize.0 / 2)", "\(screenSize.1 / 2)",
            ])
            logger.log("中央タップ")
        }
    }

    private func doubleTapCenter() {
        actionQueue.async { [weak self] in
            guard let self else { return }
            let screenSize = currentScreenSize()
            let serial = connection.currentSerial()
            let arguments = [
                "-s", serial, "shell", "input", "tap",
                "\(screenSize.0 / 2)", "\(screenSize.1 / 2)",
            ]
            _ = connection.runADB(arguments)
            Thread.sleep(forTimeInterval: 0.08)
            _ = connection.runADB(arguments)
            logger.log("中央ダブルタップ")
        }
    }
}
