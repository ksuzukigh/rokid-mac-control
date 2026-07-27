import Foundation

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

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

        let collected = LockedDataBuffer()
        let outputHandle = pipe.fileHandleForReading
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collected.append(data)
        }

        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSemaphore.signal()
        }

        do {
            try process.run()
        } catch {
            outputHandle.readabilityHandler = nil
            return CommandResult(
                status: -1,
                output: error.localizedDescription,
                timedOut: false
            )
        }

        let timedOut = terminationSemaphore.wait(
            timeout: .now() + timeout
        ) == .timedOut
        if timedOut {
            process.terminate()
            if terminationSemaphore.wait(
                timeout: .now() + 0.5
            ) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminationSemaphore.wait(timeout: .now() + 1)
            }
        }

        process.waitUntilExit()
        outputHandle.readabilityHandler = nil
        let remaining = outputHandle.readDataToEndOfFile()
        collected.append(remaining)
        let data = collected.snapshot()
        return CommandResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
