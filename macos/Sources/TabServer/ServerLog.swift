import Foundation
import os
import TabCore

/// The server's log file (`server.log`), mirrored to the unified log. One
/// line per entry: Unix seconds, level, message with line breaks escaped.
public final class ServerLog: @unchecked Sendable {
    public enum Level: String, Sendable {
        case info = "INFO"
        case error = "ERROR"
    }

    private let lock = NSLock()
    private var handle: FileHandle?
    private static let shared = ServerLog()
    /// Logs larger than this are moved aside to `server.log.1` at start.
    static let rotateBytes: UInt64 = 8 * 1024 * 1024

    /// Appends to `url` from now on.
    public static func open(_ url: URL) throws {
        let path = url.path
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64,
           size > rotateBytes {
            let previous = path + ".1"
            try? FileManager.default.removeItem(atPath: previous)
            try? FileManager.default.moveItem(atPath: path, toPath: previous)
        }
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        shared.lock.withLock { shared.handle = handle }
    }

    public static func info(_ message: String) {
        Log.server.info("\(message, privacy: .public)")
        shared.write(.info, message)
    }

    public static func error(_ message: String) {
        Log.server.error("\(message, privacy: .public)")
        shared.write(.error, message)
    }

    private func write(_ level: Level, _ message: String) {
        let escaped = message.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        let line = "\(Clock.now()) \(level.rawValue) \(escaped)\n"
        lock.withLock {
            guard let handle else { return }
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
