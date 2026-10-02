import Foundation

/// 現在のRV101純正設定画面だけへ左右キーを渡す。
enum SystemAdjustmentPolicy {
    static let package = "com.rokid.os.sprite.launcher"
    static let activities = [
        ".page.volume.SettingVolumeActivity",
        ".page.brightness.SettingBrightnessActivity",
    ]

    static func isForeground(_ output: String) -> Bool {
        let current = output.split(whereSeparator: \.isNewline).filter {
            let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.contains("topResumedActivity=")
                || line.hasPrefix("mResumedActivity:") || line.hasPrefix("ResumedActivity:")
        }
        return current.contains { line in
            activities.contains { activity in
                ["\(package)/\(activity)", "\(package)/\(package)\(activity)"].contains { component in
                    line.range(of: NSRegularExpression.escapedPattern(for: component) + #"[\s}]"#,
                               options: .regularExpression) != nil
                }
            }
        }
    }
}
