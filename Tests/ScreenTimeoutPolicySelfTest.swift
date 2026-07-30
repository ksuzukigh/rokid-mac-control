import Foundation

@main
enum ScreenTimeoutPolicySelfTest {
    static func main() {
        precondition(
            ScreenTimeoutPolicy.originalValue(from: "5000\n") == "5000"
        )
        precondition(
            ScreenTimeoutPolicy.originalValue(
                from: "* daemon started successfully\n5000\n"
            ) == "5000"
        )
        precondition(
            ScreenTimeoutPolicy.originalValue(from: "86400000\n")
                == "86400000"
        )
        precondition(ScreenTimeoutPolicy.originalValue(from: "0\n") == nil)
        precondition(ScreenTimeoutPolicy.originalValue(from: "-1\n") == nil)
        precondition(ScreenTimeoutPolicy.originalValue(from: "null\n") == nil)
        precondition(
            ScreenTimeoutPolicy.originalValue(from: "5000\n6000\n") == nil
        )
        precondition(ScreenTimeoutPolicy.macModeValue == "86400000")
        print("Screen timeout policy self-test passed")
    }
}
