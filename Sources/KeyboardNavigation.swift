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
