import Foundation

/// Runs a program in a project folder on the server, without a terminal.
/// Exactly one of `argv` (run directly) and `shell` (a command line for the
/// user's shell) is set.
public struct ExecRequest: Hashable, Codable, Sendable {
    /// Client-chosen, non-zero; `cancelExec` names it.
    public var job: UInt64
    public var project: ProjectId
    public var argv: [String]
    public var shell: String?
    /// Defaults to the project folder.
    public var cwd: ServerPath?
    public var env: [String: String]
    public var stdin: Data
    public var timeoutMs: UInt32

    public init(job: UInt64, project: ProjectId, argv: [String] = [], shell: String? = nil, cwd: ServerPath? = nil,
                env: [String: String] = [:], stdin: Data = Data(), timeoutMs: UInt32 = 60_000) {
        self.job = job
        self.project = project
        self.argv = argv
        self.shell = shell
        self.cwd = cwd
        self.env = env
        self.stdin = stdin
        self.timeoutMs = timeoutMs
    }
}

public struct ExecResult: Hashable, Codable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var timedOut: Bool
    /// Output beyond `Limits.maxExecOutput` was dropped.
    public var truncated: Bool
    public var cancelled: Bool

    public init(stdout: String = "", stderr: String = "", exitCode: Int32, timedOut: Bool = false,
                truncated: Bool = false, cancelled: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.truncated = truncated
        self.cancelled = cancelled
    }
}

/// One piece of a file sent to the server's computer, such as an image
/// dropped on a remote terminal, so programs there can open it by path.
/// Chunks arrive in order; the server keeps the file with the session.
public struct UploadChunk: Hashable, Codable, Sendable {
    public var session: SessionId
    /// The same in every chunk of one file.
    public var upload: OperationId
    /// The file's name; the server keeps a safe last component of it.
    public var name: String
    /// Where `bytes` start in the file.
    public var offset: UInt64
    public var bytes: Data
    /// The file is complete after this chunk.
    public var last: Bool

    public init(session: SessionId, upload: OperationId, name: String, offset: UInt64, bytes: Data, last: Bool) {
        self.session = session
        self.upload = upload
        self.name = name
        self.offset = offset
        self.bytes = bytes
        self.last = last
    }
}
