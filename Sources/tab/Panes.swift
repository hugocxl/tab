import Foundation
import TabClient
import TabCore
import TabProtocol

/// `pane new` and `tab new`: terminals, agents and browsers shown in the app
/// on this computer.
enum Panes {
    static func run(_ pane: CLIPane, json: Bool) async throws {
        guard !App.overSSH else { throw CLIError("panes open in the app on this Mac, not over SSH") }
        if case .browser(let url, let profile) = pane.content {
            let environment = ProcessInfo.processInfo.environment
            let caller = (environment["TAB_AGENT_ID"] ?? environment["TAB_SESSION_ID"]).flatMap(SessionId.init(string:))
            var invocation = BrowserInvocation.open(url: url, profile: profile, project: pane.project,
                                                    beside: pane.placement == .pane ? caller : nil,
                                                    placement: pane.placement)
            if json { invocation.output = .idJSON }
            return try BrowserCommandRunner.run(invocation)
        }
        let target = Target(host: nil)
        let client = try await target.connect(start: true)
        defer { client.close() }
        let caller = pane.placement == .pane ? caller(server: client.server.server) : nil
        let shown: AppPane
        let record: JSONValue
        switch pane.content {
        case .terminal(let selector?, _, _):
            let session = try await Sessions.calling(selector, client: client)
            guard let info = try await client.sessions().first(where: { $0.id == session }) else {
                throw CLIError("session \(session) isn't running")
            }
            shown = AppPane(kind: .terminal, session: session, project: info.project, beside: caller,
                            placement: pane.placement)
            record = Sessions.record(info)
        case .terminal(nil, let directory, let command):
            let project = try await project(pane, client: client, target: target)
            let session = try await Sessions.start(in: project, directory: directory, command: command, client: client,
                                                   target: target)
            shown = AppPane(kind: .terminal, session: session.id, project: session.project, beside: caller,
                            placement: pane.placement)
            record = Sessions.record(session)
        case .agent(let provider):
            let project = try await project(pane, client: client, target: target).id
            let snapshot = try await client.agentChat(.create(session: SessionId(), project: project, provider: provider))
            shown = AppPane(kind: .agent, session: snapshot.session, project: snapshot.project,
                            provider: snapshot.provider, beside: caller, placement: pane.placement)
            record = agentRecord(snapshot)
        case .fork(let agent):
            guard let source = agent.flatMap(SessionId.init(string:)) ?? Agents.hostingAgent(server: client.server.server)
            else { throw CLIError("give an agent ID; this isn't a Tab agent on that server") }
            let snapshot = try await client.agentChat(.fork(session: SessionId(), from: source))
            shown = AppPane(kind: .agent, session: snapshot.session, project: snapshot.project,
                            provider: snapshot.provider, beside: caller, placement: pane.placement)
            record = agentRecord(snapshot)
        case .browser:
            return
        }
        do {
            _ = try App.call(.show(shown), timeout: try App.replyTime(), startApp: true)
        } catch {
            throw CLIError("started \(shown.session), but could not show it: \(CLI.message(error))")
        }
        Output.record(record, columns: ["id"], json: json)
    }

    /// Where a new terminal or agent belongs: Home for a tab; for a pane, the
    /// project given, else the caller's, else Home.
    static func project(_ pane: CLIPane, client: ServerClient, target: Target) async throws -> ProjectDescriptor {
        guard pane.placement == .pane else { return try Sessions.home(try await client.catalog().projects) }
        return try await Sessions.project(pane.project, client: client, target: target)
    }

    static func agentRecord(_ snapshot: AgentChatSnapshot) -> JSONValue {
        .object([
            "id": .string(snapshot.session.description),
            "projectId": .string(snapshot.project.description),
            "provider": .string(snapshot.provider.rawValue),
        ])
    }

    /// The Tab agent or terminal this command runs in, for a new pane to open beside.
    static func caller(server: ServerId) -> SessionId? {
        Agents.hostingAgent(server: server) ?? Sessions.hostingSession(server: server)
    }
}

/// Tab's own agent panes.
enum Agents {
    /// The Tab agent this command runs in, when it belongs to `server`.
    static func hostingAgent(server: ServerId,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> SessionId? {
        guard let inherited = environment["TAB_SERVER_ID"].flatMap(ServerId.init(string:)), inherited == server else {
            return nil
        }
        return environment["TAB_AGENT_ID"].flatMap(SessionId.init(string:))
    }
}
