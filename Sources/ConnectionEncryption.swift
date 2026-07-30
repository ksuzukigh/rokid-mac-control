import Foundation

/// 接続先が暗号化された接続（Android標準のワイヤレスデバッグ＝TLS）かどうかを判定する。
///
/// **ポート番号では判定できない。** `adb tcpip <ポート>` は5555以外の任意のポートでも
/// 暗号化なしの待ち受けを作れるため、「5555でなければ暗号化されている」とは言えない。
/// 端末が申告する待ち受けポートと突き合わせて判定する。
///
/// ADB処理から切り離してあるため、端末なしで自動試験できる。
enum ConnectionEncryption {
    /// 判定結果。拒否する場合は理由を持たせ、ログに残せるようにする。
    enum Verdict: Equatable {
        /// 暗号化された接続として採用してよい。
        case encrypted
        /// 端末が暗号化なしで待ち受けているポートへ繋いでいる。
        case plaintextListener(port: String)
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

    /// 端末が申告した状態から、接続が暗号化されているかを判定する。
    ///
    /// - Parameters:
    ///   - address: adbの接続先（`host:port`）。USBのシリアルは対象外。
    ///   - plaintextPorts: 端末の `service.adb.tcp.port` と `persist.adb.tcp.port`。
    ///     これらに値が入っていると、そのポートで暗号化なしの待ち受けが動いている。
    ///     空文字・`null`・`-1` は「待ち受けていない」として扱う。
    ///   - wirelessDebuggingEnabled: `settings get global adb_wifi_enabled` が `1` か。
    static func verdict(
        address: String,
        plaintextPorts: [String],
        wirelessDebuggingEnabled: Bool
    ) -> Verdict {
        guard let port = port(of: address) else {
            return .notNetworkAddress
        }

        let listening = plaintextPorts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "null" && $0 != "-1" }
        if listening.contains(port) {
            return .plaintextListener(port: port)
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
        case .plaintextListener(let port):
            return "端末がポート\(port)で暗号化なしの待ち受けをしています"
        case .wirelessDebuggingDisabled:
            return "ワイヤレスデバッグ（暗号化）が有効になっていません"
        case .notNetworkAddress:
            return "ネットワーク接続先の形ではありません"
        }
    }
}
