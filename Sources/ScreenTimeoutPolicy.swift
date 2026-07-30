import Foundation

/// Mac操作中だけ使う、Rokidの画面消灯までの時間。
enum ScreenTimeoutPolicy {
    /// 24時間。アプリ終了時には必ず元の値へ戻す。
    static let macModeValue = "86400000"

    /// `settings get system screen_off_timeout`の出力から元の値を読む。
    ///
    /// ADBの警告行が混ざる場合は許容するが、数値が複数ある曖昧な出力は拒否する。
    static func originalValue(from output: String) -> String? {
        let values = output
            .split(whereSeparator: \.isNewline)
            .map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { value in
                !value.isEmpty && value.allSatisfy(\.isNumber)
            }
        guard values.count == 1,
              let milliseconds = Int64(values[0]),
              milliseconds > 0
        else {
            return nil
        }
        return String(milliseconds)
    }
}
