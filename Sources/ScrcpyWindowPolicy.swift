import CoreGraphics
import Foundation

struct ScrcpyWindowCandidate {
    let bounds: CGRect
    let layer: Int
    let alpha: Double
}

enum ScrcpyWindowPolicy {
    /// scrcpyと同じプロセスが補助ウインドウを持つ場合でも、画面本体を選ぶ。
    static func bestBounds(
        from candidates: [ScrcpyWindowCandidate]
    ) -> CGRect? {
        candidates
            .filter {
                $0.layer == 0
                    && $0.alpha > 0
                    && $0.bounds.width > 0
                    && $0.bounds.height > 0
            }
            .max {
                ($0.bounds.width * $0.bounds.height)
                    < ($1.bounds.width * $1.bounds.height)
            }?
            .bounds
    }
}
