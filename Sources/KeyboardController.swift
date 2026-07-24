import AppKit
import ApplicationServices
import Foundation

final class KeyboardController {
    private let connection: RokidConnectionManager
    private let logger: AppLogger
    private let actionQueue = DispatchQueue(label: "RokidControl.KeyboardActions")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingSpace: DispatchWorkItem?
    private var width = 480
    private var height = 640
    private let targetPIDLock = NSLock()
    private var scrcpyProcessIdentifier: pid_t?

    init(connection: RokidConnectionManager, logger: AppLogger) {
        self.connection = connection
        self.logger = logger
    }

    func updateScreenSize() {
        let size = connection.getScreenSize()
        width = size.0
        height = size.1
        logger.log("画面サイズ \(width)x\(height)")
    }

    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
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
        let shiftPressed = event.flags.contains(.maskShift)

        let handled: Bool
        switch keyCode {
        case 123:
            shiftPressed ? openBottomIcon(offset: -(width / 15)) : keyEvent("KEYCODE_DPAD_LEFT")
            handled = true
        case 124:
            shiftPressed ? openBottomIcon(offset: width / 15) : keyEvent("KEYCODE_DPAD_RIGHT")
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
            openBottomIcon(offset: 0)
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
        let executable = application.executableURL?.lastPathComponent.lowercased()
        let name = application.localizedName?.lowercased()
        return executable == "scrcpy" || name == "scrcpy"
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

    private func openBottomIcon(offset: Int) {
        actionQueue.async { [weak self] in
            guard let self else { return }
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
                "\(width / 2 + offset)", "\(height / 2)",
            ])
            logger.log("下段アイコン offset=\(offset)")
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
            let serial = connection.currentSerial()
            _ = connection.runADB([
                "-s", serial, "shell", "input", "tap",
                "\(width / 2)", "\(height / 2)",
            ])
            logger.log("中央タップ")
        }
    }

    private func doubleTapCenter() {
        actionQueue.async { [weak self] in
            guard let self else { return }
            let serial = connection.currentSerial()
            let arguments = [
                "-s", serial, "shell", "input", "tap",
                "\(width / 2)", "\(height / 2)",
            ]
            _ = connection.runADB(arguments)
            Thread.sleep(forTimeInterval: 0.08)
            _ = connection.runADB(arguments)
            logger.log("中央ダブルタップ")
        }
    }
}
