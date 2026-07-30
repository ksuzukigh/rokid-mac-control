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
        guard timeout.timedOut, !timeout.cancelled, elapsed < 1.5 else {
            throw TestError.timeout(timeout.timedOut, elapsed)
        }

        try testCancellationStopsRunningCommand()
        try testCancellationBlocksNewCommands()
        try testResumeAfterCancellation()

        print("ProcessRunner self-test passed")
    }

    /// 利用者のキャンセルが、実行中のコマンドを止める。
    /// 時間切れとは別の結果として扱う。
    private static func testCancellationStopsRunningCommand() throws {
        let runner = ProcessRunner(
            environment: ProcessInfo.processInfo.environment
        )
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            runner.cancel()
        }

        let started = Date()
        let result = runner.run(
            URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 30
        )
        let elapsed = Date().timeIntervalSince(started)

        guard result.cancelled, !result.timedOut, !result.succeeded,
              elapsed < 5
        else {
            throw TestError.cancellation(
                result.cancelled,
                result.timedOut,
                elapsed
            )
        }
    }

    /// キャンセル後は、新しいコマンドを実行せずにすぐ戻る。
    private static func testCancellationBlocksNewCommands() throws {
        let runner = ProcessRunner(
            environment: ProcessInfo.processInfo.environment
        )
        runner.cancel()

        let started = Date()
        let result = runner.run(
            URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 30
        )
        let elapsed = Date().timeIntervalSince(started)

        guard result.cancelled, !result.succeeded, elapsed < 1 else {
            throw TestError.cancellation(
                result.cancelled,
                result.timedOut,
                elapsed
            )
        }
    }

    /// キャンセル状態を解除すれば、後片付けのコマンドを実行できる。
    private static func testResumeAfterCancellation() throws {
        let runner = ProcessRunner(
            environment: ProcessInfo.processInfo.environment
        )
        runner.cancel()
        guard runner.isCancelled else {
            throw TestError.resume(false)
        }

        runner.resumeAfterCancellation()
        guard !runner.isCancelled else {
            throw TestError.resume(true)
        }

        let result = runner.run(
            URL(fileURLWithPath: "/bin/echo"),
            arguments: ["ok"],
            timeout: 5
        )
        guard result.succeeded, !result.cancelled else {
            throw TestError.resume(result.cancelled)
        }
    }

    enum TestError: Error {
        case largeOutput(Int32, Int, Bool)
        case timeout(Bool, TimeInterval)
        case cancellation(Bool, Bool, TimeInterval)
        case resume(Bool)
    }
}
