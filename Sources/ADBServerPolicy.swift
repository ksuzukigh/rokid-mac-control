import Foundation

enum ADBServerPolicy {
    /// Rokid Control専用のADBサーバー。Homebrew版やほかのAndroid作業が使う
    /// 標準5037番と分離し、古い別アプリの許可状態を再利用しない。
    static let dedicatedPort = "5038"

    /// macOSのローカルネットワーク許可がADB常駐処理へ反映されていない場合、
    /// ADBは接続先が同じLAN上に存在していてもこのエラーを返す。
    static func indicatesLocalNetworkBlock(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("no route to host")
            || normalized.contains("network is unreachable")
    }
}
