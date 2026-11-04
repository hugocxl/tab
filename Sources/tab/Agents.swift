import Foundation
import TabClient
import TabCore
import TabProtocol

/// `agent`: conversations shown in agent panes of the desktop app.
enum Agents {
    static func run(_ command: CLIAgent, client: ServerClient, target: Target, json: Bool) async throws {
        guard !target.isRemote else { throw CLIError("agents open in the app on this computer; leave out --host") }
        let snapshot: AgentChatSnapshot
        switch command {
        case .new(let selector, let provider):
            let project = if let selector {
                try await Projects.resolve(selector, client: client, target: target).id
            } else {
                try await Sessions.ownProject(client: client).id
            }
            snapshot = try await client.agentChat(.create(session: SessionId(), project: project, provider: provider))
        case .fork(let selector):
            let source = if let selector, let id = SessionId(string: selector) {
                id
            } else if let id = hostingAgent(server: client.server.server) {
                id
            } else {
                throw CLIError("give an agent ID; this isn't a Tab agent on that server")
            }
            snapshot = try await client.agentChat(.fork(session: SessionId(), from: source))
        }
        try Panes.show(AppPane(kind: .agent, session: snapshot.session, project: snapshot.project,
                               provider: snapshot.provider, beside: Panes.caller(server: client.server.server)))
        Output.record(.object([
            "id": .string(snapshot.session.description),
            "projectId": .string(snapshot.project.description),
            "provider": .string(snapshot.provider.rawValue),
        ]), columns: ["id"], json: json)
    }

    /// The Tab agent this command runs in, when it belongs to `server`.
    static func hostingAgent(server: ServerId,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> SessionId? {
        guard let inherited = environment["TAB_SERVER_ID"].flatMap(ServerId.init(string:)), inherited == server else {
            return nil
        }
        return environment["TAB_AGENT_ID"].flatMap(SessionId.init(string:))
    }
}

/// Terminals and agents shown in panes of the desktop app on this computer.
enum Panes {
    /// Shows `pane`, starting the app when it isn't running.
    static func show(_ pane: AppPane) throws {
        guard !App.overSSH else { throw CLIError("panes open in the app on this computer, not over SSH") }
        _ = try App.call(.show(pane), timeout: try App.replyTime(), startApp: true)
    }

    /// The Tab agent or terminal this command runs in, for a new pane to open beside.
    static func caller(server: ServerId) -> SessionId? {
        Agents.hostingAgent(server: server) ?? Sessions.hostingSession(server: server)
    }
}
