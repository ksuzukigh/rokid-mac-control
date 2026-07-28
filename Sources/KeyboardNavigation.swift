import Foundation

enum LowerNavigationItem: Int, CaseIterable {
    case memo
    case home
    case applications

    var title: String {
        switch self {
        case .memo:
            return "メモ"
        case .home:
            return "Home"
        case .applications:
            return "アプリ一覧"
        }
    }

    func horizontalOffset(for screenWidth: Int) -> Int {
        (rawValue - LowerNavigationItem.home.rawValue)
            * (screenWidth / 15)
    }

    /// Home画面の下段アイコン位置（Rokidの座標系、左上が原点）。
    /// タップ位置と選択表示は必ずこの値を共用する。
    func devicePoint(forScreenWidth width: Int, height: Int) -> CGPoint {
        CGPoint(
            x: CGFloat(width) / 2 + CGFloat(horizontalOffset(for: width)),
            y: CGFloat(height) / 2
        )
    }
}

struct KeyboardNavigationState {
    private(set) var lowerItem: LowerNavigationItem?

    var isLowerRow: Bool {
        lowerItem != nil
    }

    @discardableResult
    mutating func enterLowerRow() -> LowerNavigationItem {
        lowerItem = .home
        return .home
    }

    @discardableResult
    mutating func moveLowerRow(by offset: Int) -> LowerNavigationItem? {
        guard let lowerItem else { return nil }
        let nextValue = min(
            max(
                lowerItem.rawValue + offset,
                LowerNavigationItem.memo.rawValue
            ),
            LowerNavigationItem.applications.rawValue
        )
        let next = LowerNavigationItem(rawValue: nextValue) ?? lowerItem
        self.lowerItem = next
        return next
    }

    @discardableResult
    mutating func leaveLowerRow() -> Bool {
        let wasLowerRow = lowerItem != nil
        lowerItem = nil
        return wasLowerRow
    }
}
