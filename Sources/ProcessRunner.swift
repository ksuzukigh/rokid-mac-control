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
    /// 利用者がキャンセルしたために止めた場合は`true`。
    /// 時間切れ（`timedOut`）とは別に扱う。
    let cancelled: Bool

    init(
        status: Int32,
        output: String,
        timedOut: Bool,
        cancelled: Bool = false
    ) {
        self.status = status
        self.output = output
        self.timedOut = timedOut
        self.cancelled = cancelled
    }

    var succeeded: Bool {
        status == 0 && !timedOut && !cancelled
    }
}

/// 外部コマンドを実行する。実行中のものを利用者のキャンセルで止められる。
///
/// 止める対象はこのアプリが直接起動したプロセスだけでよい。ここで実行するのは
/// `adb` と `dns-sd` で、どちらも子プロセスを作らないためである（`adb` の常駐
/// サーバーは別プロセスで、こちらが起動したものではないので止めない）。
/// Windows版のプロセスツリー終了処理は移植しない。
final class ProcessRunner {
    private let environment: [String: String]
    private let lock = NSLock()
    // プロセスIDは終了後に別のプロセスへ再利用されうるので、鍵には使わない。
    private var nextToken = 0
    private var runningProcesses: [Int: Process] = [:]
    private var cancelled = false

    init(environment: [String: String]) {
        self.environment = environment
    }

    /// 利用者のキャンセルを、実行中および以降のコマンドへ伝える。
    ///
    /// `resumeAfterCancellation()` を呼ぶまで、新しいコマンドは実行せずに
    /// キャンセル結果を返す。長いADB待機の後ろで終了処理が詰まらないようにする。
    func cancel() {
        lock.lock()
        cancelled = true
        let processes = Array(runningProcesses.values)
        lock.unlock()

        for process in processes where process.isRunning {
            process.terminate()
        }
        // SIGTERMで終わらないものだけ、少し待ってから強制終了する。
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            for process in processes where process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// キャンセル状態を解除し、次の接続に備える。
    func resumeAfterCancellation() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func run(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval = 8
    ) -> CommandResult {
        if isCancelled {
            return CommandResult(
                status: -1,
                output: "",
                timedOut: false,
                cancelled: true
            )
        }

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

        let token = register(process)
        // 起動とcancel()が行き違った場合に取りこぼさないための確認。
        if isCancelled, process.isRunning {
            process.terminate()
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

        // 先に登録を外す。waitUntilExitでプロセスIDが解放されたあとに
        // 別のプロセスと取り違えないようにするため。
        unregister(token)
        process.waitUntilExit()
        outputHandle.readabilityHandler = nil
        let remaining = outputHandle.readDataToEndOfFile()
        collected.append(remaining)
        let data = collected.snapshot()
        // キャンセルで止めた場合は時間切れとして扱わない。
        let wasCancelled = isCancelled && process.terminationStatus != 0
        return CommandResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? "",
            timedOut: timedOut && !wasCancelled,
            cancelled: wasCancelled
        )
    }

    private func register(_ process: Process) -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextToken += 1
        runningProcesses[nextToken] = process
        return nextToken
    }

    private func unregister(_ token: Int) {
        lock.lock()
        runningProcesses.removeValue(forKey: token)
        lock.unlock()
    }
}
