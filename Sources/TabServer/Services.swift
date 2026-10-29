import Foundation
import TabProtocol

// Contracts between the server core (catalog, sessions, connections) and the
// services it dispatches to (Git, files, search, agent detection, mobile
// access). The core implements the first group; the services implement the
// second. Extend these; don't change existing signatures without updating
// every implementation.

// MARK: - Provided by the server core

/// Resolves projects for services that run Git and file operations.
public protocol ProjectLocator: AnyObject, Sendable {
    /// The project's folder. Throws `ErrorCode.unknownProject` for unknown ids.
    func projectPath(_ id: ProjectId) throws -> String
    /// This server's Home project.
    var homeProject: ProjectId { get }
}

/// Where services report events the connection layer forwards to clients.
public protocol ServiceEvents: AnyObject, Sendable {
    /// Broadcast an event to every connected client (for example
    /// `.gitChanged(project:)` or `.filesChanged(project:changes:)`).
    func broadcast(_ event: EventBody)
    /// Send an event only to the client that asked for a watch.
    func send(_ event: EventBody, to client: ClientId)
}

/// Lets the mobile listener hand accepted connections to the server core.
public protocol ConnectionAcceptor: AnyObject, Sendable {
    /// Serve a client over `stream`. `origin` restricts what phones may do.
    func accept(stream: ByteStream, origin: ConnectionOrigin)
}

public enum ConnectionOrigin: Sendable, Equatable {
    /// The local Unix socket or `tab stdio` over SSH: full access.
    case local
    /// A paired phone: no server management, no exec, no remote-access changes.
    case mobile(DeviceId)
}

/// The catalog operations Git worktree actions need. The core implements it
/// next to `ProjectLocator`.
public protocol WorktreeCatalog: ProjectLocator {
    /// The project's descriptor. Throws `ErrorCode.unknownProject` for unknown ids.
    func project(_ id: ProjectId) throws -> ProjectDescriptor
    /// The worktree projects whose `parentId` is `parent`.
    func children(of parent: ProjectId) -> [ProjectDescriptor]
    /// Adds a worktree project (`kind == .worktree`, `parentId` set) made or
    /// registered by a worktree action, and announces the catalog change.
    func addWorktreeProject(_ project: ProjectDescriptor) throws
    /// Ends `project`'s sessions, and any other session whose folder is
    /// inside `directory`, before the worktree's files are removed.
    func endSessions(project: ProjectId, directory: String) throws
    /// Removes a worktree project after its files were removed, and announces
    /// the catalog change.
    func removeWorktreeProject(_ project: ProjectId) throws
}

// MARK: - Provided by the services

/// Lets the core refuse changes that would race a worktree action in progress.
public protocol WorktreeOperationGuard: AnyObject, Sendable {
    /// Throws while a worktree action involves any of `projects`, so the
    /// catalog doesn't rename, delete or prune them meanwhile.
    func checkMutation(of projects: [ProjectId]) throws
    /// Throws when `directory` is inside a worktree being removed, so no new
    /// session starts there.
    func checkSession(directory: String) throws
}

/// Git operations for a project, run with the `git` and `gh` executables.
public protocol GitServiceProtocol: AnyObject, Sendable {
    /// Handles one request. Throws `ErrorCode` for protocol errors or
    /// `ServiceError` with a message for Git failures.
    func handle(_ request: GitRequest, client: ClientId) async throws -> GitReply
    /// Stops watches held by a client that disconnected.
    func clientDisconnected(_ client: ClientId)
}

/// File operations and search for a project.
public protocol FilesServiceProtocol: AnyObject, Sendable {
    func handle(_ request: FilesRequest, client: ClientId) async throws -> FilesReply
    func clientDisconnected(_ client: ClientId)
}

/// What a session shows, for agent detection.
public struct DetectionInput: Sendable {
    /// The visible screen as text, rows joined by `\n`.
    public var screen: String
    /// The current OSC title.
    public var title: String
    /// The latest OSC 9;4 progress report, `"state;value"`, or empty.
    public var progress: String
    /// The foreground program's name, lowercased, or empty.
    public var program: String

    public init(screen: String, title: String, progress: String, program: String) {
        self.screen = screen
        self.title = title
        self.progress = progress
        self.program = program
    }
}

public struct DetectionResult: Sendable, Equatable {
    public var provider: AgentProvider
    public var state: AgentState
    /// The rule asked to keep the previous state (for example a transcript
    /// viewer is open).
    public var keepsPreviousState: Bool

    public init(provider: AgentProvider, state: AgentState, keepsPreviousState: Bool = false) {
        self.provider = provider
        self.state = state
        self.keepsPreviousState = keepsPreviousState
    }
}

/// Recognizes AI coding agents from a session's program and screen.
public protocol AgentDetectorProtocol: AnyObject, Sendable {
    /// `nil` when no supported agent is recognized.
    func detect(_ input: DetectionInput, previous: DetectionResult?) -> DetectionResult?
}

/// Mobile access: the TLS listener, pairing, and paired devices.
public protocol RemoteAccessProtocol: AnyObject, Sendable {
    func state() -> RemoteAccessState
    func write(_ settings: RemoteAccessSettings) throws
    func startPairing(hosts: [String]) throws -> PairingOffer
    func cancelPairing()
    /// Cancels the code only if it is still the one offered.
    func cancelPairing(code: Data)
    func pair(_ request: PairRequest) throws -> Paired
    func authenticate(_ credential: DeviceCredential) throws -> DeviceId
    func revoke(_ device: DeviceId) throws
    /// Starts the listener when enabled; `acceptor` serves each connection.
    func start(acceptor: ConnectionAcceptor)
    func stop()
}

/// A service failure with a message for the user.
public struct ServiceError: Error, Sendable, CustomStringConvertible {
    public var code: ErrorCode
    public var message: String

    public init(_ code: ErrorCode = .badRequest, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
}
