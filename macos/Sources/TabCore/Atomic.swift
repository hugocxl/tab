import Foundation

/// Crash-safe replacement of private files: a crash leaves either the old
/// file or the new one, never a mix.
public enum AtomicFile {
    /// Replaces `url` with `data`, readable only by its owner, and makes the
    /// replacement durable. Creates missing parent folders.
    public static func write(_ data: Data, to url: URL, permissions: mode_t = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (temporary, descriptor) = try createTemporary(beside: url, permissions: permissions)
        do {
            try writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else { throw posixError(path: temporary) }
            close(descriptor)
            guard rename(temporary, url.path) == 0 else { throw posixError(path: url.path) }
        } catch {
            close(descriptor)
            unlink(temporary)
            throw error
        }
        try syncDirectory(directory)
    }

    private static let counter = Counter()

    private static func createTemporary(beside url: URL, permissions: mode_t) throws -> (String, Int32) {
        let directory = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        var attempts = 0
        while true {
            let path = "\(directory)/.\(name)-\(getpid())-\(counter.next()).tmp"
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
            if descriptor >= 0 { return (path, descriptor) }
            if errno == EEXIST && attempts < 16 {
                attempts += 1
                continue
            }
            throw posixError(path: path)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(path: nil)
                }
                remaining -= written
                pointer += written
            }
        }
    }

    /// Syncs a directory so a rename into it survives a crash.
    public static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(path: directory.path) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(path: directory.path) }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

func posixError(path: String?, code: Int32 = errno) -> Error {
    var info: [String: Any] = [:]
    if let path { info[NSFilePathErrorKey] = path }
    return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: info)
}
