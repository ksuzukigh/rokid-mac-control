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
    var onActivate: (() -> Void)?
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
        let shiftPressed = event.flags.contains(.maskShift)
        let screenSize = currentScreenSize()

        let handled: Bool
        switch keyCode {
        case 123:
            shiftPressed
                ? wakeAndTapCenterRow(offsetX: -(screenSize.0 / 15))
                : keyEvent("KEYCODE_DPAD_LEFT")
            handled = true
        case 124:
            shiftPressed
                ? wakeAndTapCenterRow(offsetX: screenSize.0 / 15)
                : keyEvent("KEYCODE_DPAD_RIGHT")
            handled = true
        case 49:
            handleSpace()
            handled = true
        case 36, 76:
            keyEvent("KEYCODE_ENTER")
            handled = true
        case 53:
            keyEvent("KEYCODE_BACK")
            handled = true
        case 4:
            wakeAndTapCenterRow(offsetX: 0)
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
        if pid == currentScrcpyPID || pid == ProcessInfo.processInfo.processIdentifier {
            return true
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

    private func keyEvent(_ androidKey: String) {
        actionQueue.async { [weak self] in
            guard let self else { return }
            let serial = connection.currentSerial()
            _ = connection.runADB([
                "-s", serial, "shell", "input", "keyevent", androidKey,
            ])
            logger.log("キー \(androidKey)")
        }
    }

    private func wakeAndTapCenterRow(offsetX: Int) {
        actionQueue.async { [weak self] in
            guard let self else { return }
            let screenSize = currentScreenSize()
            let serial = connection.currentSerial()
            _ = connection.runADB([
                "-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP",
            ])
            _ = connection.runADB([
                "-s", serial, "shell", "input", "keyevent", "KEYCODE_HOME",
            ])
            Thread.sleep(forTimeInterval: 0.35)
            _ = connection.runADB([
                "-s", serial, "shell", "input", "tap",
                "\(screenSize.0 / 2 + offsetX)", "\(screenSize.1 / 2)",
            ])
            logger.log("中央行タップ offsetX=\(offsetX)")
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
