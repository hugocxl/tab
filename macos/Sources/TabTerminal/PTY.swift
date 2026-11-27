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

    /// Forks a child that leads a new session with the PTY as its controlling
    /// terminal (`setsid` + `TIOCSCTTY`, as `login_tty` does), then execs.
    /// `posix_spawn` can't: it opens files before `setsid`, so only programs
    /// that reopen their terminal (sh, bash) got one, and zsh ran without job
    /// control or Ctrl+C. Everything the child uses is prepared before the
    /// fork and the child makes only async-signal-safe calls. A failure
    /// before the exec comes back through a close-on-exec pipe.
    private static func spawn(_ request: SpawnRequest, slave: String) throws -> pid_t {
        guard let program = executable(request.program) else { throw PTYError(.spawn, code: ENOENT) }
        let argv = CStrings([request.argv0 ?? request.program] + request.arguments)
        let envp = CStrings(request.environment.map { "\($0.key)=\($0.value)" })
        let paths = CStrings([program, slave, request.workingDirectory])
        guard let programPath = paths.pointers[0], let slavePath = paths.pointers[1],
              let directory = paths.pointers[2] else { throw PTYError(.spawn, code: EINVAL) }
        var report: [Int32] = [-1, -1]
        guard pipe(&report) == 0 else { throw PTYError(.spawn) }
        defer { close(report[0]) }
        _ = fcntl(report[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(report[1], F_SETFD, FD_CLOEXEC)
        let descriptors = descriptorLimit()

        let pid = argv.pointers.withUnsafeBufferPointer { arguments in
            envp.pointers.withUnsafeBufferPointer { environment in
                let pid = Fork.call()
                if pid == 0 {
                    child(program: programPath, argv: arguments.baseAddress!, envp: environment.baseAddress!,
                          slave: slavePath, directory: directory, report: report[1], descriptors: descriptors)
                }
                return pid
            }
        }
        let forkError = errno
        close(report[1])
        guard pid > 0 else { throw PTYError(.spawn, code: forkError) }
        if let code = childFailure(report[0]) {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            throw PTYError(.spawn, code: code)
        }
        return pid
    }

    /// The `errno` the child reported before its exec, or nil once the exec
    /// closed the pipe.
    private static func childFailure(_ descriptor: Int32) -> Int32? {
        var code: Int32 = 0
        var received = 0
        let size = MemoryLayout<Int32>.size
        while received < size {
            let count = withUnsafeMutableBytes(of: &code) { bytes in
                read(descriptor, bytes.baseAddress! + received, size - received)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            received += count
        }
        return received == 0 ? nil : code
    }

    /// The forked child. Never returns.
    private static func child(program: UnsafePointer<CChar>, argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
                              envp: UnsafePointer<UnsafeMutablePointer<CChar>?>, slave: UnsafePointer<CChar>,
                              directory: UnsafePointer<CChar>, report: Int32, descriptors: Int32) -> Never {
        var mask = sigset_t()
        sigemptyset(&mask)
        sigprocmask(SIG_SETMASK, &mask, nil)
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_DFL
        var signal: Int32 = 1
        while signal < NSIG {
            if signal != SIGKILL && signal != SIGSTOP { sigaction(signal, &action, nil) }
            signal += 1
        }
        guard setsid() >= 0 else { childFailed(report) }
        let terminal = open(slave, O_RDWR)
        guard terminal >= 0 else { childFailed(report) }
        guard ioctl(terminal, UInt(TIOCSCTTY), 0 as CInt) == 0 else { childFailed(report) }
        guard dup2(terminal, 0) >= 0, dup2(terminal, 1) >= 0, dup2(terminal, 2) >= 0 else { childFailed(report) }
        var descriptor: Int32 = 3
        while descriptor < descriptors {
            if descriptor != report { close(descriptor) }
            descriptor += 1
        }
        guard chdir(directory) == 0 else { childFailed(report) }
        execve(program, argv, envp)
        childFailed(report)
    }

    private static func childFailed(_ report: Int32) -> Never {
        var code = errno
        _ = withUnsafeBytes(of: &code) { Darwin.write(report, $0.baseAddress, $0.count) }
        _exit(127)
    }

    /// `program` itself when it has a slash, else the first executable of
    /// that name in this process's `PATH`, as `posix_spawnp` looks it up.
    static func executable(_ program: String) -> String? {
        guard !program.isEmpty else { return nil }
        if program.contains("/") { return program }
        let search = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for folder in search.split(separator: ":", omittingEmptySubsequences: false) {
            let path = (folder.isEmpty ? "." : String(folder)) + "/" + program
            if access(path, X_OK) == 0 { return path }
        }
        return nil
    }

    /// The child closes every descriptor below this: past the highest one
    /// open now, with room for any that another thread opens before the fork
    /// (new descriptors take the lowest free numbers), within the limit.
    private static func descriptorLimit() -> Int32 {
        var limit = rlimit()
        let ceiling = getrlimit(RLIMIT_NOFILE, &limit) == 0 ? Int32(clamping: limit.rlim_cur) : Int32(OPEN_MAX)
        let size = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return ceiling }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / size + 64)
        let filled = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * size))
        guard filled > 0 else { return ceiling }
        let highest = descriptors.prefix(Int(filled) / size).map(\.proc_fd).max() ?? 2
        return min(ceiling, highest + 257)
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

/// NUL-terminated C strings kept alive while a child is started.
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

/// `fork(2)`, which Swift marks unavailable in favor of `posix_spawn`; the
/// PTY needs it to give the child its controlling terminal.
private enum Fork {
    private typealias Function = @convention(c) () -> pid_t

    private static let function: Function = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork") else {
            fatalError("fork is missing from libSystem")
        }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static func call() -> pid_t { function() }
}
