import Foundation

@main
enum ProcessRunnerSelfTest {
    static func main() throws {
        let runner = ProcessRunner(
            environment: ProcessInfo.processInfo.environment
        )

        let largeOutput = runner.run(
            URL(fileURLWithPath: "/usr/bin/awk"),
            arguments: [
                "BEGIN { for (i = 0; i < 20000; i++) print \"Rokid-Control-ProcessRunner\" }",
            ],
            timeout: 5
        )
        guard largeOutput.succeeded,
              largeOutput.output.utf8.count > 400_000
        else {
            throw TestError.largeOutput(
                largeOutput.status,
                largeOutput.output.utf8.count,
                largeOutput.timedOut
            )
        }

        let started = Date()
        let timeout = runner.run(
            URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["2"],
            timeout: 0.1
        )
        let elapsed = Date().timeIntervalSince(started)
        guard timeout.timedOut, elapsed < 1.5 else {
            throw TestError.timeout(timeout.timedOut, elapsed)
        }

        print("ProcessRunner self-test passed")
    }

    enum TestError: Error {
        case largeOutput(Int32, Int, Bool)
        case timeout(Bool, TimeInterval)
    }
}
