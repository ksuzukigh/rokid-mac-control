import Foundation

@main
enum ConnectionEncryptionSelfTest {
    static func main() {
        testPortExtraction()
        testDefaultPlaintextPortRejected()
        testNonDefaultPlaintextPortRejected()
        testPersistentPlaintextPortRejected()
        testEncryptedConnectionAccepted()
        testAbsentPlaintextPortValues()
        testWirelessDebuggingRequired()
        testUSBSerialIsNotNetworkAddress()
        print("Connection encryption self-test passed")
    }

    // MARK: - ポートの取り出し

    private static func testPortExtraction() {
        precondition(
            ConnectionEncryption.port(of: "192.168.11.46:42031") == "42031"
        )
        precondition(
            ConnectionEncryption.port(of: "Android.local:5555") == "5555"
        )
        // IPv6は最後のコロンより後ろがポート。
        precondition(
            ConnectionEncryption.port(of: "[fe80::1]:37000") == "37000"
        )
        // USBのシリアルにはポートがない。
        precondition(ConnectionEncryption.port(of: "1904092623382143") == nil)
        // 数字でないものはポートとみなさない。
        precondition(ConnectionEncryption.port(of: "host:abc") == nil)
        precondition(ConnectionEncryption.port(of: "host:") == nil)
    }

    // MARK: - 暗号化なしの拒否

    /// `adb tcpip 5555`が作る既定の暗号化なし接続を拒否する。
    private static func testDefaultPlaintextPortRejected() {
        let verdict = ConnectionEncryption.verdict(
            address: "192.168.11.46:5555",
            plaintextPorts: ["5555", ""],
            wirelessDebuggingEnabled: true
        )
        precondition(verdict == .plaintextListener(port: "5555"))
        precondition(ConnectionEncryption.rejectionReason(for: verdict) != nil)
    }

    /// **5555以外の暗号化なし接続も拒否する。**
    ///
    /// `adb tcpip <ポート>` は任意のポートを使えるため、ポート番号が5555で
    /// ないことをもって暗号化されているとはみなせない。端末が申告する
    /// 待ち受けポートと一致したら、番号が何であっても拒否する。
    private static func testNonDefaultPlaintextPortRejected() {
        for port in ["7000", "37000", "5556", "12345"] {
            let address = "192.168.11.46:\(port)"
            let verdict = ConnectionEncryption.verdict(
                address: address,
                plaintextPorts: [port, ""],
                // ワイヤレスデバッグが有効でも、繋いでいる先が
                // 暗号化なしの待ち受けなら拒否する。
                wirelessDebuggingEnabled: true
            )
            precondition(
                verdict == .plaintextListener(port: port),
                "ポート\(port)の暗号化なし接続を拒否できていない"
            )
            precondition(
                !ConnectionEncryption.isEncrypted(
                    address: address,
                    plaintextPorts: [port, ""],
                    wirelessDebuggingEnabled: true
                ),
                "ポート\(port)を暗号化済みと誤判定している"
            )
        }
    }

    /// 再起動後も残る`persist.adb.tcp.port`側の待ち受けも拒否する。
    private static func testPersistentPlaintextPortRejected() {
        let verdict = ConnectionEncryption.verdict(
            address: "192.168.11.46:37000",
            plaintextPorts: ["", "37000"],
            wirelessDebuggingEnabled: true
        )
        precondition(verdict == .plaintextListener(port: "37000"))
    }

    // MARK: - 暗号化ありの採用

    private static func testEncryptedConnectionAccepted() {
        precondition(
            ConnectionEncryption.verdict(
                address: "192.168.11.46:42031",
                plaintextPorts: ["", ""],
                wirelessDebuggingEnabled: true
            ) == .encrypted
        )
        // 暗号化なしの待ち受けが別ポートで動いていても、
        // 繋いでいる先がそれと違うなら暗号化された接続である。
        precondition(
            ConnectionEncryption.verdict(
                address: "192.168.11.46:42031",
                plaintextPorts: ["5555", ""],
                wirelessDebuggingEnabled: true
            ) == .encrypted
        )
        precondition(
            ConnectionEncryption.rejectionReason(for: .encrypted) == nil
        )
    }

    /// 待ち受けなしを表す値は、待ち受けとして扱わない。
    private static func testAbsentPlaintextPortValues() {
        for absent in ["", "null", "-1", "  "] {
            precondition(
                ConnectionEncryption.verdict(
                    address: "192.168.11.46:42031",
                    plaintextPorts: [absent, absent],
                    wirelessDebuggingEnabled: true
                ) == .encrypted,
                "\(absent) を待ち受けとして誤解釈している"
            )
        }
    }

    // MARK: - ワイヤレスデバッグ

    private static func testWirelessDebuggingRequired() {
        let verdict = ConnectionEncryption.verdict(
            address: "192.168.11.46:42031",
            plaintextPorts: ["", ""],
            wirelessDebuggingEnabled: false
        )
        precondition(verdict == .wirelessDebuggingDisabled)
        precondition(ConnectionEncryption.rejectionReason(for: verdict) != nil)
    }

    // MARK: - USB

    private static func testUSBSerialIsNotNetworkAddress() {
        precondition(
            ConnectionEncryption.verdict(
                address: "1904092623382143",
                plaintextPorts: ["", ""],
                wirelessDebuggingEnabled: true
            ) == .notNetworkAddress
        )
    }
}
