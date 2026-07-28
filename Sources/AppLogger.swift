import Foundation

final class AppLogger {
    private static let maximumLogSize = 2_000_000
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

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

        logURL = logsDirectory.appendingPathComponent("Rokid Control.log")
        let rotatedURL = logsDirectory.appendingPathComponent(
            "Rokid Control.1.log"
        )
        if let attributes = try? FileManager.default.attributesOfItem(
            atPath: logURL.path
        ),
        let size = attributes[.size] as? NSNumber,
        size.intValue > Self.maximumLogSize {
            try? FileManager.default.removeItem(at: rotatedURL)
            try? FileManager.default.moveItem(at: logURL, to: rotatedURL)
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            _ = FileManager.default.createFile(
                atPath: logURL.path,
                contents: nil
            )
        }
        fileHandle = try FileHandle(forWritingTo: logURL)
        try fileHandle.seekToEnd()
        log("=== Rokid Control started ===")
    }

    func log(_ message: String) {
        queue.sync {
            let stamp = Self.formatter.string(from: Date())
            let line = "\(stamp) \(message)\n"
            try? fileHandle.write(contentsOf: Data(line.utf8))
        }
    }

    func close() {
        queue.sync {
            try? fileHandle.close()
        }
    }
}
