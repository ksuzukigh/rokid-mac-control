import Foundation

/// Rokidへの接続が安全かどうかを、端末が申告する待ち受けの状態から判定する。
///
/// 判定は「Macの接続がTLSか」ではなく「**端末に暗号化なしの入口が残っていないか**」
/// で行う。Androidでは従来の暗号化なしADBとTLSサーバーは別々の待ち受けとして
/// 動くため、MacがTLSで繋いでいても、端末側に暗号化なしの入口が開いたままなら
/// 同じWi-Fi内の別の機器からそこへ接続できてしまう。
///
/// **ポート番号では判定できない。** `adb tcpip <ポート>` は5555以外の任意の
/// ポートでも暗号化なしの待ち受けを作れる。
///
/// ADB処理から切り離してあるため、端末なしで自動試験できる。
enum ConnectionEncryption {
    /// 判定結果。拒否する場合は理由を持たせ、ログに残せるようにする。
    enum Verdict: Equatable {
        /// 安全。暗号化された接続で、端末に暗号化なしの入口も残っていない。
        case encrypted
        /// 繋いでいる先そのものが、暗号化なしの待ち受けだった。
        case plaintextConnection(port: String)
        /// 繋いでいる先とは別に、暗号化なしの待ち受けが端末に残っている。
        case plaintextListenerRemains(ports: [String])
        /// ワイヤレスデバッグが有効になっていない。
        case wirelessDebuggingDisabled
        /// `host:port` の形ではない（USB接続など）。
        case notNetworkAddress
    }

    /// `host:port` からポート部分を取り出す。数字以外はポートとみなさない。
    static func port(of address: String) -> String? {
        guard let separator = address.lastIndex(of: ":") else { return nil }
        let port = String(address[address.index(after: separator)...])
        guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
        return port
    }

    /// `getprop` の値が「実際に待ち受けている」ことを表すか。
    ///
    /// 空文字・`null`・`-1`・数字でないもの・範囲外は、待ち受けていないとみなす。
    static func isActiveListenerPort(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.allSatisfy(\.isNumber),
            let number = Int(trimmed),
            number > 0,
            number <= 65535
        else {
            return false
        }
        return true
    }

    /// 端末が申告した待ち受けのうち、実際に開いているものだけを順序を保って返す。
    static func activeListenerPorts(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isActiveListenerPort)
            .reduce(into: [String]()) { unique, port in
                if !unique.contains(port) {
                    unique.append(port)
                }
            }
    }

    /// USB接続中のRokidが申告したWi-FiアドレスとTLSポートから接続先を作る。
    ///
    /// RV101ではTLSサーバーが起動していても、ルーターやmacOS側の状態によって
    /// `_adb-tls-connect._tcp`のmDNS通知が見えないことがある。信頼済みのUSB経由で
    /// 読み取った値だけを予備候補にする。ここでは候補を組み立てるだけで、
    /// 採用前には別途、Rokid確認と平文入口が残っていないことの確認を行う。
    static func usbTLSAddress(
        ipAddressOutput: String,
        tlsPortOutput: String
    ) -> String? {
        let pattern = #"\binet\s+((?:\d{1,3}\.){3}\d{1,3})/"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: ipAddressOutput,
                range: NSRange(ipAddressOutput.startIndex..., in: ipAddressOutput)
            ),
            let addressRange = Range(match.range(at: 1), in: ipAddressOutput)
        else {
            return nil
        }

        let address = String(ipAddressOutput[addressRange])
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard
            octets.count == 4,
            let first = Int(octets[0]),
            first > 0,
            first < 224,
            first != 127,
            octets.allSatisfy({
                guard let value = Int($0) else { return false }
                return value >= 0 && value <= 255
            })
        else {
            return nil
        }

        let ports = activeListenerPorts(
            tlsPortOutput
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        )
        guard ports.count == 1, let port = ports.first else {
            return nil
        }
        return "\(address):\(port)"
    }

    /// 端末が申告した状態から、この接続先を採用してよいかを判定する。
    ///
    /// - Parameters:
    ///   - address: adbの接続先（`host:port`）。USBのシリアルは対象外。
    ///   - plaintextPorts: 端末の `service.adb.tcp.port` と `persist.adb.tcp.port`。
    ///     ひとつでも有効な値が入っていれば、暗号化なしの入口が開いている。
    ///   - wirelessDebuggingEnabled: `settings get global adb_wifi_enabled` が `1` か。
    static func verdict(
        address: String,
        plaintextPorts: [String],
        wirelessDebuggingEnabled: Bool
    ) -> Verdict {
        guard let port = port(of: address) else {
            return .notNetworkAddress
        }

        let listening = activeListenerPorts(plaintextPorts)
        // 繋いでいる先そのものが暗号化なしの場合。
        if listening.contains(port) {
            return .plaintextConnection(port: port)
        }
        // 繋いでいる先はTLSでも、端末に別の入口が残っている場合。
        // MacがTLSで繋いでいても、その入口は誰にでも開いている。
        if !listening.isEmpty {
            return .plaintextListenerRemains(ports: listening)
        }

        guard wirelessDebuggingEnabled else {
            return .wirelessDebuggingDisabled
        }
        return .encrypted
    }

    static func isEncrypted(
        address: String,
        plaintextPorts: [String],
        wirelessDebuggingEnabled: Bool
    ) -> Bool {
        verdict(
            address: address,
            plaintextPorts: plaintextPorts,
            wirelessDebuggingEnabled: wirelessDebuggingEnabled
        ) == .encrypted
    }

    /// 拒否した理由をログへ残すための説明。
    static func rejectionReason(for verdict: Verdict) -> String? {
        switch verdict {
        case .encrypted:
            return nil
        case .plaintextConnection(let port):
            return "繋いだ先がポート\(port)の暗号化されていない入口です"
        case .plaintextListenerRemains(let ports):
            return "端末にポート\(ports.joined(separator: "・"))の"
                + "暗号化されていない入口が残っています"
        case .wirelessDebuggingDisabled:
            return "ワイヤレスデバッグ（暗号化）が有効になっていません"
        case .notNetworkAddress:
            return "ネットワーク接続先の形ではありません"
        }
    }

    /// 暗号化なしの入口が残っていることが理由の拒否か。
    ///
    /// この理由で全ての候補が拒否された場合は、USBケーブルでつないで
    /// 入口を閉じてもらう必要があるため、利用者への案内を変える。
    static func isPlaintextListenerProblem(_ verdict: Verdict) -> Bool {
        switch verdict {
        case .plaintextConnection, .plaintextListenerRemains:
            return true
        case .encrypted, .wirelessDebuggingDisabled, .notNetworkAddress:
            return false
        }
    }
}
