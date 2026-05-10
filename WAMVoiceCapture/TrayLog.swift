import Darwin
import Foundation
import OSLog

enum TrayLog {
    static let logger = Logger(subsystem: "com.artempolansky.wam-voice-capture", category: "tray")

    /// Plain-text log the user can read without Console.app (Application Support is reliable for GUI apps).
    static func append(_ line: String) {
        logger.info("\(line, privacy: .public)")
        fputs("WAM: \(line)\n", stderr)

        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let dir = base.appendingPathComponent("WAM Voice Capture", isDirectory: true)
        let url = dir.appendingPathComponent("wam-voice-capture-tray.txt", isDirectory: false)
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forWritingTo: url)
                try h.seekToEnd()
                try h.write(contentsOf: payload)
                try h.close()
            } else {
                try payload.write(to: url)
            }
        } catch {
            logger.error("log write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
