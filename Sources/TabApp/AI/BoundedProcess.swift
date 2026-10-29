import Darwin
import Foundation

/// Runs a program in its own process group with stdin closed, collecting
/// its output up to a size limit and within a time limit. The whole group is
/// killed when it ends, is cancelled, or overruns, so helpers it started
/// can't outlive it or hold its output open.
enum BoundedProcess {
    /// How long to keep reading after the program exits while helpers it
    /// left behind still hold the output open.
    static let exitGrace: TimeInterval = 0.25

    struct Output: Equatable {
        var stdout: Data
        var stderr: Data
    }

    enum Failure: Error, Equatable {
        case cancelled
        case timedOut
        case tooLarge
        case exited(String)
        case io(String)

        func describe(provider: String) -> String {
            switch self {
            case .cancelled: return "Cancelled"
            case .timedOut: return "\(provider) did not respond within five minutes"
            case .tooLarge: return "\(provider)'s response exceeded the 256 KB output limit"
            case .exited(let detail): return "\(provider) failed: \(detail)"
            case .io(let error): return error
            }
        }
    }

    private static let groupsLock = NSLock()
    nonisolated(unsafe) private static var groups = Set<pid_t>()

    /// Kills every program still running, such as when the app quits.
    static func terminateAll() {
        let running = groupsLock.withLock { groups }
        for group in running { killpg(group, SIGKILL) }
    }

    /// Blocks until the program is done; call it off the main thread.
    static func run(program: String, arguments: [String], environment: [String: String], directory: String,
                    timeout: TimeInterval, limit: Int, cancellation: AICancellation) throws -> Output {
        guard !cancellation.isCancelled else { throw Failure.cancelled }
        guard !([program, directory] + arguments + environment.flatMap { [$0.key, $0.value] }).contains(where: { $0.contains("\0") }) else {
            throw Failure.io("Process arguments contain a null byte")
        }
        let pid: pid_t
        let pipes: [Int32]
        (pid, pipes) = try spawn(program: program, arguments: arguments, environment: environment, directory: directory)
        groupsLock.withLock { _ = groups.insert(pid) }
        defer {
            killpg(pid, SIGKILL)
            groupsLock.withLock { _ = groups.remove(pid) }
        }
        let collector = Collector(limit: limit)
        let readers = DispatchGroup()
        for (index, descriptor) in pipes.enumerated() {
            readers.enter()
            Thread.detachNewThread {
                collector.drain(descriptor, into: index)
                close(descriptor)
                readers.leave()
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var exitStatus: Int32?
        var exitedAt: TimeInterval?
        var outcome: Result<Int32, Failure>?
        while outcome == nil {
            if cancellation.isCancelled {
                outcome = .failure(.cancelled)
            } else if ProcessInfo.processInfo.systemUptime >= deadline {
                outcome = .failure(.timedOut)
            } else if collector.overflowed {
                outcome = .failure(.tooLarge)
            } else if let error = collector.error {
                outcome = .failure(.io(error))
            } else if let status = exitStatus, let exitedAt {
                if readers.wait(timeout: .now()) == .success || ProcessInfo.processInfo.systemUptime - exitedAt >= exitGrace {
                    outcome = .success(status)
                }
            }
            if outcome != nil { break }
            if exitStatus == nil {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid {
                    exitStatus = status
                    exitedAt = ProcessInfo.processInfo.systemUptime
                    continue
                } else if result < 0 && errno != EINTR {
                    outcome = .failure(.io(String(cString: strerror(errno))))
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        killpg(pid, SIGKILL)
        if exitStatus == nil {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
        _ = readers.wait(timeout: .now() + 1)
        let (stdout, stderr) = collector.output
        switch outcome {
        case .failure(let failure)?:
            throw failure
        case .success(let status)?:
            guard Self.succeeded(status) else {
                let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure.exited(message.isEmpty ? Self.describe(status) : String(message.prefix(1000)))
            }
            return Output(stdout: stdout, stderr: stderr)
        case nil:
            throw Failure.io("The program did not finish")
        }
    }

    private static func succeeded(_ status: Int32) -> Bool {
        status & 0x7f == 0 && (status >> 8) & 0xff == 0
    }

    private static func describe(_ status: Int32) -> String {
        let signal = status & 0x7f
        if signal != 0 { return "terminated by signal \(signal)" }
        return "exit status: \((status >> 8) & 0xff)"
    }

    private static func spawn(program: String, arguments: [String], environment: [String: String],
                              directory: String) throws -> (pid_t, [Int32]) {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0 else { throw Failure.io(String(cString: strerror(errno))) }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            throw Failure.io(String(cString: strerror(errno)))
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
        for descriptor in stdoutPipe + stderrPipe {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        var signals = sigset_t()
        sigemptyset(&signals)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([program] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, program, &actions, &attributes, argv, envp)
        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard result == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw Failure.io("Could not start \(program): \(String(cString: strerror(result)))")
        }
        return (pid, [stdoutPipe[0], stderrPipe[0]])
    }

    /// The output read so far, shared by the reader threads.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var buffers = [Data(), Data()]
        private var overflow = false
        private var failure: String?

        init(limit: Int) { self.limit = limit }

        var overflowed: Bool { lock.withLock { overflow } }
        var error: String? { lock.withLock { failure } }
        var output: (Data, Data) { lock.withLock { (buffers[0], buffers[1]) } }

        func drain(_ descriptor: Int32, into index: Int) {
            var chunk = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count == 0 { return }
                if count < 0 {
                    if errno == EINTR { continue }
                    let message = String(cString: strerror(errno))
                    lock.withLock { failure = message }
                    return
                }
                let full: Bool = lock.withLock {
                    if buffers[index].count + count > limit {
                        overflow = true
                        return true
                    }
                    buffers[index].append(contentsOf: chunk[..<count])
                    return false
                }
                if full { return }
            }
        }
    }
}
