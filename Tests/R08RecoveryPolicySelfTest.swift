import Foundation

@main
enum R08RecoveryPolicySelfTest {
    static func main() {
        let package = "package:\(R08RecoveryPolicy.package)\n"
        let service = R08RecoveryPolicy.accessibilityService
        precondition(R08RecoveryPolicy.isEnabled(packageList: package, services: service))
        precondition(R08RecoveryPolicy.isEnabled(packageList: package, services: "other/service:\(service)\n"))
        precondition(!R08RecoveryPolicy.isEnabled(packageList: "package:\(R08RecoveryPolicy.package).fake\n", services: service))
        precondition(!R08RecoveryPolicy.isEnabled(packageList: package, services: service + ".fake"))
        precondition(!R08RecoveryPolicy.isEnabled(packageList: "", services: service))
        precondition(R08RecoveryPolicy.isEnabled(
            packageList: package, services: "",
            armedSettings: #"<map><boolean name="bridge_armed" value="true" /></map>"#
        ))
        precondition(!R08RecoveryPolicy.isEnabled(
            packageList: package, services: "",
            armedSettings: #"<map><boolean name="bridge_armed" value="false" /></map>"#
        ))
        precondition(!R08RecoveryPolicy.isEnabled(
            packageList: "", services: "",
            armedSettings: #"<map><boolean name="bridge_armed" value="true" /></map>"#
        ))

        let hashes = R08RecoveryPolicy.helpers
            .map { "\($0.sha256)  \($0.path)" }.joined(separator: "\n")
        precondition(R08RecoveryPolicy.matchesHelpers(hashes))
        precondition(!R08RecoveryPolicy.matchesHelpers(hashes.replacingOccurrences(of: "50e9", with: "0000")))
        precondition(!R08RecoveryPolicy.matchesHelpers(hashes + "\n" + hashes))
        precondition(!R08RecoveryPolicy.matchesHelpers("sha256sum: Permission denied"))

        precondition(R08RecoveryPolicy.runningPID("running pid=123 base=/path") == "123")
        precondition(R08RecoveryPolicy.runningPID("not running pid=123") == nil)
        precondition(R08RecoveryPolicy.runningPID("running pid=0") == nil)
        precondition(R08RecoveryPolicy.runningPID("running pid=123;echo") == nil)
        let helper = R08RecoveryPolicy.helpers[0]
        precondition(R08RecoveryPolicy.isHelperProcess("sh\0\(helper.path)\0run\0", helper: helper))
        precondition(!R08RecoveryPolicy.isHelperProcess("sh\0/tmp/other.sh\0run\0", helper: helper))

        let header = "State Recv-Q Send-Q Local Address:Port Peer Address:Port\n"
        precondition(R08RecoveryPolicy.legacyListenerIsClosed(header + "LISTEN 0 4 *:43627 *:*\n"))
        for address in ["*:5555", "0.0.0.0:5555", "127.0.0.1:5555", "[::1]:5555"] {
            precondition(!R08RecoveryPolicy.legacyListenerIsClosed(header + "LISTEN 0 4 \(address) *:*\n"))
        }
        precondition(!R08RecoveryPolicy.legacyListenerIsClosed("ss: Permission denied"))
        precondition(!R08RecoveryPolicy.legacyListenerIsClosed(header + "LISTEN incomplete"))
        print("R08 recovery policy self-test passed")
    }
}
