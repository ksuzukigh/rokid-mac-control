import Foundation

final class AppLogger {
    let fileHandle: FileHandle
    let logURL: URL
    private let queue = DispatchQueue(label: "RokidControl.Logger")

    init() throws {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true
        )

        logURL = logsDirectory.appendingPathComponent("Rokid Control DMG.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        fileHandle = try FileHandle(forWritingTo: logURL)
        try fileHandle.seekToEnd()
        log("=== Rokid Control DMG started \(Date()) ===")
    }

    func log(_ message: String) {
        queue.sync {
            let line = "\(message)\n"
            try? fileHandle.write(contentsOf: Data(line.utf8))
        }
    }

    func close() {
        queue.sync {
            try? fileHandle.close()
        }
    }
}
