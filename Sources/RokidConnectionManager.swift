import Foundation

enum RokidConnectionError: LocalizedError {
    case missingResource(String)
    case noDevice
    case wifiUnavailable
    case watchdogFailed
    case cancelled

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
        case .cancelled:
            return "接続をキャンセルしました。"
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

    func connectForStartup(
        onProgress: (String) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> String {
        try checkCancellation(isCancelled)
        onProgress("Rokidを探しています…")
        // A connected development cable is the most stable path and does not
        // require changing the glasses' Wi-Fi state.
        if let usbSerial = findUSBDevice() {
            onProgress("Rokidに接続しています…")
            return useUSB(usbSerial)
        }

        try checkCancellation(isCancelled)
        if let saved = readSavedAddress(), connect(saved) {
            onProgress("Rokidに接続しています…")
            if isRokidDevice(saved) {
                return use(saved)
            }
            rejectWiFiDevice(saved, removeSavedAddress: true)
        }

        try checkCancellation(isCancelled)
        if let discovered = connectToDiscoveredRokid(
            onProgress: onProgress
        ) {
            return discovered
        }

        logger.log("Wi-Fi接続またはUSB接続を待っています")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try checkCancellation(isCancelled)
            onProgress("Rokidを探しています…")
            if let discovered = connectToDiscoveredRokid(
                onProgress: onProgress
            ) {
                return discovered
            }

            if let usbSerial = findUSBDevice() {
                onProgress("Rokidに接続しています…")
                return try recoverWiFiUsingUSB(
                    usbSerial,
                    isCancelled: isCancelled
                )
            }
            Thread.sleep(forTimeInterval: 1)
        }

        throw RokidConnectionError.noDevice
    }

    func reconnect(
        isCancelled: () -> Bool = { false }
    ) -> String? {
        var oldSerial = currentSerial()
        if !oldSerial.isEmpty && oldSerial.contains(":") {
            _ = adb(["disconnect", oldSerial], timeout: 3)
        }

        for _ in 0..<20 {
            if isCancelled() {
                return nil
            }
            if let usbSerial = findUSBDevice() {
                return useUSB(usbSerial)
            }
            if oldSerial.contains(":") && connect(oldSerial) {
                if isRokidDevice(oldSerial) {
                    return use(oldSerial)
                }
                rejectWiFiDevice(oldSerial, removeSavedAddress: true)
                oldSerial = ""
            }
            if let discovered = connectToDiscoveredRokid() {
                return discovered
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
            logger.log(
                "画面サイズの取得に失敗したため480x640を使用 output=\(result.output)"
            )
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
        timer.schedule(deadline: .now(), repeating: 5)
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
        guard !current.isEmpty else { return }

        let pidResult = adb([
            "-s", current, "shell", "cat", remoteWatchdogPID,
        ], timeout: 2)
        let pid = pidResult.output.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if pidResult.succeeded, Int(pid) != nil {
            _ = adb(["-s", current, "shell", "kill", pid], timeout: 2)
        } else {
            logger.log(
                "監視スクリプトのPIDを取得できませんでした（生存信号の削除で停止させます）"
            )
        }
        _ = adb([
            "-s", current, "shell", "rm", "-f",
            remoteHeartbeat, remoteWatchdogPID,
        ], timeout: 2)
        logger.log("Mac操作モード終了")
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

    private func useUSB(_ usbSerial: String) -> String {
        stateLock.lock()
        serial = usbSerial
        stateLock.unlock()
        logger.log("USB接続成功 serial=\(usbSerial)")
        return usbSerial
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
            if fields[1] == "device",
               !candidate.contains(":"),
               isRokidDevice(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func connectToDiscoveredRokid(
        onProgress: (String) -> Void = { _ in }
    ) -> String? {
        for address in discoverSecureWiFi() {
            onProgress("Rokidに接続しています…")
            guard connect(address) else { continue }
            if isRokidDevice(address) {
                return use(address)
            }
            rejectWiFiDevice(address)
        }
        return nil
    }

    private func discoverSecureWiFi() -> [String] {
        var addresses: [String] = []
        let mdns = adb(["mdns", "services"], timeout: 3).output
        for line in mdns.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if let index = fields.firstIndex(of: "_adb-tls-connect._tcp"),
               fields.indices.contains(index + 1) {
                addresses.append(String(fields[index + 1]))
            }
        }
        if addresses.isEmpty {
            addresses = discoverWithBonjour()
        }
        return addresses.reduce(into: []) { unique, address in
            if !unique.contains(address) {
                unique.append(address)
            }
        }
    }

    private func discoverWithBonjour() -> [String] {
        let dnsSD = URL(fileURLWithPath: "/usr/bin/dns-sd")
        let browse = runner.run(
            dnsSD,
            arguments: ["-B", "_adb-tls-connect._tcp", "local"],
            timeout: 1.2
        ).output

        var serviceNames: [String] = []
        for line in browse.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.contains("Add") else { continue }
            if let typeIndex = fields.firstIndex(where: {
                $0.hasPrefix("_adb-tls-connect._tcp")
            }), fields.indices.contains(typeIndex + 1) {
                let serviceName = fields[(typeIndex + 1)...]
                    .map(String.init)
                    .joined(separator: " ")
                if !serviceNames.contains(serviceName) {
                    serviceNames.append(serviceName)
                }
            }
        }

        var addresses: [String] = []
        for serviceName in serviceNames {
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
                let address = String(fields[at + 1])
                    .replacingOccurrences(of: ".:", with: ":")
                if !addresses.contains(address) {
                    addresses.append(address)
                }
            }
        }
        return addresses
    }

    private func recoverWiFiUsingUSB(
        _ usbSerial: String,
        isCancelled: () -> Bool = { false }
    ) throws -> String {
        try checkCancellation(isCancelled)
        guard isRokidDevice(usbSerial) else {
            throw RokidConnectionError.noDevice
        }
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
            try checkCancellation(isCancelled)
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
            try checkCancellation(isCancelled)
            if connect(address) {
                if isRokidDevice(address) {
                    return use(address)
                }
                rejectWiFiDevice(address)
                throw RokidConnectionError.noDevice
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw RokidConnectionError.noDevice
    }

    private func checkCancellation(
        _ isCancelled: () -> Bool
    ) throws {
        if isCancelled() {
            throw RokidConnectionError.cancelled
        }
    }

    private func isRokidDevice(_ address: String) -> Bool {
        let model = adb([
            "-s", address, "shell", "getprop", "ro.product.model",
        ], timeout: 3).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let manufacturer = adb([
            "-s", address, "shell", "getprop", "ro.product.manufacturer",
        ], timeout: 3).output.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.log(
            "接続先確認 serial=\(address) model=\(model) manufacturer=\(manufacturer)"
        )

        let identifiers = [model, manufacturer].map { $0.lowercased() }
        return identifiers.contains {
            $0.contains("rokid")
                || $0.contains("rv101")
                || $0.contains("rg-glasses")
        }
    }

    private func rejectWiFiDevice(
        _ address: String,
        removeSavedAddress: Bool = false
    ) {
        logger.log("Rokid以外の接続先を拒否 serial=\(address)")
        _ = adb(["disconnect", address], timeout: 3)
        if removeSavedAddress {
            try? FileManager.default.removeItem(at: addressURL)
            logger.log("保存済みWi-Fi接続先を破棄")
        }
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
