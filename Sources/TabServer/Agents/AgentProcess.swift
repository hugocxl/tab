import Darwin
import Foundation
import TabProtocol

/// NDJSON transport. Readers drain both pipes independently; stdout EOF precedes exit delivery.
internal final class AgentProcess: @unchecked Sendable {
    struct Launch: Sendable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var stopped = false
    private let lock = NSLock()

    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        var paths = [environment["PATH"] ?? "", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                     "\(home)/.cargo/bin", "\(home)/.volta/bin", "\(home)/.bun/bin",
                     "\(home)/.asdf/shims", "\(home)/.local/share/mise/shims", "\(home)/.yarn/bin",
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        // GUI-launched servers often lack the Node version manager's shell PATH.
        for (root, suffix) in [("\(home)/.nvm/versions/node", "bin"),
                               ("\(home)/.local/share/fnm/node-versions", "installation/bin")] {
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(root)/\($0)/\(suffix)" }
        }
        environment["PATH"] = paths.filter { !$0.isEmpty }.joined(separator: ":")
        return environment
    }

    static func resolve(_ name: String, environment: [String: String]) throws -> URL {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path.path) { return path }
        }
        throw AgentRuntimeError("\(name) CLI was not found. Install \(name == "claude" ? "Claude Code" : "Codex"), sign in with `\(name)`, and ensure it is on PATH (for example ~/.local/bin or /opt/homebrew/bin).")
    }

    init(launch: Launch, directory: String, onLine: @escaping @Sendable (Data) -> Void,
         onExit: @escaping @Sendable (Int32, String) -> Void) throws {
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let descriptor = input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw AgentRuntimeError("Could not configure nonblocking agent input: \(String(cString: strerror(errno)))")
        }
        try process.run()
        // Parent copies must not keep the child's pipe ends alive.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let stderr = AgentProcessStderr()
        let stderrDone = DispatchGroup()
        stderrDone.enter()
        Thread.detachNewThread { [errors] in
            defer { try? errors.fileHandleForReading.close(); stderrDone.leave() }
            while let chunk = Self.readAvailable(errors.fileHandleForReading.fileDescriptor), !chunk.isEmpty {
                stderr.append(chunk)
            }
        }
        Thread.detachNewThread { [output, process] in
            var buffer = Data()
            while let chunk = Self.readAvailable(output.fileHandleForReading.fileDescriptor), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if !line.isEmpty { onLine(line) }
                }
                if buffer.count > 16 * 1_024 * 1_024 {
                    process.terminate()
                    break
                }
            }
            if !buffer.isEmpty { onLine(buffer) }
            try? output.fileHandleForReading.close()
            process.waitUntilExit()
            // Do not wait for descendants that inherited stderr indefinitely.
            _ = stderrDone.wait(timeout: .now() + 0.5)
            onExit(process.terminationStatus, stderr.text)
        }
    }

    private static func readAvailable(_ descriptor: Int32) -> Data? {
        // FileHandle.read(upToCount:) may try to fill the requested count on pipes,
        // starving low-volume interactive responses until another turn writes bytes.
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count >= 0 { return Data(bytes.prefix(count)) }
            if errno != EINTR { return nil }
        }
    }

    func write(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count < Limits.maxFrame else {
            throw AgentRuntimeError("Agent input exceeds the maximum frame size. Remove attachments or use smaller files.")
        }
        data.append(10)
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw AgentRuntimeError("Agent process is closed.") }
        let descriptor = input.fileHandleForWriting.fileDescriptor
        // A CLI can remain alive while no longer reading stdin. Never let its pipe
        // block the runtime queue (and therefore stop/interrupt/timeouts) indefinitely.
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw AgentRuntimeError("Agent stopped reading input; submission timed out. Reopen the Agent Tab to resume.")
                }
                let count = Darwin.write(descriptor, base.advanced(by: offset), min(bytes.count - offset, 16_384))
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw AgentRuntimeError("Could not write agent input: \(String(cString: strerror(errno)))")
                }
                var readiness = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let result = Darwin.poll(&readiness, 1, 50)
                if result < 0, errno != EINTR {
                    throw AgentRuntimeError("Could not wait for agent input: \(String(cString: strerror(errno)))")
                }
                if readiness.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    throw AgentRuntimeError("Agent closed its input pipe.")
                }
            }
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        // Foundation's reader thread always waits/reaps, including escalation.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    deinit { stop() }
}

private final class AgentProcessStderr: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > 8_192 { data = Data(data.suffix(8_192)) }
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
