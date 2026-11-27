import Darwin
import Foundation
import TabCore
import TabProtocol

/// Servers on other computers, reached through ssh or a custom command that
/// runs `tab stdio` there.
public enum RemoteServer {
    /// Covers ssh's 10 s connect timeout, logging in, and starting the server.
    public static let readyTimeout: TimeInterval = 20
    /// How long a failed ssh gets to exit and finish its error output.
    static let exitTimeout: TimeInterval = 1

    /// Runs a command through the same transport as the bridge, retaining
    /// typed SSH failures so a refused password can be forgotten.
    public static func run(_ command: String, on target: SSHTarget) async throws -> String {
        let process = try target.process(remote: command)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        return try await blocking {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            if process.terminationStatus == 255 {
                let (reason, detail) = Bridge.explain(Bridge.Exit(status: 255, stderr: text), printed: [])
                throw ClientError.remote(RemoteFailure(reason: reason, destination: target.description, detail: detail))
            }
            guard process.terminationStatus == 0 else {
                throw RemoteInstallError.failed(Bridge.lastLine(Array(data)))
            }
            return text
        }
    }

    /// Connects to the server on `target` through its bridge. ssh prompts only
    /// through the target's askpass program, so logging in otherwise needs
    /// ssh-agent, a key or a certificate, and the host key must be trusted.
    public static func connect(_ target: SSHTarget, start: BridgeStart = .ifNeeded, kind: ClientKind,
                               clientId: ClientId? = nil,
                               readyTimeout: TimeInterval = readyTimeout) async throws -> ServerClient {
        let child = try await blocking { try BridgeProcess(target: target, start: start) }
        let stream: ByteStream
        do {
            stream = try await blocking { try child.waitUntilReady(timeout: readyTimeout) }
        } catch {
            child.terminate()
            throw error
        }
        do {
            let client = try await ServerClient.connect(stream: stream, kind: kind, clientId: clientId)
            client.onClose { _ in child.terminate() }
            return client
        } catch ClientError.versionUnsupported {
            child.terminate()
            throw ClientError.remote(RemoteFailure(reason: .incompatible, destination: target.description,
                                                   detail: "its running server is a different version"))
        } catch {
            child.terminate()
            throw error
        }
    }
}

/// The ssh process that carries a bridge, with its stdin and stdout as the
/// stream and the tail of its error output kept for messages.
final class BridgeProcess: @unchecked Sendable {
    let target: SSHTarget
    private let process: Process
    private let stream: FileDescriptorStream
    private let stderr = ErrorTail()
    private let exited = DispatchSemaphore(value: 0)

    init(target: SSHTarget, start: BridgeStart) throws {
        self.target = target
        do {
            process = try target.process(remote: Bridge.command(start))
        } catch SSHTargetError.missingProgram(let program) {
            throw ClientError.remote(RemoteFailure(reason: .sshMissing, destination: target.description,
                                                   detail: program))
        }
        let input = try Self.pipe()
        let output = try Self.pipe()
        let errors = try Self.pipe()
        process.standardInput = FileHandle(fileDescriptor: input.read, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: output.write, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: errors.write, closeOnDealloc: false)
        let exited = exited
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            for descriptor in [input.read, input.write, output.read, output.write, errors.read, errors.write] {
                close(descriptor)
            }
            throw ClientError.remote(RemoteFailure(reason: .sshMissing, destination: target.description,
                                                   detail: process.executableURL?.path ?? "ssh"))
        }
        close(input.read)
        close(output.write)
        close(errors.write)
        stream = try FileDescriptorStream(readDescriptor: output.read, writeDescriptor: input.write)
        stderr.drain(errors.read)
    }

    /// Reads up to the bridge's ready line, skipping what the remote shell
    /// printed first, then returns the stream with any bytes read past it put
    /// back in front.
    func waitUntilReady(timeout: TimeInterval) throws -> ByteStream {
        let done = DispatchSemaphore(value: 0)
        let timedOut = Flag()
        let stream = stream
        DispatchQueue.global().async {
            if done.wait(timeout: .now() + timeout) == .timedOut {
                timedOut.set()
                stream.close()
            }
        }
        defer { done.signal() }
        var line = Bridge.ReadyLine()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = (try? chunk.withUnsafeMutableBytes { try stream.read(into: $0) }) ?? 0
            if timedOut.isSet {
                throw failure(.timeout, Bridge.lastLine(Array(stderr.wait(timeout: 0).utf8)))
            }
            guard count > 0 else {
                let exit = Bridge.Exit(status: status(), stderr: stderr.wait(timeout: RemoteServer.exitTimeout))
                let (reason, detail) = Bridge.explain(exit, printed: line.seen)
                throw failure(reason, detail)
            }
            switch line.push(chunk[0 ..< count]) {
            case nil:
                continue
            case .success(let rest):
                return PrefixedStream(prefix: Data(rest), base: stream)
            case .failure(let error):
                switch error.reason {
                case .noisy(let printed):
                    throw failure(.unexpectedOutput, Bridge.lastLine(printed))
                case .version(let version):
                    throw failure(.incompatible, "it speaks bridge version \(Bridge.lastLine(version))")
                case .ended(let printed):
                    throw failure(.bridgeFailed, Bridge.lastLine(printed))
                }
            }
        }
    }

    private func status() -> Int32? {
        guard exited.wait(timeout: .now() + RemoteServer.exitTimeout) == .success else { return nil }
        exited.signal()
        return process.terminationReason == .exit ? process.terminationStatus : nil
    }

    private func failure(_ reason: RemoteReason, _ detail: String) -> ClientError {
        .remote(RemoteFailure(reason: reason, destination: target.description, detail: detail))
    }

    func terminate() {
        stream.close()
        if process.isRunning { process.terminate() }
    }

    private static func pipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw ClientError.transport("pipe: \(String(cString: strerror(errno)))")
        }
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        return (descriptors[0], descriptors[1])
    }
}

