import Foundation

enum CameraAppPolicy {
    /// RV101のホームから開くRokid独自の撮影画面と、Android標準Camera。
    /// 地域・本体ソフトウェアによって入口が異なるため両方を扱う。
    static let originalCameraPackages = [
        "com.rokid.os.sprite.assistserver",
        "com.android.camera2",
    ]

    /// `dumpsys activity activities`の現在の最前面Activityだけを見る。
    /// 履歴に残ったCameraのActivityを、起動中と誤判定しない。
    static func isOriginalCameraForeground(_ output: String) -> Bool {
        output
            .split(whereSeparator: \.isNewline)
            .contains { line in
                let value = line.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let isCurrentActivity =
                    value.contains("topResumedActivity=")
                    || value.hasPrefix("mResumedActivity:")
                    || value.hasPrefix("ResumedActivity:")
                return isCurrentActivity
                    && originalCameraPackages.contains { packageName in
                        value.contains("\(packageName)/")
                    }
            }
    }
}
