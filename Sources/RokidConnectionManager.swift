import Foundation

enum RokidConnectionError: LocalizedError {
    case missingResource(String)
    case noDevice
    case wifiUnavailable
    case watchdogFailed

    var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            return "アプリ内の必要なファイルが見つかりません: \(name)"
        case .noDevice:
            return "Rokidへ接続できませんでした。Rokidで「Wi-Fi ON」を開いてから、もう一度お試しください。改善しない場合は開発用5ピンケーブルを接続してください。"
        case .wifiUnavailable:
            return "RokidをWi-Fiへ接続できませんでした。"
        case .watchdogFailed:
            return "Mac操作中のWi-Fi監視を開始できませんでした。"
        }
    }
}

final class RokidConnectionManager {
    private let adbURL: URL
    private let watchdogURL: URL
    private let runner: ProcessRunner
    private let logger: AppLogger
    private let addressURL: URL
    private let stateLock = NSLock()
    private var heartbeatTimer: DispatchSourceTimer?

    private let remoteWatchdog = "/data/local/tmp/rokid_wifi_watchdog.sh"
    private let remoteHeartbeat = "/data/local/tmp/rokid_mac_control_heartbeat"
    private let remoteWatchdogPID = "/data/local/tmp/rokid_mac_wifi_watchdog.pid"

    private(set) var serial = ""

    init(
        adbURL: URL,
        watchdogURL: URL,
        runner: ProcessRunner,
        logger: AppLogger
    ) throws {
        self.adbURL = adbURL
        self.watchdogURL = watchdogURL
        self.runner = runner
        self.logger = logger

        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Rokid Control",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )
        addressURL = appSupport.appendingPathComponent("wifi-address.txt")
    }

    func prepareADBServer() {
        _ = adb(["start-server"], timeout: 8)
    }

    func connectForStartup() throws -> String {
        if let saved = readSavedAddress(), connect(saved) {
            return use(saved)
        }

        if let discovered = discoverSecureWiFi(), connect(discovered) {
            return use(discovered)
        }

        logger.log("Wi-Fi接続またはUSB接続を待っています")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let discovered = discoverSecureWiFi(), connect(discovered) {
                return use(discovered)
            }

            if let usbSerial = findUSBDevice() {
                return try recoverWiFiUsingUSB(usbSerial)
            }
            Thread.sleep(forTimeInterval: 1)
        }

