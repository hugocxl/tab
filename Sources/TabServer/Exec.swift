import Darwin
import Foundation
import TabProtocol

/// Programs a connection runs in project folders, without a terminal. Each
/// job runs on its own thread; cancelling or disconnecting stops it.
final class ExecJobs: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [UInt64: CancelFlag] = [:]
    /// Cancellations that arrived before their job.
    private var early: [UInt64] = []
    static let maxActive = 32

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    func cancel(_ job: UInt64) {
        lock.withLock {
            if let flag = active[job] {
                flag.set()
                return
            }
            early.append(job)
            if early.count > 128 { early.removeFirst() }
        }
    }

    func cancelAll() {
        lock.withLock { active.values.forEach { $0.set() } }
    }

    /// Starts `request` in `root`; `completion` gets its result on the job's thread.
    func start(_ request: ExecRequest, root: String, disconnected: @escaping @Sendable () -> Bool,
               completion: @escaping @Sendable (Result<ExecResult, Error>) -> Void) throws {
        let flag = try lock.withLock { () throws -> CancelFlag in
            guard active.count < Self.maxActive, active[request.job] == nil else {
                throw ServiceError(.badRequest, "Too many commands, or a duplicate job ID")
            }
            let flag = CancelFlag()
            if let index = early.firstIndex(of: request.job) {
                early.remove(at: index)
                flag.set()
            }
            active[request.job] = flag
            return flag
        }
        let thread = Thread { [self] in
            var request = request
            if request.env["PATH"] == nil, let path = LoginPath.value {
                request.env["PATH"] = path
            }
            let result = Result { try Exec.run(request, root: root) { flag.isSet || disconnected() } }
            lock.withLock { active[request.job] = nil }
            completion(result)
        }
        thread.name = "exec-\(request.job)"
        thread.start()
    }
}

/// Runs one program with pipes for its input and output.
enum Exec {
    /// Runs `request` in `root` (or its `cwd`), killing its process group on
    /// cancellation or timeout. Output beyond `Limits.maxExecOutput` is dropped.
    static func run(_ request: ExecRequest, root: String, cancelled: () -> Bool) throws -> ExecResult {
        do {
            try request.validate()
        } catch {
            throw ServiceError(.badRequest, "The command is not valid")
        }
        if cancelled() { return ExecResult(exitCode: -1, cancelled: true) }
        let argv = request.shell.map { ["/bin/sh", "-c", $0] } ?? request.argv
        let directory = workingDirectory(root: root, cwd: request.cwd)
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in request.env { environment[key] = value }
        let child = try Child(argv: argv, environment: environment, directory: directory)
        return supervise(child, request: request, cancelled: cancelled)
    }

    /// `~` is the home folder; relative paths start in the project folder.
    static func workingDirectory(root: String, cwd: ServerPath?) -> String {
        guard let cwd = cwd?.rawValue, !cwd.isEmpty else { return root }
        if cwd == "~" { return NSHomeDirectory() }
        if cwd.hasPrefix("~/") { return (NSHomeDirectory() as NSString).appendingPathComponent(String(cwd.dropFirst(2))) }
        if cwd.hasPrefix("/") { return cwd }
        return (root as NSString).appendingPathComponent(cwd)
    }

    private static func supervise(_ child: Child, request: ExecRequest, cancelled: () -> Bool) -> ExecResult {
        var stdout = Data()
        var stderr = Data()
        var truncated = false
        var written = 0
        var stdinOpen = true
        var outputOpen = true
        var errorOpen = true
        var timedOut = false
        var wasCancelled = false
        var stopping: Date?
        var exited: Date?
        var code: Int32 = -1
        let start = Date()
        let timeout = TimeInterval(request.timeoutMs) / 1000
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        if request.stdin.isEmpty {
            child.closeInput()
            stdinOpen = false
        }
        while true {
            var fds: [pollfd] = []
            if outputOpen { fds.append(pollfd(fd: child.output, events: Int16(POLLIN), revents: 0)) }
            if errorOpen { fds.append(pollfd(fd: child.errors, events: Int16(POLLIN), revents: 0)) }
            if stdinOpen { fds.append(pollfd(fd: child.input, events: Int16(POLLOUT), revents: 0)) }
            _ = poll(&fds, nfds_t(fds.count), 20)

            if outputOpen { outputOpen = drain(child.output, into: &stdout, buffer: &buffer, truncated: &truncated) }
            if errorOpen { errorOpen = drain(child.errors, into: &stderr, buffer: &buffer, truncated: &truncated) }
            if stdinOpen {
                let remaining = request.stdin.count - written
                let count = request.stdin.withUnsafeBytes { bytes -> Int in
                    guard let base = bytes.baseAddress else { return 0 }
                    return Darwin.write(child.input, base + written, remaining)
                }
                if count > 0 { written += count }
                if count < 0, errno != EAGAIN, errno != EINTR { written = request.stdin.count }
                if written >= request.stdin.count {
                    child.closeInput()
                    stdinOpen = false
                }
            }
            wasCancelled = wasCancelled || cancelled()
            timedOut = timedOut || Date().timeIntervalSince(start) >= timeout
            if (wasCancelled || timedOut) && stopping == nil {
                child.signal(SIGTERM)
                stopping = Date()
            }
            if let stopping, Date().timeIntervalSince(stopping) >= 0.15 {
                child.signal(SIGKILL)
            }
            if exited == nil, let status = child.poll() {
                code = status
                exited = Date()
                child.signal(SIGKILL)
            }
            if let exited, (!outputOpen && !errorOpen) || Date().timeIntervalSince(exited) >= 0.25 {
                break
            }
        }
        return ExecResult(stdout: text(stdout, truncated: &truncated), stderr: text(stderr, truncated: &truncated),
                          exitCode: code, timedOut: timedOut, truncated: truncated, cancelled: wasCancelled)
    }

