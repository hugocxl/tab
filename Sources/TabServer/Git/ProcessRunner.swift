import Darwin
import Foundation

/// What a finished child process printed.
struct ProcessOutput: Sendable {
    var stdout: Data
    var stderr: Data
    /// The exit status, or 128 + signal when a signal ended it.
    var status: Int32
    /// Standard output was cut at `truncateStdout` and the process stopped.
    var truncated: Bool

    var succeeded: Bool { status == 0 }
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

enum ProcessFailure: Error, Equatable, CustomStringConvertible {
    case launch(String, Int32)
    case timedOut(String)
    case outputTooLarge(String)

    var description: String {
        switch self {
        case .launch(let program, let code): "Couldn't start \(program): \(String(cString: strerror(code)))"
        case .timedOut(let program): "\(program) timed out; refresh before retrying"
        case .outputTooLarge(let program): "\(program) printed more than the limit"
        }
    }
}

/// Runs programs directly (never through a shell) in their own process
/// group, with bounded output and a deadline that kills the whole group.
enum ProcessRunner {
    static let defaultOutputLimit = 4 * 1024 * 1024

    static func run(
        _ executable: String,
        _ arguments: [String],
        directory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        input: Data? = nil,
        timeout: TimeInterval = 20,
        outputLimit: Int = defaultOutputLimit,
        truncateStdout: Int? = nil
    ) throws -> ProcessOutput {
        let name = (executable as NSString).lastPathComponent
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else { throw ProcessFailure.launch(name, errno) }
        guard pipe(&stderrPipe) == 0 else {
            closeAll(stdoutPipe)
            throw ProcessFailure.launch(name, errno)
        }
        if input != nil, pipe(&stdinPipe) != 0 {
            let code = errno
            closeAll(stdoutPipe + stderrPipe)
            throw ProcessFailure.launch(name, code)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if input != nil {
            posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
        if let directory {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(stdoutPipe[1])
        close(stderrPipe[1])
        if input != nil { close(stdinPipe[0]) }
        guard spawned == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            if input != nil { close(stdinPipe[1]) }
            throw ProcessFailure.launch(name, spawned)
        }

        let writer = input.map { bytes -> DispatchGroup in
            let group = DispatchGroup()
            let descriptor = stdinPipe[1]
            DispatchQueue.global().async(group: group) {
                writeAll(bytes, to: descriptor)
                close(descriptor)
            }
            return group
        }

        let deadline = Date().addingTimeInterval(timeout)
        var stdout = Data()
        var stderr = Data()
        var truncated = false
        var failure: ProcessFailure?
        var open = [stdoutPipe[0], stderrPipe[0]]
        var buffer = [UInt8](repeating: 0, count: 65536)
        readLoop: while !open.isEmpty {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                failure = .timedOut(name)
                break
            }
            var descriptors = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&descriptors, nfds_t(descriptors.count), Int32(min(remaining, 1) * 1000) + 1)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            for descriptor in descriptors where descriptor.revents != 0 {
                let count = read(descriptor.fd, &buffer, buffer.count)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                if count <= 0 {
                    open.removeAll { $0 == descriptor.fd }
                    continue
                }
                if descriptor.fd == stdoutPipe[0] {
                    if let limit = truncateStdout, stdout.count + count > limit {
                        stdout.append(contentsOf: buffer[0 ..< max(0, limit - stdout.count)])
                        truncated = true
                        break readLoop
                    }
                    if stdout.count + count > outputLimit {
                        failure = .outputTooLarge(name)
                        break readLoop
                    }
                    stdout.append(contentsOf: buffer[0 ..< count])
                } else if stderr.count + count <= outputLimit {
                    stderr.append(contentsOf: buffer[0 ..< count])
                }
            }
        }
        if failure != nil || truncated || !open.isEmpty {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        close(stdoutPipe[0])
        close(stderrPipe[0])
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        writer?.wait()
        if let failure { throw failure }
        let exit: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return ProcessOutput(stdout: stdout, stderr: stderr, status: exit, truncated: truncated)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                remaining -= written
                pointer += written
            }
        }
    }

    private static func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
    }
}

/// Finds programs such as `git`, `gh` and `rg` for a server that may have
/// been started from the app with a minimal `PATH`.
struct ExecutableLookup: Sendable {
    /// Folders searched after `PATH`.
    static let fallbackFolders = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    private let find: @Sendable (String) -> String?

    init(_ find: @escaping @Sendable (String) -> String?) {
        self.find = find
    }

    /// `PATH`, then Homebrew's and the system's folders.
    static let system = ExecutableLookup { name in
        locate(name, path: ProcessInfo.processInfo.environment["PATH"] ?? "")
    }

    func callAsFunction(_ name: String) -> String? { find(name) }

    static func locate(_ name: String, path: String) -> String? {
        let folders = path.split(separator: ":").map(String.init) + fallbackFolders
        for folder in folders where folder.hasPrefix("/") {
            let candidate = (folder as NSString).appendingPathComponent(name)
            var info = stat()
            guard stat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, (info.st_mode & 0o111) != 0 else {
                continue
            }
            return candidate
        }
        return nil
    }
}

/// Runs blocking work off Swift's cooperative thread pool.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}
