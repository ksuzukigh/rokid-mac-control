import Foundation

/// R08の準備済み操作補助だけを、MacのTLS接続から復旧する。
/// 5555番を許可する例外は設けず、R08のAPKや個人設定も書き換えない。
enum R08RecoveryPolicy {
    static let package = "com.anezium.r08accessbridge"
    static let accessibilityService =
        "\(package)/\(package).RingControlAccessibilityService"

    struct Helper {
        let path: String
        let pidFile: String
        let sha256: String
        let pendingRequest: String?
        let restoreAtStartup: Bool
    }

    // R08 Access Bridge 2.0.1の正式APK内res/rawと実機ファイルで照合済み。
    static let helpers = [
        Helper(
            path: "/data/local/tmp/r08-shortcut-bridge.sh",
            pidFile: "/data/local/tmp/r08-shortcut-bridge.pid",
            sha256: "50e9e08693a1ad0208e7a231fc8cc7d0a410f7ea36c9b82711d87a3667b9f3f8",
            pendingRequest: "/sdcard/Android/data/com.anezium.r08accessbridge/files/shortcut_bridge/request",
            restoreAtStartup: true
        ),
        Helper(
            path: "/data/local/tmp/r08-a11y-watchdog.sh",
            pidFile: "/data/local/tmp/r08-a11y-watchdog.pid",
            sha256: "fcc0b20b166c8bd0f653913f3b3a08b28b1928ba62b4f8dba9807d8db5f646db",
            pendingRequest: nil,
            // 復旧のたびにMainActivityを開きHOMEを送るため、通常操作と競合する。
            // 入力サービスは起動時だけ登録し、この常駐監視は再開しない。
            restoreAtStartup: false
        ),
    ]

    static func isEnabled(
        packageList: String, services: String, armedSettings: String = ""
    ) -> Bool {
        let installed = packageList.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                == "package:\(package)" }
        let enabled = services.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .contains { String($0) == accessibilityService }
        let wasArmed = armedSettings.range(
            of: #"<boolean\s+name="bridge_armed"\s+value="true"\s*/>"#,
            options: .regularExpression
        ) != nil
        return installed && (enabled || wasArmed)
    }

    static func matchesHelpers(_ checksumOutput: String) -> Bool {
        let rows = checksumOutput.split(whereSeparator: \.isNewline)
        guard rows.count == helpers.count else { return false }
        var actual: [String: String] = [:]
        for row in rows {
            let fields = row.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { return false }
            let path = String(fields[1])
            guard actual[path] == nil else { return false }
            actual[path] = String(fields[0])
        }
        return helpers.allSatisfy { actual[$0.path] == $0.sha256 }
    }

    static func runningPID(_ status: String) -> String? {
        let pattern = #"^running pid=([1-9][0-9]*)(?:\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        for line in status.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)
            ), let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    static func isHelperProcess(_ commandLine: String, helper: Helper) -> Bool {
        commandLine.split { $0 == "\0" || $0.isWhitespace }
            .contains { String($0) == helper.path }
    }

    enum HelperAction: Equatable { case keep, start, stop }

    static var recoveryOrder: [Helper] {
        // 画面を戻す監視の停止を、新しい補助や入力サービスの復旧より先に行う。
        helpers.filter { !$0.restoreAtStartup } + helpers.filter { $0.restoreAtStartup }
    }

    static func action(for helper: Helper, isRunning: Bool) -> HelperAction {
        if helper.restoreAtStartup { return isRunning ? .keep : .start }
        return isRunning ? .stop : .keep
    }

    static func hasAccessibilityService(_ services: String) -> Bool {
        services.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":").contains { String($0) == accessibilityService }
    }

    /// 他のサービスを保持したまま、登録だけを復旧する。ActivityやHOMEは開かない。
    static func accessibilityRegistrationCommand(_ existing: String) -> String {
        let current = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let services = hasAccessibilityService(current) ? current
            : (current.isEmpty || current == "null" ? accessibilityService
                : current + ":" + accessibilityService)
        let quoted = "'" + services.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "settings put secure enabled_accessibility_services \(quoted)"
            + " && settings put secure accessibility_enabled 1"
    }

    /// 補助が止まった間の命令を、起動時に遅れて実行させない。
    /// 既存の通常ファイルだけを空にし、リンク先や個人記録には触れない。
    static func resetPendingRequestCommand(_ path: String) -> String {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "if [ -f \(quoted) ] && [ ! -L \(quoted) ]; then : > \(quoted); fi"
    }

    /// 設定を書き換えただけで稼働中の入口が残る場合も見逃さない。
    static func legacyListenerIsClosed(_ sockets: String) -> Bool {
        let lines = sockets.split(whereSeparator: \.isNewline)
        guard let header = lines.first,
              header.contains("State"), header.contains("Local Address:Port")
        else { return false }
        for line in lines.dropFirst() {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 5, fields[0] == "LISTEN" else {
                return false
            }
            if fields[3].hasSuffix(":5555") { return false }
        }
        return true
    }
}
