import Foundation

struct CommandResult {
    let status: Int32
    let output: String
    let timedOut: Bool

    var succeeded: Bool {
        status == 0 && !timedOut
    }
}

final class ProcessRunner {
    private let environment: [String: String]

    init(environment: [String: String]) {
        self.environment = environment
    }

    func run(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval = 8
    ) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return CommandResult(
                status: -1,
                output: error.localizedDescription,
                timedOut: false
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
