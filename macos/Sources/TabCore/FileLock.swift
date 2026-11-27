import Foundation

/// An exclusive advisory lock on a file, held until the value is released or
/// deinitialized. Locks are per open file, so a second lock of the same path
/// fails even in the same process.
public final class FileLock: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        /// Another owner holds the lock.
        case held
    }

    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Takes the lock on `url` without waiting, creating the file (owner-only)
    /// when it is missing. Throws `Failure.held` while someone else has it.
    public static func tryLock(_ url: URL) throws -> FileLock {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError(path: url.path) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw Failure.held }
            throw posixError(path: url.path, code: code)
        }
        return FileLock(descriptor: descriptor)
    }

    /// The open descriptor, for writing a pid into a lock file.
    public var fileDescriptor: Int32 { descriptor }

    /// Releases the lock now.
    public func unlock() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { unlock() }
}
