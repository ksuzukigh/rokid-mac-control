import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class RokidControlApp: NSObject, NSApplicationDelegate {
    private enum DisplayMode {
        case standard
        case vision
    }

    private var logger: AppLogger?
    private var runner: ProcessRunner?
    private var connection: RokidConnectionManager?
    private var keyboard: KeyboardController?
    private var scrcpyApplication: NSRunningApplication?
    private var visionController: VisionModeController?
    private var visionRecoveryInProgress = false
    private var displayMode: DisplayMode = .standard
    private var isTerminating = false
    private var scrcpyRestartCount = 0
    private var lastScrcpyStart = Date.distantPast
    private let workQueue = DispatchQueue(label: "RokidControl.MainWork")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        NSApp.activate(ignoringOtherApps: true)

        guard let selectedMode = chooseDisplayMode() else {
            NSApp.terminate(nil)
            return
        }
        displayMode = selectedMode

        guard requestAccessibilityIfNeeded() else {
            showFailure(
                title: "キーボード操作の許可が必要です",
                message: "開いた設定画面で「Rokid Control」を許可してから、もう一度起動してください。"
            )
            return
        }
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
            logger.log(
                "表示モード \(displayMode == .vision ? "視界表示" : "通常表示")"
            )
            let resources = try locateResources()
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

            workQueue.async { [weak self] in
                guard let self else { return }
                do {
                    connection.prepareADBServer()
                    _ = try connection.connectForStartup()
                    try self.startMacModeWithRetry()

                    let keyboard = KeyboardController(
                        connection: connection,
                        logger: logger
                    )
                    keyboard.updateScreenSize()
                    DispatchQueue.main.sync {
                        self.keyboard = keyboard
                        if !keyboard.start() {
                            self.failFromWorker(
                                title: "キーボード操作を開始できませんでした",
                                message: "macOSのアクセシビリティ設定を確認してください。"
                            )
                        }
                    }
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
                                environment: environment
                            )
                        }
                    }
                } catch {
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

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }

    private func chooseDisplayMode() -> DisplayMode? {
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
            return warning.runModal() == .alertFirstButtonReturn
                ? .vision
                : chooseDisplayMode()
        case .alertSecondButtonReturn:
            return .standard
        default:
            return nil
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
                    self.lastScrcpyStart = Date()
                    self.keyboard?.updateScrcpyProcessIdentifier(
                        runningApplication.processIdentifier
                    )
                    logger.log(
                        "scrcpy開始 pid=\(runningApplication.processIdentifier) serial=\(serial)"
                    )
                    self.focusScrcpy(
                        processIdentifier: runningApplication.processIdentifier
                    )
                    self.workQueue.async { [weak self] in
                        self?.monitorScrcpy(
                            runningApplication,
                            resources: resources,
                            environment: environment
                        )
                    }
                }
            }
        }
    }

    private func startVisionController(
        connection: RokidConnectionManager,
        keyboard: KeyboardController,
        logger: AppLogger,
        resources: AppResources,
        environment: [String: String]
    ) {
        guard !isTerminating else { return }
        let controller = VisionModeController(
            connection: connection,
            keyboard: keyboard,
            logger: logger,
            resources: resources,
            environment: environment,
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
                    guard connection.reconnect() != nil else {
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
                        environment: environment
                    )
                }
            }
        }
    }

    private func monitorScrcpy(
        _ application: NSRunningApplication,
        resources: AppResources,
        environment: [String: String]
    ) {
        while !application.isTerminated && !isTerminating {
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard !isTerminating else { return }
        handleScrcpyTermination(
            resources: resources,
            environment: environment
        )
    }

    private func focusScrcpy(processIdentifier: pid_t) {
        for delay in [1.0, 2.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.isTerminating == false else { return }
                NSApp.activate(ignoringOtherApps: true)
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
        keyboard?.updateScrcpyProcessIdentifier(nil)
        guard !isTerminating else { return }

        guard let connection else { return }
        if connection.isCurrentConnectionAlive() {
            cleanup()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return
        }

        let elapsed = Date().timeIntervalSince(lastScrcpyStart)
        if elapsed < 5 {
            scrcpyRestartCount += 1
        } else {
            scrcpyRestartCount = 0
        }
        if scrcpyRestartCount >= 2 {
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
        guard connection.reconnect() != nil else {
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

            if alert.runModal() == .alertFirstButtonReturn {
                self.scrcpyRestartCount = 0
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
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
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

    private func cleanup() {
        if isTerminating { return }
        isTerminating = true
        keyboard?.stop()
        keyboard = nil
        visionController?.stop()
        visionController = nil
        visionRecoveryInProgress = false

        if let application = scrcpyApplication, !application.isTerminated {
            application.terminate()
        }
        connection?.stopMacMode()
        connection?.shutdownADBServer()
        logger?.log("Rokid Control終了")
        logger?.close()
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
        cleanup()
        DispatchQueue.main.async { [weak self] in
            self?.showFailure(title: title, message: message)
        }
    }

    private func showFailure(title: String, message: String) {
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
