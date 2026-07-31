import AppKit
import ApplicationServices
import Foundation

/// Rokidの画面サイズを複数のスレッドから安全に読み書きする入れ物。
private final class ScreenSizeStore {
    private let lock = NSLock()
    private var size = (480, 640)

    func get() -> (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return size
    }

    func set(_ newValue: (Int, Int)) {
        lock.lock()
        size = newValue
        lock.unlock()
    }
}

/// キーボード操作をADB経由でRokidへ届ける。
///
/// `KeyboardCommandRouter`から呼ばれる。命令の並びを決めるのはRouter側で、
/// ここは実際にADBを実行するだけに絞ってある。
private final class ADBCommandSink: RokidCommandSink {
    private let connection: RokidConnectionManager
    private let logger: AppLogger
    private let screenSize: ScreenSizeStore

    init(
        connection: RokidConnectionManager,
        logger: AppLogger,
        screenSize: ScreenSizeStore
    ) {
        self.connection = connection
        self.logger = logger
        self.screenSize = screenSize
    }

    func send(_ command: RokidCommand) {
        switch command {
        case .keyEvent(let androidKey):
            sendKeyEvent(androidKey)
        case .openShortcut(let shortcut):
            openShortcut(shortcut)
        }
    }

    private func sendKeyEvent(_ androidKey: String) {
        let serial = connection.currentSerial()
        _ = connection.runADB([
            "-s", serial, "shell", "input", "keyevent", androidKey,
        ])
        logger.log("キー \(androidKey)")
    }

    private func openShortcut(_ shortcut: LauncherShortcut) {
        let size = screenSize.get()
        let serial = connection.currentSerial()
        _ = connection.runADB([
            "-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP",
        ])
        _ = connection.runADB([
            "-s", serial, "shell", "input", "keyevent", "KEYCODE_HOME",
        ])
        waitForLauncher(serial: serial)
        let point = shortcut.devicePoint(
            forScreenWidth: size.0,
            height: size.1
        )
        _ = connection.runADB([
            "-s", serial, "shell", "input", "tap",
            "\(Int(point.x))", "\(Int(point.y))",
        ])
        logger.log("下段を開く \(shortcut.title)")
    }

