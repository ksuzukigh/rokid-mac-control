import Foundation

@main
enum ADBServerPolicySelfTest {
    static func main() {
        precondition(ADBServerPolicy.dedicatedPort == "5038")
        precondition(
            ADBServerPolicy.indicatesLocalNetworkBlock(
                "failed to connect: No route to host"
            )
        )
        precondition(
            ADBServerPolicy.indicatesLocalNetworkBlock(
                "NETWORK IS UNREACHABLE"
            )
        )
        precondition(
            !ADBServerPolicy.indicatesLocalNetworkBlock(
                "failed to connect: Connection refused"
            )
        )
        precondition(
            !ADBServerPolicy.indicatesLocalNetworkBlock(
                "failed to connect: Operation timed out"
            )
        )
        print("ADB server policy self-test passed")
    }
}
