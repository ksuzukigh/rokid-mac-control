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

    /// 画面消灯までの時間を変更していた版が残した控え。見つけたら元へ戻す。
    private let screenTimeoutBackupURL: URL

    // 暗号化の判定結果を、ひとつの接続試行のあいだだけ覚えておく。
    // 判定には端末への問い合わせが3回かかるため、繰り返しのたびに
    // 同じ接続先を調べ直すと待ち時間が積み上がる。
    private let encryptionCacheLock = NSLock()
    private var encryptionVerdictCache:
        [String: ConnectionEncryption.Verdict] = [:]

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
        screenTimeoutBackupURL = appSupport.appendingPathComponent(
            "screen-off-timeout.txt"
        )
    }

    func prepareADBServer() {
        _ = adb(["start-server"], timeout: 8)
    }

    func connectForStartup(
        onProgress: (String) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> String {
        try checkCancellation(isCancelled)
        forgetEncryptionVerdicts()
        onProgress("Rokidを探しています…")
        // A connected development cable is the most stable path and does not
        // require changing the glasses' Wi-Fi state.
        if let usbSerial = findUSBDevice() {
            onProgress("Rokidに接続しています…")
            return try migrateToSecureWiFi(
                usbSerial: usbSerial,
                onProgress: onProgress,
                isCancelled: isCancelled
            )
        }

        try checkCancellation(isCancelled)
        if let connected = connectToSecureWiFi(onProgress: onProgress) {
            return connected
        }

        logger.log("Wi-Fi接続またはUSB接続を待っています")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try checkCancellation(isCancelled)
            onProgress("Rokidを探しています…")
            if let connected = connectToSecureWiFi(onProgress: onProgress) {
                return connected
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

    /// USBがつながっているときに、暗号化された無線接続を用意して移行する。
    ///
    /// 移行できないときは暗号化なしへ落とさず、USB接続のまま続ける。
    /// 起動時と再接続時の両方から呼ぶ。片方だけ直すとUSBに固定される。
    /// `attempts`は探索の繰り返し回数。Wi-Fiを復旧させたあとの経路
    /// （`recoverWiFiUsingUSB`）は告知が遅れやすいため多めに待つ。
    private func migrateToSecureWiFi(
        usbSerial: String,
        recent: String? = nil,
        attempts: Int = 8,
        onProgress: (String) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> String {
        prepareSecureWirelessDebugging(usbSerial)
        for _ in 0..<attempts {
            try checkCancellation(isCancelled)
            Thread.sleep(forTimeInterval: 1)
            if let connected = connectToSecureWiFi(
                recent: recent,
                onProgress: onProgress
            ) {
                return connected
            }
        }
        logger.log("暗号化接続を用意できないためUSB接続を継続します")
        return useUSB(usbSerial)
    }

    func reconnect(
        isCancelled: () -> Bool = { false }
    ) -> String? {
        forgetEncryptionVerdicts()
        var oldSerial = currentSerial()
        if !oldSerial.isEmpty && oldSerial.contains(":") {
            _ = adb(["disconnect", oldSerial], timeout: 3)
        }
        // 念のための備え。現在の経路では、暗号化されない接続先が`serial`へ
        // 入ることはない（採用前に必ず暗号化を確かめるため）。それでも、
        // 古い版が残した記録などで紛れ込んだ場合に再利用しないようにする。
        if isDefaultPlaintextAddress(oldSerial) {
            logger.log("暗号化されない直前の接続先を破棄 \(oldSerial)")
            stateLock.lock()
            serial = ""
            stateLock.unlock()
            try? FileManager.default.removeItem(at: addressURL)
            oldSerial = ""
        }

        // 直前がUSB接続だった場合、そのシリアルは接続先候補にならない。
        let recentWiFi = oldSerial.contains(":") ? oldSerial : nil

        for _ in 0..<20 {
            if isCancelled() {
                return nil
            }
            if let usbSerial = findUSBDevice() {
                // USBへ退避した場合も、暗号化された無線接続を用意し直して戻る。
                // ここでUSBを返して終えると、以後ずっとUSBのままになる。
                return try? migrateToSecureWiFi(
                    usbSerial: usbSerial,
                    recent: recentWiFi,
                    isCancelled: isCancelled
                )
            }
            if let connected = connectToSecureWiFi(recent: recentWiFi) {
                return connected
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
            // 前の監視スクリプトは終了時に画面消灯の設定を元へ戻す。
            // 完全に終わるのを待たずに次の準備を始めると、これから設定する値を
            // 後から戻されてしまうため、終了を見届けてから先へ進む。
            _ = adb([
                "-s", current, "shell",
                "kill \(oldPID); n=0;"
                    + " while kill -0 \(oldPID) 2>/dev/null && [ $n -lt 5 ];"
                    + " do sleep 1; n=$((n+1)); done",
            ], timeout: 10)
        }

        _ = adb([
            "-s", current, "shell", "rm", "-f", remoteWatchdogPID,
        ], timeout: 3)
        guard adb([
            "-s", current, "shell", "touch", remoteHeartbeat,
        ], timeout: 3).succeeded else {
            throw RokidConnectionError.watchdogFailed
        }

        // 前回が異常終了だった場合に備え、控えが残っていれば元へ戻す。
        restoreScreenTimeoutFromBackup(current)

        // 画面消灯までの時間は、現在は変更していない。
        // RV101ではこの設定がHUDの表示を左右せず、変更しなくても
        // Mac操作が続けられることを実機で確認したため。
        // 第2引数は「監視スクリプトが終了時に戻すべき値」で、空なら何もしない。
        let launch = "setsid sh '\(remoteWatchdog)' 20 '' </dev/null >/dev/null 2>&1 &"
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
        restoreScreenTimeoutFromBackup(current)
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

    /// USBがつながっている間に、暗号化された無線接続の下準備をする。
    ///
    /// 旧版は`adb tcpip 5555`で暗号化なしのTCP待ち受けを作っていた。これは
    /// `service.adb.tcp.port`として端末に残り、再起動しても待ち受けが続くため、
    /// 同じWi-Fi内の別の機器から接続できる状態になる。見つけたら閉じる。
    private func prepareSecureWirelessDebugging(_ usbSerial: String) {
        let tcpPort = adb([
            "-s", usbSerial, "shell", "getprop", "service.adb.tcp.port",
        ], timeout: 3).output.trimmingCharacters(in: .whitespacesAndNewlines)

        if tcpPort == "5555" {
            // 旧版が残した暗号化なしの待ち受けを閉じる。
            // adbdを再起動するので、必要なときだけ実行する。
            logger.log("暗号化されない待ち受け（5555番）を閉じます")
            _ = adb(["-s", usbSerial, "usb"], timeout: 8)
            // adbdの再起動でUSB接続が一度切れる。先に眠ってから待たないと、
            // 切れる前の接続を見て「もう繋がっている」と誤判定してしまう。
            Thread.sleep(forTimeInterval: 2)
            _ = adb(["-s", usbSerial, "wait-for-device"], timeout: 20)
        }

        let enabled = adb([
            "-s", usbSerial, "shell", "settings", "put", "global",
            "adb_wifi_enabled", "1",
        ], timeout: 5)
        logger.log(
            enabled.succeeded
                ? "ワイヤレスデバッグ（暗号化）を有効化"
                : "ワイヤレスデバッグの有効化に失敗 output=\(enabled.output)"
        )
    }

    /// `adb tcpip 5555`が作る既定の暗号化なし接続先かどうか。
    ///
    /// これは繋ぐ前に使える簡易のふるい分けにすぎない。`adb tcpip`は5555以外の
    /// ポートも使えるため、これだけでは暗号化を保証できない。実際の判定は
    /// 接続後に`encryptionRejectionReason(_:)`が端末の状態を読んで行う。
    private func isDefaultPlaintextAddress(_ address: String) -> Bool {
        address.hasSuffix(":5555")
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
        guard !isDefaultPlaintextAddress(value) else {
            logger.log("暗号化されない保存済み接続先を破棄 \(value)")
            _ = adb(["disconnect", value], timeout: 3)
            try? FileManager.default.removeItem(at: addressURL)
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

    /// 接続先の候補と、その出どころ。
    private struct WiFiCandidate {
        let address: String
        /// 保存済みの接続先。Rokidでなければ記録を消す。
        let isSaved: Bool
        /// このアプリが繋いだのではなく、もともと`adb devices`にあったもの。
        /// Rokidでなくても切断しない（利用者が別の用途で使っている可能性がある）。
        let wasAlreadyConnected: Bool
    }

    /// 暗号化された無線接続の候補を、優先順に並べて返す。
    ///
    /// 起動時と再接続時で共通の並びにする。重複は除き、`adb tcpip 5555`が作る
    /// 暗号化なしの固定5555番はどの経路から来ても含めない。
    ///
    /// 1. 直前の接続先（再接続時のみ。起動時は`recent`にnilを渡す）
    /// 2. 保存済みの接続先
    /// 3. `adb devices`にすでに繋がっているネットワーク接続先
    /// 4. `_adb-tls-connect._tcp`のmDNS探索結果
    private func secureWiFiCandidates(recent: String? = nil) -> [WiFiCandidate] {
        let saved = readSavedAddress()
        let alreadyConnected = connectedNetworkDevices()
        let alreadyConnectedSet = Set(alreadyConnected)

        var ordered: [String] = []
        func add(_ address: String?) {
            guard
                let address,
                address.contains(":"),
                !isDefaultPlaintextAddress(address),
                !ordered.contains(address)
            else {
                return
            }
            ordered.append(address)
        }

        add(recent)
        add(saved)
        alreadyConnected.forEach(add)
        discoverSecureWiFi().forEach(add)

        return ordered.map { address in
            WiFiCandidate(
                address: address,
                isSaved: address == saved,
                wasAlreadyConnected: alreadyConnectedSet.contains(address)
            )
        }
    }

    /// `adb devices`にすでに繋がっているネットワーク接続先。
    ///
    /// mDNSが一時的に見えないときでも、既存の暗号化接続を拾い直せるようにする。
    private func connectedNetworkDevices() -> [String] {
        let output = adb(["devices"], timeout: 3).output
        var addresses: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1] == "device" else { continue }
            let candidate = String(fields[0])
            guard candidate.contains(":") else { continue }
            addresses.append(candidate)
        }
        return addresses
    }

    /// 候補を順に試し、Rokidだと確認できた最初の接続先を採用する。
    private func connectToSecureWiFi(
        recent: String? = nil,
        onProgress: (String) -> Void = { _ in }
    ) -> String? {
        for candidate in secureWiFiCandidates(recent: recent) {
            onProgress("Rokidに接続しています…")
            guard connect(candidate.address) else { continue }

            guard isRokidDevice(candidate.address) else {
                reject(candidate, reason: "Rokid以外の接続先です")
                continue
            }
            // 採用して保存する前に、暗号化されていることを端末の状態から確かめる。
            // ポート番号だけでは判定できないため、ここまで繋いでから確認する。
            guard let reason = encryptionRejectionReason(candidate.address)
            else {
                return use(candidate.address)
            }
            reject(candidate, reason: reason)
        }
        return nil
    }

    /// 採用しない候補の後始末。
    private func reject(_ candidate: WiFiCandidate, reason: String) {
        logger.log("接続先を拒否 serial=\(candidate.address) 理由=\(reason)")
        if candidate.isSaved {
            try? FileManager.default.removeItem(at: addressURL)
            logger.log("保存済みWi-Fi接続先を破棄")
        }
        // もともと繋がっていた接続は切らない。
        // 利用者が別の端末を自分で繋いでいることがあるため。
        guard !candidate.wasAlreadyConnected else {
            logger.log(
                "もともと繋がっていた接続なので切断はしません serial=\(candidate.address)"
            )
            return
        }
        _ = adb(["disconnect", candidate.address], timeout: 3)
    }

    /// 接続先が暗号化されていない場合に、その理由を返す。暗号化されていればnil。
    ///
    /// 端末の状態を読むにはいったん接続する必要があるが、ここで実行するのは
    /// `getprop` と `settings get` の読み取りだけで、端末には何も書き込まない。
    /// 暗号化されていないと分かった接続はこの直後に切断する。ただし利用者が
    /// もともと繋いでいた接続は切らない。
    ///
    /// 判定結果を覚えておく。ひとつの接続試行のあいだに同じ接続先を
    /// 何度も問い合わせると、待ち時間が積み上がるため。
    private func encryptionRejectionReason(_ address: String) -> String? {
        encryptionCacheLock.lock()
        let cached = encryptionVerdictCache[address]
        encryptionCacheLock.unlock()
        if let cached {
            return ConnectionEncryption.rejectionReason(for: cached)
        }

        // 標準出力と標準エラーは同じ経路で受け取るため、警告が混ざりうる。
        // 行に分けてから比べ、待ち受けポートを取りこぼさないようにする。
        let plaintextPorts = [
            "service.adb.tcp.port",
            "persist.adb.tcp.port",
        ].flatMap { property in
            adb([
                "-s", address, "shell", "getprop", property,
            ], timeout: 3)
                .output
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let wifiDebugging = adb([
            "-s", address, "shell", "settings", "get", "global",
            "adb_wifi_enabled",
        ], timeout: 3)
            .output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let verdict = ConnectionEncryption.verdict(
            address: address,
            plaintextPorts: plaintextPorts,
            wirelessDebuggingEnabled: wifiDebugging.contains("1")
        )
        // 覚えておくのは、ひとつの接続試行のあいだに変わらない判定だけにする。
        // ワイヤレスデバッグの有効・無効は端末の準備しだいで後から変わる。
        // これを覚えてしまうと、繰り返し待ち直す仕組みが効かなくなる。
        switch verdict {
        case .plaintextListener, .notNetworkAddress:
            encryptionCacheLock.lock()
            encryptionVerdictCache[address] = verdict
            encryptionCacheLock.unlock()
        case .encrypted, .wirelessDebuggingDisabled:
            break
        }
        return ConnectionEncryption.rejectionReason(for: verdict)
    }

    /// 接続試行を始めるときに、覚えていた判定結果を捨てる。
    /// 端末の状態は起動のたびに変わりうるため、持ち越さない。
    private func forgetEncryptionVerdicts() {
        encryptionCacheLock.lock()
        encryptionVerdictCache.removeAll()
        encryptionCacheLock.unlock()
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
            if !unique.contains(address), !isDefaultPlaintextAddress(address) {
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
                // この繰り返しは待ち時間が長い。ここで確認しないと、
                // キャンセルしてから最大10秒ほど反応しなくなる。
                try checkCancellation(isCancelled)
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

        // `adb tcpip 5555`は使わない。
        //
        // あれはadbdを暗号化なしのTCP待ち受けへ切り替えるもので、一度実行すると
        // Rokidが同じWi-Fi内の誰からでも接続できる状態になり、`service.adb.tcp.port`
        // が残るため再起動後も続く。さらに保存した`:5555`が次回以降の起動で
        // 最優先に使われ、暗号化なしの接続に固定されてしまう。
        //
        // 代わりにAndroid標準のワイヤレスデバッグ（TLS）を有効にし、
        // 初回USB認証で登録済みのMacの鍵で繋ぐ。
        logger.log("暗号化された無線接続を用意します ip=\(ipAddress)")
        return try migrateToSecureWiFi(
            usbSerial: usbSerial,
            attempts: 15,
            isCancelled: isCancelled
        )
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

    // MARK: - 画面消灯の設定

    // このアプリはRokidの`screen_off_timeout`を変更しない。
    //
    // 当初は、Mac操作中にRokidの画面が消えないよう24時間へ伸ばしていた。
    // しかしRV101で実測したところ、Androidとしてはスリープ状態になっても
    // HUDの表示は続いており、この設定はHUDの点灯・消灯を決めていなかった。
    // 利用者もMac操作中に画面が落ちて困った経験がないため、端末の設定を
    // 書き換えない方針に戻した。長時間の放置で接続が切れる事例が出た場合は、
    // 控えと復元のうえで再導入する（履歴に実装が残っている）。

    /// 設定を変更していた版が残した控えがあれば、元の値へ戻す。
    ///
    /// 引数名を`serial`にすると同名のプロパティを覆い隠すため、別の名前にする。
    private func restoreScreenTimeoutFromBackup(_ deviceSerial: String) {
        guard
            let original = try? String(
                contentsOf: screenTimeoutBackupURL,
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            Int(original) != nil
        else {
            return
        }
        let result = adb([
            "-s", deviceSerial, "shell", "settings", "put", "system",
            "screen_off_timeout", original,
        ], timeout: 5)
        // 書き戻せなかったときは控えを残す。次回起動でもう一度やり直せる。
        guard result.succeeded else {
            logger.log("画面消灯までの時間を復元できませんでした（控えは残します）")
            return
        }
        try? FileManager.default.removeItem(at: screenTimeoutBackupURL)
        logger.log("画面消灯までの時間を復元 \(original)")
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
