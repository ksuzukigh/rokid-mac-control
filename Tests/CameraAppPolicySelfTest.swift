import Foundation

@main
enum CameraAppPolicySelfTest {
    static func main() {
        precondition(
            CameraAppPolicy.isOriginalCameraForeground(
                """
                topResumedActivity=ActivityRecord{123 u0 \
                com.android.camera2/com.android.camera.CameraActivity t42}
                """
            )
        )
        precondition(
            CameraAppPolicy.isOriginalCameraForeground(
                """
                topResumedActivity=ActivityRecord{123 u0 \
                com.rokid.os.sprite.assistserver/\
                com.rokid.os.sprite.assist.media.page.CameraActivity t42}
                """
            )
        )
        precondition(
            CameraAppPolicy.isOriginalCameraForeground(
                """
                ResumedActivity: ActivityRecord{123 u0 \
                com.android.camera2/com.android.camera.CameraActivity t42}
                """
            )
        )
        precondition(
            !CameraAppPolicy.isOriginalCameraForeground(
                """
                topResumedActivity=ActivityRecord{123 u0 \
                com.rokid.os.sprite.launcher/.main.SpriteMainActivity t42}
                Hist #1: ActivityRecord{456 u0 \
                com.android.camera2/com.android.camera.CameraActivity t41}
                """
            )
        )
        precondition(
            !CameraAppPolicy.isOriginalCameraForeground(
                """
                topResumedActivity=ActivityRecord{123 u0 \
                io.github.ksuzukigh.phototomac/.MainActivity t42}
                """
            )
        )
        print("Camera app policy self-test passed")
    }
}
