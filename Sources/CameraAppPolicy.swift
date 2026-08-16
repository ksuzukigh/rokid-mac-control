import Foundation

enum CameraAppPolicy {
    /// 背面カメラを専有し、Rokid画面自体にカラープレビューを出すアプリ。
    /// これらの起動中はRokid Control側のカメラ受信を停め、端末画面をそのまま表示する。
    static let fullScreenCameraPackages = [
        "com.rokid.os.sprite.assistserver",
        "com.android.camera2",
        "io.github.ksuzukigh.rokidzoomincamera",
    ]

    /// `dumpsys activity activities`の現在の最前面Activityだけを見る。
    /// 履歴に残ったCameraのActivityを、起動中と誤判定しない。
    static func isFullScreenCameraForeground(_ output: String) -> Bool {
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
                    && fullScreenCameraPackages.contains { packageName in
                        value.contains("\(packageName)/")
                    }
            }
    }
}
