import AppKit
import ApplicationServices
import Foundation

final class RokidControlApp: NSObject, NSApplicationDelegate {
    private var logger: AppLogger?
    private var runner: ProcessRunner?
    private var connection: RokidConnectionManager?
    private var keyboard: KeyboardController?
    private var scrcpyApplication: NSRunningApplication?
    private var isTerminating = false
    private let workQueue = DispatchQueue(label: "RokidControl.MainWork")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        guard requestAccessibilityIfNeeded() else {
            showFailure(
                title: "キーボード操作の許可が必要です",
                message: "開いた設定画面で「Rokid Control」を許可してから、もう一度起動してください。"
            )
            return
        }

        do {
            let logger = try AppLogger()
            self.logger = logger
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
                    self.launchScrcpy(resources: resources, environment: environment)
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
            "--window-title=Rokid Glasses RV101（Mac操作モード）",
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
        environment["ANDROID_ADB_SERVER_PORT"] = "5041"
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
