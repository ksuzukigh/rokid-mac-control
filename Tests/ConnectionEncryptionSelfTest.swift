import Foundation

@main
enum ConnectionEncryptionSelfTest {
    static func main() {
        testPortExtraction()
        testActiveListenerPortValues()
        testUSBTLSAddress()
        testDefaultPlaintextPortRejected()
        testNonDefaultPlaintextPortRejected()
        testPersistentPlaintextPortRejected()
        testRemainingPlaintextListenerRejected()
        testEncryptedConnectionAccepted()
        testWirelessDebuggingRequired()
        testUSBSerialIsNotNetworkAddress()
        testPlaintextListenerProblemClassification()
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

    // MARK: - 待ち受けの有無

    /// 待ち受けなしを表す値を、待ち受けと誤解釈しない。
    private static func testActiveListenerPortValues() {
        for absent in ["", "  ", "null", "-1", "abc", "0", "70000"] {
            precondition(
                !ConnectionEncryption.isActiveListenerPort(absent),
                "\(absent) を待ち受けとして誤解釈している"
            )
        }
        for present in ["5555", "7000", "37000", "1", "65535"] {
            precondition(
                ConnectionEncryption.isActiveListenerPort(present),
                "\(present) を待ち受けとして数えられていない"
            )
        }
        // 順序を保ったまま重複を除く。
        precondition(
            ConnectionEncryption.activeListenerPorts(
                ["5555", "null", "7000", "5555", ""]
            ) == ["5555", "7000"]
        )
    }

    // MARK: - USBから取得するTLS接続先

    private static func testUSBTLSAddress() {
        let actualRV101Output =
            "15: wlan0    inet 192.168.11.46/24 brd 192.168.11.255 "
            + "scope global wlan0\\       valid_lft forever preferred_lft forever"
        let address = ConnectionEncryption.usbTLSAddress(
            ipAddressOutput: actualRV101Output,
            tlsPortOutput: "37535\n"
        )
        precondition(address == "192.168.11.46:37535")

        // ADBの警告が別行に混ざっても、端末が返した値を取得できる。
        precondition(
            ConnectionEncryption.usbTLSAddress(
                ipAddressOutput:
                    "adb: warning: temporary message\n"
                    + "15: wlan0    inet 10.0.0.8/24 scope global wlan0\n",
                tlsPortOutput: "adb: warning: temporary message\n42031\n"
            ) == "10.0.0.8:42031"
        )

        // IP、ポート、読み取り結果のいずれかが不正なら候補を作らない。
        for invalidIP in [
            "",
            "15: wlan0    inet 999.168.11.46/24 scope global wlan0",
            "15: wlan0    inet 127.0.0.1/8 scope host wlan0",
            "15: wlan0    inet 224.0.0.1/24 scope global wlan0",
        ] {
            precondition(
                ConnectionEncryption.usbTLSAddress(
                    ipAddressOutput: invalidIP,
                    tlsPortOutput: "37535"
                ) == nil
            )
        }
        for invalidPort in ["", "-1", "0", "abc", "70000", "37535\n42031"] {
            precondition(
                ConnectionEncryption.usbTLSAddress(
                    ipAddressOutput: actualRV101Output,
                    tlsPortOutput: invalidPort
                ) == nil
            )
        }

        // USBから作った候補でも、平文入口が残っていれば採用しない。
        guard let address else {
            preconditionFailure("実機形式のUSB情報からTLS候補を作れない")
        }
        precondition(
            ConnectionEncryption.verdict(
                address: address,
                plaintextPorts: ["5555", ""],
                wirelessDebuggingEnabled: true
            ) == .plaintextListenerRemains(ports: ["5555"])
        )
    }

    // MARK: - 暗号化なしの接続先そのもの

    /// `adb tcpip 5555`が作る既定の暗号化なし接続を拒否する。
    private static func testDefaultPlaintextPortRejected() {
        let verdict = ConnectionEncryption.verdict(
            address: "192.168.11.46:5555",
            plaintextPorts: ["5555", ""],
            wirelessDebuggingEnabled: true
        )
        precondition(verdict == .plaintextConnection(port: "5555"))
        precondition(ConnectionEncryption.rejectionReason(for: verdict) != nil)
    }

    /// **5555以外の暗号化なし接続も拒否する。**
    ///
    /// `adb tcpip <ポート>` は任意のポートを使えるため、ポート番号が5555で
    /// ないことをもって暗号化されているとはみなせない。
    private static func testNonDefaultPlaintextPortRejected() {
        for port in ["7000", "37000", "5556", "12345"] {
            let address = "192.168.11.46:\(port)"
            precondition(
                ConnectionEncryption.verdict(
                    address: address,
                    plaintextPorts: [port, ""],
                    wirelessDebuggingEnabled: true
                ) == .plaintextConnection(port: port),
                "ポート\(port)の暗号化なし接続を拒否できていない"
            )
        }
    }

    /// 再起動後も残る`persist.adb.tcp.port`側の待ち受けも拒否する。
    private static func testPersistentPlaintextPortRejected() {
        precondition(
            ConnectionEncryption.verdict(
                address: "192.168.11.46:37000",
                plaintextPorts: ["", "37000"],
                wirelessDebuggingEnabled: true
            ) == .plaintextConnection(port: "37000")
        )
    }

    // MARK: - 別ポートに残る暗号化なしの入口

    /// **TLS接続中でも、別ポートに暗号化なしの入口が残っていれば拒否する。**
    ///
    /// Androidでは従来の暗号化なしADBとTLSサーバーは別々の待ち受けとして動く。
    /// MacがTLSで繋いでいても、その入口は同じWi-Fi内の誰にでも開いている。
    /// 「自分の接続が暗号化されているか」ではなく「端末に暗号化なしの入口が
    /// 残っていないか」で判定する。
    private static func testRemainingPlaintextListenerRejected() {
        // TLS接続（42031番）中に、5555番の暗号化なし待ち受けが残っている。
        let verdict = ConnectionEncryption.verdict(
            address: "192.168.11.46:42031",
            plaintextPorts: ["5555", ""],
            wirelessDebuggingEnabled: true
        )
        precondition(
            verdict == .plaintextListenerRemains(ports: ["5555"]),
            "別ポートに残る暗号化なしの入口を見逃している"
        )
        precondition(ConnectionEncryption.rejectionReason(for: verdict) != nil)
        precondition(
            !ConnectionEncryption.isEncrypted(
                address: "192.168.11.46:42031",
                plaintextPorts: ["5555", ""],
                wirelessDebuggingEnabled: true
            )
        )

        // 5555以外でも同じ。ポート番号は関係ない。
        for port in ["7000", "37000", "5556", "12345"] {
            precondition(
                ConnectionEncryption.verdict(
                    address: "192.168.11.46:42031",
                    plaintextPorts: [port, ""],
                    wirelessDebuggingEnabled: true
                ) == .plaintextListenerRemains(ports: [port]),
                "ポート\(port)に残る暗号化なしの入口を見逃している"
            )
        }

        // 2か所に残っている場合は両方を報告する。
        precondition(
            ConnectionEncryption.verdict(
                address: "192.168.11.46:42031",
                plaintextPorts: ["5555", "7000"],
                wirelessDebuggingEnabled: true
            ) == .plaintextListenerRemains(ports: ["5555", "7000"])
        )
    }

    // MARK: - 採用してよい場合

    /// 暗号化なしの入口がひとつも残っていないときだけ採用する。
    private static func testEncryptedConnectionAccepted() {
        precondition(
            ConnectionEncryption.verdict(
                address: "192.168.11.46:42031",
                plaintextPorts: ["", ""],
                wirelessDebuggingEnabled: true
            ) == .encrypted
        )
        // 待ち受けなしを表す値が入っていても採用してよい。
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
        precondition(
            ConnectionEncryption.rejectionReason(for: .encrypted) == nil
        )
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

    // MARK: - 案内の切り替え

    /// 暗号化なしの入口が理由の拒否だけを、USB接続での対処が要る問題として扱う。
    private static func testPlaintextListenerProblemClassification() {
        precondition(
            ConnectionEncryption.isPlaintextListenerProblem(
                .plaintextConnection(port: "5555")
            )
        )
        precondition(
            ConnectionEncryption.isPlaintextListenerProblem(
                .plaintextListenerRemains(ports: ["5555"])
            )
        )
        precondition(
            !ConnectionEncryption.isPlaintextListenerProblem(.encrypted)
        )
        precondition(
            !ConnectionEncryption.isPlaintextListenerProblem(
                .wirelessDebuggingDisabled
            )
        )
        precondition(
            !ConnectionEncryption.isPlaintextListenerProblem(.notNetworkAddress)
        )
    }
}
