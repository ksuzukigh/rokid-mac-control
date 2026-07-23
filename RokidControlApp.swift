import AppKit
import Foundation

final class RokidControlApp: NSObject, NSApplicationDelegate {
    private var controllerProcess: Process?
    private var logHandle: FileHandle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        startRokidControl()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let process = controllerProcess, process.isRunning {
            process.terminate()
        }
        try? logHandle?.close()
    }

    private func startRokidControl() {
        guard
            let resourceURL = Bundle.main.resourceURL,
            let toolPathData = try? Data(
                contentsOf: resourceURL.appendingPathComponent("tool_path.txt")
            ),
            let toolDirectory = String(data: toolPathData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !toolDirectory.isEmpty
        else {
            showFailure(
                title: "Rokid操作ツールが見つかりません",
                message: "セットアップをもう一度実行してください。"
            )
            return
        }

        let commandName = "Rokid操作【Wi-Fi・マウス・キーボード】.command"
        let commandURL = URL(fileURLWithPath: toolDirectory)
            .appendingPathComponent(commandName)

        guard FileManager.default.isExecutableFile(atPath: commandURL.path) else {
            showFailure(
                title: "Rokid操作ツールが見つかりません",
                message: "ダウンロードしたフォルダを移動した場合は、セットアップをもう一度実行してください。"
            )
            return
        }

        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true
        )
        let logURL = logsDirectory.appendingPathComponent("Rokid Control.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            let started = "\n\n=== Rokid Control started \(Date()) ===\n"
            try handle.write(contentsOf: Data(started.utf8))
            logHandle = handle

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [commandURL.path]
            process.currentDirectoryURL = URL(fileURLWithPath: toolDirectory)
            var environment = ProcessInfo.processInfo.environment
            environment["ROKID_GUI_MODE"] = "1"
            process.environment = environment
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { [weak self] finished in
                DispatchQueue.main.async {
                    self?.controlFinished(
                        status: finished.terminationStatus,
                        logURL: logURL
                    )
                }
            }

            controllerProcess = process
            try process.run()
        } catch {
            showFailure(
                title: "Rokid操作を開始できませんでした",
                message: "セットアップをもう一度実行してください。\n\n\(error.localizedDescription)"
            )
        }
    }

    private func controlFinished(status: Int32, logURL: URL) {
        try? logHandle?.close()
        logHandle = nil

        if status == 0 {
            NSApp.terminate(nil)
            return
        }

        let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let message: String
        if logText.contains("アクセシビリティ")
            || logText.contains("開いた設定画面で") {
            message = "キーボード操作の許可が必要です。開いた設定画面で「Rokid Control」を許可してから、もう一度起動してください。"
        } else if logText.contains("開発用5ピンケーブル") {
            message = "RokidへWi-Fi接続できませんでした。\n\nRokidで「Wi-Fi ON」を開いてから、もう一度お試しください。改善しない場合は開発用5ピンケーブルを接続してください。"
        } else {
            message = "Rokidへ接続できませんでした。\n\nRokidで「Wi-Fi ON」を開き、MacとRokidが同じWi-Fiにつながっていることを確認してください。"
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Rokid操作を開始できませんでした"
        alert.informativeText = message
        alert.addButton(withTitle: "閉じる")
        alert.addButton(withTitle: "ログを表示")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        }
        NSApp.terminate(nil)
    }

    private func showFailure(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "閉じる")
        alert.runModal()
        NSApp.terminate(nil)
    }
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
