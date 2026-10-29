import Darwin
import Foundation
import TabProtocol

/// What to run in a new PTY.
public struct SpawnRequest: Hashable, Sendable {
    /// Absolute path of the program, or a name looked up in this process's `PATH`.
    public var program: String
    public var arguments: [String]
    /// `argv[0]`, e.g. `-zsh` for a login shell; defaults to `program`.
    public var argv0: String?
    /// The complete environment of the program.
    public var environment: [String: String]
    public var workingDirectory: String
    public var size: Size
    public var cellSize: CellSize

    public init(
        program: String, arguments: [String] = [], argv0: String? = nil, environment: [String: String] = [:],
        workingDirectory: String, size: Size, cellSize: CellSize = CellSize(width: 0, height: 0)
    ) {
        self.program = program
        self.arguments = arguments
        self.argv0 = argv0
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.size = size
        self.cellSize = cellSize
    }
}

/// How the program ended.
public enum PTYExit: Hashable, Sendable {
    case exited(code: Int32)
    case signaled(signal: Int32)
}

/// A program running on a pseudo-terminal. The program leads a new session
/// with the PTY as its controlling terminal.
public final class PTY {
    public let pid: pid_t
    /// The master side; also useful for `tcgetpgrp` (foreground process).
    public let masterFD: Int32
    private let lock = NSLock()
    private var size: Size
    private var cell: CellSize
    private var exit: PTYExit?
    private var readerStarted = false

    public init(spawning request: SpawnRequest) throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw PTYError(.open) }
        do {
            guard grantpt(master) == 0, unlockpt(master) == 0 else { throw PTYError(.open) }
            _ = fcntl(master, F_SETFD, FD_CLOEXEC)
            var name = [CChar](repeating: 0, count: 128)
            guard ptsname_r(master, &name, name.count) == 0 else { throw PTYError(.open) }
            let path = String(cString: name)
            let slave = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC)
            guard slave >= 0 else { throw PTYError(.open) }
            defer { close(slave) }
            try Self.setWindowSize(slave, size: request.size, cell: request.cellSize, step: .open)
            pid = try Self.spawn(request, slave: path)
        } catch {
            close(master)
            throw error
        }
        masterFD = master
        size = request.size
        cell = request.cellSize
    }

    /// Dropping the PTY hangs up a program that is still running, as closing
    /// a terminal window does. Call `waitForExit()` somewhere to reap it.
    deinit {
        if exitReason() == nil {
            Darwin.kill(pid, SIGHUP)
        }
        close(masterFD)
    }

    private static func spawn(_ request: SpawnRequest, slave: String) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slave, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, request.workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = CStrings([request.argv0 ?? request.program] + request.arguments)
        let envp = CStrings(request.environment.map { "\($0.key)=\($0.value)" })
        var pid: pid_t = 0
        let result = request.program.contains("/")
            ? posix_spawn(&pid, request.program, &actions, &attributes, argv.pointers, envp.pointers)
            : posix_spawnp(&pid, request.program, &actions, &attributes, argv.pointers, envp.pointers)
        guard result == 0 else { throw PTYError(.spawn, code: result) }
        return pid
    }

    /// Starts a thread that blocks on `read(2)` and hands every chunk to
    /// `output` as soon as it arrives, then calls `closed` once the program's
    /// side of the PTY is gone. Call once.
    public func startReader(
        output: @escaping @Sendable (Data) -> Void, closed: @escaping @Sendable () -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !readerStarted else { return }
        let descriptor = dup(masterFD)
        guard descriptor >= 0 else { throw PTYError(.open) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        readerStarted = true
        let thread = Thread {
            let capacity = 64 * 1024
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
            defer {
                buffer.deallocate()
                close(descriptor)
                closed()
            }
            while true {
                let count = read(descriptor, buffer, capacity)
                if count > 0 {
                    output(Data(bytes: buffer, count: count))
                } else if count < 0, errno == EINTR || errno == EAGAIN {
                    continue
                } else {
                    return
                }
            }
        }
        thread.name = "pty-reader-\(pid)"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Writes all of `data`, retrying partial writes.
    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(masterFD, pointer, remaining)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw PTYError(.write)
                }
                pointer += written
                remaining -= written
            }
        }
    }

    public func resize(_ size: Size) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.setWindowSize(masterFD, size: size, cell: cell, step: .resize)
        self.size = size
    }

    /// The cell size in pixels, reported to programs in the window size.
    public func setCellSize(_ cell: CellSize) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.setWindowSize(masterFD, size: size, cell: cell, step: .resize)
        self.cell = cell
    }

    private static func setWindowSize(_ descriptor: Int32, size: Size, cell: CellSize, step: PTYStep) throws {
        var window = winsize(
            ws_row: size.rows, ws_col: size.cols,
            ws_xpixel: size.cols &* cell.width, ws_ypixel: size.rows &* cell.height)
        guard ioctl(descriptor, TIOCSWINSZ, &window) == 0 else { throw PTYError(step) }
    }

    /// Sends `signal` to the program; the default is a hang-up, as when a
    /// terminal window closes.
    public func kill(_ signal: Int32 = SIGHUP) throws {
        guard exitReason() == nil else { return }
        guard Darwin.kill(pid, signal) == 0 || errno == ESRCH else { throw PTYError(.kill) }
    }

    /// Kills the program outright.
    public func terminate() throws {
        try kill(SIGKILL)
    }

    /// How the program ended, or nil while it runs. Never blocks.
    public func exitReason() -> PTYExit? {
        lock.lock()
        defer { lock.unlock() }
        if let exit { return exit }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid else { return nil }
        exit = Self.reason(status)
        return exit
    }

    /// Blocks until the program ends.
    public func waitForExit() throws -> PTYExit {
        while true {
            if let exit = exitReason() { return exit }
            var status: Int32 = 0
            let result = waitpid(pid, &status, 0)
            if result == pid {
                lock.lock()
                defer { lock.unlock() }
                let reason = exit ?? Self.reason(status)
                exit = reason
                return reason
            }
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == ECHILD, let exit = exitReason() { return exit }
            throw PTYError(.wait)
        }
    }

    private static func reason(_ status: Int32) -> PTYExit {
        let signal = status & 0x7f
        return signal == 0 ? .exited(code: (status >> 8) & 0xff) : .signaled(signal: signal)
    }
}

/// NUL-terminated C strings kept alive for a `posix_spawn` call.
private final class CStrings {
    let pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
        pointers = strings.map { strdup($0) } + [nil]
    }

    deinit {
        for pointer in pointers {
            free(pointer)
        }
    }
}