/// The end of a child's error output. A thread drains it for the child's
/// whole life, so the child never blocks on a full pipe.
final class ErrorTail: @unchecked Sendable {
    static let limit = 8 * 1024
    private let lock = NSCondition()
    private var bytes: [UInt8] = []
    private var ended = false

    func drain(_ descriptor: Int32) {
        let thread = Thread { [self] in
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                lock.lock()
                bytes.append(contentsOf: chunk[0 ..< count])
                if bytes.count > Self.limit { bytes.removeFirst(bytes.count - Self.limit) }
                lock.unlock()
            }
            close(descriptor)
            lock.lock()
            ended = true
            lock.broadcast()
            lock.unlock()
        }
        thread.name = "TabClient.ssh-stderr"
        thread.start()
    }

    /// Waits up to `timeout` for the output to end, then returns its tail.
    func wait(timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while !ended, lock.wait(until: deadline) {}
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A byte stream with bytes already read put back in front.
final class PrefixedStream: ByteStream, @unchecked Sendable {
    private let base: ByteStream
    private let lock = NSLock()
    private var prefix: Data

    init(prefix: Data, base: ByteStream) {
        self.prefix = prefix
        self.base = base
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let taken: Data? = lock.withLock {
            guard !prefix.isEmpty else { return nil }
            let count = min(buffer.count, prefix.count)
            let taken = prefix.prefix(count)
            prefix = Data(prefix.dropFirst(count))
            return taken
        }
        guard let taken else { return try base.read(into: buffer) }
        taken.copyBytes(to: buffer.bindMemory(to: UInt8.self), count: taken.count)
        return taken.count
    }

    func write(_ data: Data) throws { try base.write(data) }
    func close() { base.close() }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

// MARK: - Installing Tab on another computer

/// Installs this release of Tab in `~/.local/bin` on another computer. The
/// installer comes from the GitHub release of the same version, is saved to a
/// temporary file first so a failed download fails the install, and checks
/// the archive against the release's SHA-256 sums before installing.
public enum RemoteInstall {
    public static let releases = "https://github.com/hugocxl/tab/releases/download"

    public static func installerURL(version: String) -> String {
        "\(releases)/v\(version)/install-tab.sh"
    }

    /// The remote command; refuses versions that aren't releases, such as
    /// local builds, which have nothing published to download.
    public static func command(version: String, replace: Bool = false) throws -> String {
        guard ReleaseVersion(version) != nil else { throw RemoteInstallError.notARelease(version) }
        let curl = "curl --fail --silent --show-error --location --proto =https --tlsv1.2"
        let script = [
            "set -eu",
            #"installer=$(mktemp "${TMPDIR:-/tmp}/install-tab.XXXXXX")"#,
            #"trap 'rm -f "$installer"' EXIT"#,
            #"\#(curl) -o "$installer" \#(installerURL(version: version))"#,
            #"sh "$installer" --version \#(version)\#(replace ? " --replace" : "")"#,
        ].joined(separator: "; ")
        return "sh -c '" + script.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// What the user is told before installing.
    public static func description(version: String, destination: String) -> String {
        "Tab \(version) is downloaded from GitHub and installed in ~/.local/bin on \(destination). It needs curl there, and runs on Apple silicon Macs."
    }

    /// Runs the installer through the same ssh login as the bridge and
    /// returns its output.
    @discardableResult
    public static func install(on target: SSHTarget, version: String = Release.version,
                               replace: Bool = false) async throws -> String {
        try await RemoteServer.run(try command(version: version, replace: replace), on: target)
    }
}

public enum RemoteInstallError: Error, Hashable, Sendable, CustomStringConvertible {
    case notARelease(String)
    case failed(String)

    public var description: String {
        switch self {
        case .notARelease(let version):
            "Tab \(version) isn't a published release, so it can't be installed on another computer. Install a release there."
        case .failed(let detail):
            detail.isEmpty ? "Installing Tab failed." : "Installing Tab failed: \(detail)"
        }
    }
}

extension RemoteInstallError: LocalizedError {
    public var errorDescription: String? { description }
}
