import Foundation

@main
enum KeyboardNavigationSelfTest {
    static func main() {
        var state = KeyboardNavigationState()
        precondition(!state.isLowerRow)

        precondition(state.enterLowerRow() == .home)
        precondition(state.isLowerRow)
        precondition(state.moveLowerRow(by: -1) == .memo)
        precondition(state.moveLowerRow(by: -1) == .memo)
        precondition(state.moveLowerRow(by: 1) == .home)
        precondition(state.moveLowerRow(by: 1) == .applications)
        precondition(state.moveLowerRow(by: 1) == .applications)
        precondition(state.leaveLowerRow())
        precondition(!state.leaveLowerRow())
        precondition(!state.isLowerRow)

        precondition(
            LowerNavigationItem.memo.horizontalOffset(for: 480) == -32
        )
        precondition(
            LowerNavigationItem.home.horizontalOffset(for: 480) == 0
        )
        precondition(
            LowerNavigationItem.applications.horizontalOffset(for: 480) == 32
        )
        print("Keyboard navigation self-test passed")
    }
}