    private func waitForLauncher(serial: String) {
        for attempt in 1...8 {
            let result = connection.runADB([
                "-s", serial, "shell", "dumpsys", "activity", "activities",
            ], timeout: 2)
            if result.succeeded,
               LauncherActivityPolicy.isLauncherForeground(result.output) {
                // Activityが前面になった直後の切替アニメーションがタップを
                // 取りこぼさないよう、短い安定待ちを置く。
                Thread.sleep(forTimeInterval: 0.2)
                if attempt > 1 {
                    logger.log(
                        "ホーム画面準備を待ってショートカット実行 attempt=\(attempt)"
                    )
                }
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // 状態を読めなくても従来どおり操作は試す。接続の一時的な遅延で
        // M/H/Aが完全に使えなくなることを避ける。
        Thread.sleep(forTimeInterval: 0.25)
        logger.log("ホーム画面準備を確認できないままショートカット実行")
    }
}

final class KeyboardController {
    private let connection: RokidConnectionManager
    private let logger: AppLogger
    private let scrcpyAppURL: URL
    private let actionQueue = DispatchQueue(label: "RokidControl.KeyboardActions")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let screenSize: ScreenSizeStore
    private let targetPIDLock = NSLock()
    private var scrcpyProcessIdentifier: pid_t?
    private let modalLock = NSLock()
    private var isModalPresented = false
    // Access only from actionQueue.
    private let router: KeyboardCommandRouter
    var onActivate: (() -> Void)?
    /// アプリ一覧を選んでいる間だけ`true`。操作案内の切り替えに使う。
    var onAppSelectionChanged: ((Bool) -> Void)?
    var onQuit: (() -> Void)?

    init(
        connection: RokidConnectionManager,
        logger: AppLogger,
        scrcpyAppURL: URL
    ) {
        self.connection = connection
        self.logger = logger
        self.scrcpyAppURL = scrcpyAppURL.standardizedFileURL

        let screenSize = ScreenSizeStore()
        self.screenSize = screenSize
        let sink = ADBCommandSink(
            connection: connection,
            logger: logger,
            screenSize: screenSize
        )
        router = KeyboardCommandRouter(sink: sink)
        router.onSelectionChanged = { [weak self] isSelecting in
            guard let self else { return }
            logger.log(
                isSelecting ? "アプリ一覧の選択を開始" : "アプリ一覧の選択を終了"
            )
            DispatchQueue.main.async { [weak self] in
                self?.onAppSelectionChanged?(isSelecting)
            }
        }
    }

    @discardableResult
    func updateScreenSize() -> (Int, Int) {
        let size = connection.getScreenSize()
        screenSize.set(size)
        logger.log("画面サイズ \(size.0)x\(size.1)")
        return size
    }

    func currentScreenSize() -> (Int, Int) {
        screenSize.get()
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
                focusWindow()
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

        guard let key = Self.rokidKey(forKeyCode: keyCode, flags: event.flags)
        else {
            // Spaceを含め、割り当てのないキーはそのままmacOSへ渡す。
            return Unmanaged.passUnretained(event)
        }

        actionQueue.async { [weak self] in
            self?.router.handle(key)
        }
        return nil
    }

    /// OSの仮想キーコードをRokid操作の意味へ変換する。
    ///
    /// 修飾キーを伴う入力は、Macのショートカット（⌘A など）を邪魔しないよう
    /// Rokid操作として扱わない。Spaceには何も割り当てない。
    private static func rokidKey(
        forKeyCode keyCode: Int64,
        flags: CGEventFlags
    ) -> RokidKey? {
        let hasModifier = flags.contains(.maskCommand)
            || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)

        switch keyCode {
        case 123:
            return hasModifier ? nil : .left
        case 124:
            return hasModifier ? nil : .right
        case 36, 76:
            return hasModifier ? nil : .enter
        case 53:
            return hasModifier ? nil : .escape
        case 4:
            return hasModifier ? nil : .home
        case 46:
            return hasModifier ? nil : .memo
        case 0:
            return hasModifier ? nil : .applications
        default:
            return nil
        }
    }

    private func eventTargetsScrcpy(_ event: CGEvent) -> Bool {
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        targetPIDLock.lock()
        let currentScrcpyPID = scrcpyProcessIdentifier
        targetPIDLock.unlock()
        let modalPresented = isAppModalPresented()

        // カメラ受信の切替直後は、終了済みの受信プロセスIDがイベントへ
        // 一時的に残ることがある。Rokid Control自身が前面なら受け付ける。
        if KeyboardFocusPolicy.accepts(
            appIsActive: NSApp.isActive,
            modalPresented: modalPresented,
            targetBelongsToRokidControl: false
        ) {
            return true
        }

        // An LSUIElement helper may deliver keystrokes to either its own PID or
        // the regular parent app. Both belong to Rokid Control, while another
        // foreground app retains its own PID and is left untouched.
        var targetBelongsToRokidControl =
            pid == currentScrcpyPID
            || pid == ProcessInfo.processInfo.processIdentifier
        if !targetBelongsToRokidControl,
           let application = NSRunningApplication(processIdentifier: pid) {
            targetBelongsToRokidControl =
                application.bundleURL?.standardizedFileURL == scrcpyAppURL
        }
        return KeyboardFocusPolicy.accepts(
            appIsActive: false,
            modalPresented: modalPresented,
            targetBelongsToRokidControl: targetBelongsToRokidControl
        )
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

    /// Macの別アプリからRokid画面へ戻るクリックでは選択状態を維持する。
    func focusWindow() {
        actionQueue.async { [weak self] in
            self?.router.focusWindow()
        }
    }

    /// ライブ映像上のタップなど、Rokid側を直接操作した場合は選択を終える。
    func endAppSelection() {
        actionQueue.async { [weak self] in
            self?.router.endSelection()
        }
    }
}