    /// Reads what is available; false once the pipe is closed.
    private static func drain(_ descriptor: Int32, into data: inout Data, buffer: inout [UInt8],
                              truncated: inout Bool) -> Bool {
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { return false }
            if count < 0 {
                if errno == EINTR { continue }
                return errno == EAGAIN
            }
            let take = min(count, max(0, Limits.maxExecOutput - data.count))
            data.append(contentsOf: buffer[0..<take])
            truncated = truncated || take < count
        }
        return true
    }

    private static func text(_ data: Data, truncated: inout Bool) -> String {
        var text = String(decoding: data, as: UTF8.self)
        while text.utf8.count > Limits.maxExecOutput {
            text.removeLast()
            truncated = true
        }
        return text
    }
}

/// A child process in its own process group, with non-blocking pipes.
private final class Child {
    let pid: pid_t
    private(set) var input: Int32
    let output: Int32
    let errors: Int32
    private var status: Int32?

    init(argv: [String], environment: [String: String], directory: String) throws {
        var pipes: [[Int32]] = []
        for _ in 0..<3 {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw ServiceError(.spawnFailed, "Could not create a pipe") }
            pipes.append(fds)
        }
        defer {
            close(pipes[0][0])
            close(pipes[1][1])
            close(pipes[2][1])
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pipes[0][0], 0)
        posix_spawn_file_actions_adddup2(&actions, pipes[1][1], 1)
        posix_spawn_file_actions_adddup2(&actions, pipes[2][1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let arguments = argv.map { strdup($0) } + [nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            arguments.forEach { free($0) }
            variables.forEach { free($0) }
        }
        var pid: pid_t = 0
        let program = argv[0]
        let result = program.contains("/")
            ? posix_spawn(&pid, program, &actions, &attributes, arguments, variables)
            : posix_spawnp(&pid, program, &actions, &attributes, arguments, variables)
        guard result == 0 else {
            close(pipes[0][1])
            close(pipes[1][0])
            close(pipes[2][0])
            if result == ENOENT, !program.contains("/") {
                throw ServiceError(.spawnFailed, "command not found: \(program)")
            }
            throw ServiceError(.spawnFailed, "spawn process: \(String(cString: strerror(result)))")
        }
        self.pid = pid
        input = pipes[0][1]
        output = pipes[1][0]
        errors = pipes[2][0]
        for descriptor in [input, output, errors] {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(input, F_SETNOSIGPIPE, 1)
    }

    func closeInput() {
        guard input >= 0 else { return }
        close(input)
        input = -1
    }

    func signal(_ signal: Int32) {
        guard status == nil || signal == SIGKILL else { return }
        _ = killpg(pid, signal)
    }

    /// The exit code once the program ended, without blocking.
    func poll() -> Int32? {
        if let status { return status }
        var raw: Int32 = 0
        guard waitpid(pid, &raw, WNOHANG) == pid else { return nil }
        let code = raw & 0x7f == 0 ? (raw >> 8) & 0xff : -1
        status = code
        return code
    }

    deinit {
        _ = killpg(pid, SIGKILL)
        if status == nil {
            var raw: Int32 = 0
            _ = waitpid(pid, &raw, 0)
        }
        closeInput()
        close(output)
        close(errors)
    }
}
