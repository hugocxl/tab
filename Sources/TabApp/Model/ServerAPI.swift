import Foundation
import TabClient
import TabCore
import TabProtocol

/// The server requests the app makes, as `ServerClient` provides them. The
/// model talks to this protocol so tests can stand in a fake server.
public protocol ServerAPI: AnyObject, Sendable {
    /// The server build and identity from the handshake.
    var server: ServerInfo { get }
    /// Control-channel events; finishes after `disconnected`.
    var events: AsyncStream<ClientEvent> { get }
    /// Terminal panes attach through this.
    var terminalBackend: TerminalBackend { get }
    func close()

    func sessions() async throws -> [SessionInfo]
    func createSession(_ session: CreateSession) async throws -> SessionInfo
    func closeSession(_ session: SessionId, operation: OperationId) async throws
    func endSession(_ session: SessionId) async throws
    func cancelCreation(_ operation: OperationId) async throws
    func writeInput(session: SessionId, bytes: Data) async throws
    func syncSessionReferences(owner: OperationId?, revision: UInt64, sessions: [SessionId]) async throws
    func availableProjectSessions(_ project: ProjectId) async throws -> [ProjectSession]

    func catalog() async throws -> CatalogPage
    func mutateProject(_ intent: ProjectIntent) async throws -> UInt64
    func listFolders(_ path: ServerPath) async throws -> [ServerPath]

    func activity() async throws -> ActivitySnapshot
    func acknowledgeActivity(_ events: [UInt64]) async throws
    func claimActivity(_ events: [UInt64]) async throws -> [UInt64]

    func git(_ request: GitRequest) async throws -> GitReply
    func files(_ request: FilesRequest) async throws -> FilesReply

    func serverSettings() async throws -> ServerSettingsDoc
    func writeServerSettings(_ settings: ServerSettingsDoc) async throws
    func stopServer(force: Bool) async throws -> Bool
    func restartServer() async throws
    func remoteAccess() async throws -> RemoteAccessState
    func writeRemoteAccess(_ settings: RemoteAccessSettings) async throws -> RemoteAccessState
    func startPairing(hosts: [String]) async throws -> PairingOffer
    func cancelPairing() async throws -> RemoteAccessState
    func revokeDevice(_ device: DeviceId) async throws -> RemoteAccessState
}

extension ServerClient: ServerAPI {
    public var terminalBackend: TerminalBackend { self }
}

extension ServerAPI {
    /// Every file of `project`, for Go to File and the root search.
    public func searchFiles(_ project: ProjectId, limit: UInt32 = 50_000) async throws -> FileList {
        let reply = try await files(FilesRequest(project: project, action: .searchFiles(limit: limit)))
        guard case .fileList(let list) = reply else { throw ClientError.unexpectedReply("files") }
        return list
    }

    /// Find in Files.
    public func searchContent(_ project: ProjectId, _ query: ContentSearchQuery) async throws -> ContentSearchResult {
        let reply = try await files(FilesRequest(project: project, action: .searchContent(query)))
        guard case .searchResults(let result) = reply else { throw ClientError.unexpectedReply("files") }
        return result
    }

    public func gitSummary(_ project: ProjectId) async throws -> GitSummary? {
        let reply = try await git(GitRequest(project: project, action: .summary))
        guard case .summary(let summary) = reply else { throw ClientError.unexpectedReply("git") }
        return summary
    }

    public func gitBranches(_ project: ProjectId) async throws -> [GitBranch] {
        let reply = try await git(GitRequest(project: project, action: .branches))
        guard case .branches(let branches) = reply else { throw ClientError.unexpectedReply("git") }
        return branches
    }

    public func gitChanges(_ project: ProjectId) async throws -> [GitFile] {
        let reply = try await git(GitRequest(project: project, action: .changes))
        guard case .changes(let files) = reply else { throw ClientError.unexpectedReply("git") }
        return files
    }

    public func pullRequestNumber(_ project: ProjectId) async throws -> UInt64? {
        let reply = try await git(GitRequest(project: project, action: .pullRequest(.number)))
        guard case .pullRequestNumber(let number) = reply else { return nil }
        return number
    }
}

/// A failure the model reports, with its message.
public struct ModelError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension Error {
    /// The error as the app shows it.
    var message: String {
        if let error = self as? ClientError { return error.description }
        return (self as? LocalizedError)?.errorDescription ?? "\(self)"
    }

    /// The error as a client error, for retry decisions.
    var clientError: ClientError {
        if let error = self as? ClientError { return error }
        if self is CancellationError { return .disconnected }
        return .transport(message)
    }
}