        throw RokidConnectionError.noDevice
    }

    func reconnect() -> String? {
        let oldSerial = currentSerial()
        if !oldSerial.isEmpty {
            _ = adb(["disconnect", oldSerial], timeout: 3)
        }

        for _ in 0..<20 {
            if !oldSerial.isEmpty && connect(oldSerial) {
                return use(oldSerial)
            }
            if let discovered = discoverSecureWiFi(), connect(discovered) {
                return use(discovered)
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    func getScreenSize() -> (Int, Int) {
        let current = currentSerial()
        let result = adb(["-s", current, "shell", "wm", "size"], timeout: 5)
        let pattern = #"(\d+)\s*[x×]\s*(\d+)"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: result.output,
                range: NSRange(result.output.startIndex..., in: result.output)
            ),
            let widthRange = Range(match.range(at: 1), in: result.output),
            let heightRange = Range(match.range(at: 2), in: result.output),
            let width = Int(result.output[widthRange]),
            let height = Int(result.output[heightRange])
        else {
            return (480, 640)
        }
        return (width, height)
    }

    func startMacMode() throws {
        stopHeartbeat()
        let current = currentSerial()
        guard !current.isEmpty else {
            throw RokidConnectionError.watchdogFailed
        }

        guard adb([
            "-s", current, "push", watchdogURL.path, remoteWatchdog,
        ], timeout: 8).succeeded else {
            throw RokidConnectionError.watchdogFailed
        }
        guard adb([
            "-s", current, "shell", "chmod", "700", remoteWatchdog,
        ], timeout: 5).succeeded else {
            throw RokidConnectionError.watchdogFailed
        }

        let oldPID = adb([
            "-s", current, "shell", "cat", remoteWatchdogPID,
        ], timeout: 3).output.trimmingCharacters(in: .whitespacesAndNewlines)
        if Int(oldPID) != nil {
            _ = adb(["-s", current, "shell", "kill", oldPID], timeout: 3)
        }

        _ = adb([
            "-s", current, "shell", "rm", "-f", remoteWatchdogPID,
        ], timeout: 3)
        guard adb([
            "-s", current, "shell", "touch", remoteHeartbeat,
        ], timeout: 3).succeeded else {
            throw RokidConnectionError.watchdogFailed
        }

        let launch = "setsid sh '\(remoteWatchdog)' 20 </dev/null >/dev/null 2>&1 &"
        guard adb([
            "-s", current, "shell", launch,
        ], timeout: 5).succeeded else {
            throw RokidConnectionError.watchdogFailed
        }
        Thread.sleep(forTimeInterval: 1)

        let newPID = adb([
            "-s", current, "shell", "cat", remoteWatchdogPID,
        ], timeout: 3).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Int(newPID) != nil else {
            throw RokidConnectionError.watchdogFailed
        }

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "RokidControl.Heartbeat")
        )
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let address = self.currentSerial()
            guard !address.isEmpty else { return }
            _ = self.adb([
                "-s", address, "shell", "touch", self.remoteHeartbeat,
            ], timeout: 3)
        }
        timer.resume()
        heartbeatTimer = timer
        logger.log("Mac操作モード開始 serial=\(current) watchdog=\(newPID)")
    }

    func stopMacMode() {
        stopHeartbeat()
        let current = currentSerial()
        guard !current.isEmpty, isConnected(current) else { return }

        let pid = adb([
            "-s", current, "shell", "cat", remoteWatchdogPID,
        ], timeout: 2).output.trimmingCharacters(in: .whitespacesAndNewlines)
        if Int(pid) != nil {
            _ = adb(["-s", current, "shell", "kill", pid], timeout: 2)
        }
        _ = adb([
            "-s", current, "shell", "rm", "-f",
            remoteHeartbeat, remoteWatchdogPID,
        ], timeout: 3)
        logger.log("Mac操作モード終了")
    }

    func shutdownADBServer() {
        _ = adb(["kill-server"], timeout: 5)
    }

    func runADB(_ arguments: [String], timeout: TimeInterval = 5) -> CommandResult {
        adb(arguments, timeout: timeout)
    }

    func currentSerial() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return serial
    }

    func isCurrentConnectionAlive() -> Bool {
        let current = currentSerial()
        return !current.isEmpty && isConnected(current)
    }

    private func use(_ address: String) -> String {
        stateLock.lock()
        serial = address
        stateLock.unlock()
        try? Data("\(address)\n".utf8).write(to: addressURL, options: .atomic)
        logger.log("Wi-Fi接続成功 serial=\(address)")
        return address
    }

    private func readSavedAddress() -> String? {
        guard
            let data = try? Data(contentsOf: addressURL),
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func connect(_ address: String) -> Bool {
        _ = adb(["connect", address], timeout: 5)
        return isConnected(address)
    }

    private func isConnected(_ address: String) -> Bool {
        adb(["-s", address, "get-state"], timeout: 3)
            .output
            .trimmingCharacters(in: .whitespacesAndNewlines) == "device"
    }

    private func findUSBDevice() -> String? {
        let output = adb(["devices"], timeout: 3).output
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }
            let candidate = String(fields[0])
            if fields[1] == "device" && !candidate.contains(":") {
                return candidate
            }
        }
        return nil
    }

    private func discoverSecureWiFi() -> String? {
        let mdns = adb(["mdns", "services"], timeout: 3).output
        for line in mdns.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if let index = fields.firstIndex(of: "_adb-tls-connect._tcp"),
               fields.indices.contains(index + 1) {
                return String(fields[index + 1])
            }
        }
        return discoverWithBonjour()
    }

    private func discoverWithBonjour() -> String? {
        let dnsSD = URL(fileURLWithPath: "/usr/bin/dns-sd")
        let browse = runner.run(
            dnsSD,
            arguments: ["-B", "_adb-tls-connect._tcp", "local"],
            timeout: 1.2
        ).output

        var serviceName: String?
        for line in browse.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.contains("Add") else { continue }
            if let typeIndex = fields.firstIndex(where: {
                $0.hasPrefix("_adb-tls-connect._tcp")
            }), fields.indices.contains(typeIndex + 1) {
                serviceName = String(fields[typeIndex + 1])
            }
        }
        guard let serviceName else { return nil }

        let lookup = runner.run(
            dnsSD,
            arguments: [
                "-L", serviceName, "_adb-tls-connect._tcp", "local",
            ],
            timeout: 1.2
        ).output
        for line in lookup.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let at = fields.firstIndex(of: "at"),
                  fields.indices.contains(at + 1) else {
                continue
            }
            return String(fields[at + 1]).replacingOccurrences(of: ".:", with: ":")
        }
        return nil
    }

    private func recoverWiFiUsingUSB(_ usbSerial: String) throws -> String {
        logger.log("USB接続からWi-Fiを復旧 serial=\(usbSerial)")
        var status = adb([
            "-s", usbSerial, "shell", "cmd", "wifi", "status",
        ], timeout: 5).output
        var openedSettings = false

        if status.contains("Wifi is disabled") {
            _ = adb([
                "-s", usbSerial, "shell", "input", "keyevent", "KEYCODE_WAKEUP",
            ], timeout: 3)
            _ = adb([
                "-s", usbSerial, "shell", "wm", "dismiss-keyguard",
            ], timeout: 3)
            _ = adb([
                "-s", usbSerial, "shell", "am", "start", "-a",
                "android.settings.WIFI_SETTINGS",
            ], timeout: 5)

            for _ in 0..<3 {
                Thread.sleep(forTimeInterval: 2)
                _ = adb([
                    "-s", usbSerial, "shell", "input", "keyevent",
                    "KEYCODE_WAKEUP",
                ], timeout: 3)
                Thread.sleep(forTimeInterval: 0.3)
                _ = adb([
                    "-s", usbSerial, "shell", "input", "keyevent",
                    "KEYCODE_ENTER",
                ], timeout: 3)
                Thread.sleep(forTimeInterval: 1)
                status = adb([
                    "-s", usbSerial, "shell", "cmd", "wifi", "status",
                ], timeout: 5).output
                if !status.contains("Wifi is disabled") {
                    break
                }
            }
            openedSettings = true
        }

        var ipAddress = ""
        for _ in 0..<20 {
            status = adb([
                "-s", usbSerial, "shell", "cmd", "wifi", "status",
            ], timeout: 5).output
            let addressOutput = adb([
                "-s", usbSerial, "shell", "ip", "-4", "addr", "show", "wlan0",
            ], timeout: 5).output
            ipAddress = parseIPv4(from: addressOutput) ?? ""
            if !ipAddress.isEmpty && status.contains("Wifi is connected to") {
                break
            }
            ipAddress = ""
            Thread.sleep(forTimeInterval: 1)
        }
        guard !ipAddress.isEmpty else {
            throw RokidConnectionError.wifiUnavailable
        }

        if openedSettings {
            _ = adb([
                "-s", usbSerial, "shell", "input", "keyevent", "KEYCODE_WAKEUP",
            ], timeout: 3)
            _ = adb([
                "-s", usbSerial, "shell", "input", "keyevent", "KEYCODE_HOME",
            ], timeout: 3)
        }

        let address = "\(ipAddress):5555"
        _ = adb(["disconnect", address], timeout: 3)
        _ = adb(["-s", usbSerial, "tcpip", "5555"], timeout: 8)
        Thread.sleep(forTimeInterval: 2)
        for _ in 0..<10 {
            if connect(address) {
                return use(address)
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw RokidConnectionError.noDevice
    }

    private func parseIPv4(from text: String) -> String? {
        let pattern = #"\binet\s+(\d+\.\d+\.\d+\.\d+)/"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ),
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range])
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func adb(
        _ arguments: [String],
        timeout: TimeInterval
    ) -> CommandResult {
        runner.run(adbURL, arguments: arguments, timeout: timeout)
    }
}
