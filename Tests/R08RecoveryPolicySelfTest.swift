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

        let shortcut = R08RecoveryPolicy.helpers[0]
        let oldWatchdog = R08RecoveryPolicy.helpers[1]
        precondition(R08RecoveryPolicy.action(for: shortcut, isRunning: false) == .start)
        precondition(R08RecoveryPolicy.action(for: shortcut, isRunning: true) == .keep)
        precondition(R08RecoveryPolicy.action(for: oldWatchdog, isRunning: false) == .keep)
        precondition(R08RecoveryPolicy.action(for: oldWatchdog, isRunning: true) == .stop)
        precondition(R08RecoveryPolicy.recoveryOrder.map(\.path) == [oldWatchdog.path, shortcut.path])
        precondition(!R08RecoveryPolicy.hasAccessibilityService(service + ".fake"))

        let header = "State Recv-Q Send-Q Local Address:Port Peer Address:Port\n"
        precondition(R08RecoveryPolicy.legacyListenerIsClosed(header + "LISTEN 0 4 *:43627 *:*\n"))
        for address in ["*:5555", "0.0.0.0:5555", "127.0.0.1:5555", "[::1]:5555"] {
            precondition(!R08RecoveryPolicy.legacyListenerIsClosed(header + "LISTEN 0 4 \(address) *:*\n"))
        }
        precondition(!R08RecoveryPolicy.legacyListenerIsClosed("ss: Permission denied"))
        precondition(!R08RecoveryPolicy.legacyListenerIsClosed(header + "LISTEN incomplete"))
        testPendingRequestReset()
        testRegistrationWithoutNavigation()
        print("R08 recovery policy self-test passed")
    }

    private static func testRegistrationWithoutNavigation() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("r08-registration-test-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let log = folder.appendingPathComponent("calls")
            let mock = folder.appendingPathComponent("settings")
            try "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$R08_TEST_LOG\"\n"
                .write(to: mock, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mock.path)
            for forbidden in ["am", "input"] {
                let file = folder.appendingPathComponent(forbidden)
                try "#!/bin/sh\necho unexpected-navigation >> \"$R08_TEST_LOG\"\nexit 1\n"
                    .write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            }
            let service = R08RecoveryPolicy.accessibilityService
            let tricky = "other/service'$(touch \(folder.path)/unexpected)"
            let cases = [
                ("null\n", service),
                ("", service),
                ("other/service", "other/service:" + service),
                (service + ":other/service\n", service + ":other/service"),
                (tricky, tricky + ":" + service),
            ]
            for (before, expected) in cases {
                try "".write(to: log, atomically: true, encoding: .utf8)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", R08RecoveryPolicy.accessibilityRegistrationCommand(before)]
                process.environment = ["PATH": folder.path, "R08_TEST_LOG": log.path]
                try process.run(); process.waitUntilExit()
                precondition(process.terminationStatus == 0)
                let calls = try String(contentsOf: log).split(separator: "\n").map(String.init)
                precondition(calls == [
                    "put", "secure", "enabled_accessibility_services", expected,
                    "put", "secure", "accessibility_enabled", "1",
                ])
                precondition(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("unexpected").path))
            }
        } catch { preconditionFailure("Accessibility registration test failed: \(error)") }
    }

    private static func testPendingRequestReset() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("r08-request-test-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let request = folder.appendingPathComponent("request with ' quote")
            let personal = folder.appendingPathComponent("personal-record.txt")
            try "wifi_disable:old-request".write(to: request, atomically: true, encoding: .utf8)
            try "keep this record".write(to: personal, atomically: true, encoding: .utf8)
            runReset(request.path)
            let resetRequest = try String(contentsOf: request)
            precondition(resetRequest.isEmpty)
            try FileManager.default.removeItem(at: request)
            try FileManager.default.createSymbolicLink(at: request, withDestinationURL: personal)
            runReset(request.path)
            let keptRecord = try String(contentsOf: personal)
            precondition(keptRecord == "keep this record")
            let absent = folder.appendingPathComponent("not-created")
            runReset(absent.path)
            precondition(!FileManager.default.fileExists(atPath: absent.path))
        } catch { preconditionFailure("Pending-request reset test failed: \(error)") }
    }

    private static func runReset(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", R08RecoveryPolicy.resetPendingRequestCommand(path)]
        do { try process.run(); process.waitUntilExit() }
        catch { preconditionFailure("Cannot run request-reset test: \(error)") }
        precondition(process.terminationStatus == 0)
    }
}
