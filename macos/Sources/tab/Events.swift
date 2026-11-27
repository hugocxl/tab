import Foundation
import TabClient
import TabCore
import TabProtocol

/// `session events`: what happens to sessions, one line each, until interrupted.
enum SessionEvents {
    static func follow(_ only: SessionId?, client: ServerClient, json: Bool) async throws {
        // Reading starts the server's catalog and activity events for this connection.
        _ = try await client.catalog()
        var live = Set(try await client.sessions().map(\.id))
        var activity = try await client.activity()
        var agents = Dictionary(activity.agents.map { ($0.session, $0) }, uniquingKeysWith: { _, new in new })
        var seenEvents = Set(activity.events.map(\.id))
        for await event in client.events {
            switch event {
            case .changed(.sessions, _):
                let now = Set(try await client.sessions().map(\.id))
                for session in now.subtracting(live) { emit("started", session, only, json: json) }
                live = now
            case .sessionEnded(let session, let reason):
                live.remove(session)
                emit("ended", session, only, ["reason": .string(describe(reason))], json: json)
            case .changed(.activity, _):
                activity = try await client.activity()
                for agent in activity.agents where agents[agent.session]?.state != agent.state
                    || agents[agent.session]?.provider != agent.provider {
                    emit("agent", agent.session, only, ["agent": .string(agent.provider.rawValue),
                                                        "state": .string(agent.state.rawValue)], json: json)
                }
                agents = Dictionary(activity.agents.map { ($0.session, $0) }, uniquingKeysWith: { _, new in new })
                for event in activity.events.reversed() where seenEvents.insert(event.id).inserted && !event.read {
                    var fields: [String: JSONValue] = [:]
                    if event.kind != .notification { fields["agent"] = .string(event.provider.rawValue) }
                    if let title = event.title { fields["title"] = .string(title) }
                    if let body = event.body { fields["body"] = .string(body) }
                    emit(event.kind.rawValue, event.session, only, fields, json: json)
                }
            case .disconnected(let error):
                throw error
            case .serverRestarting:
                throw CLIError("the server is restarting")
            default:
                break
            }
        }
    }

    /// One line: JSON, or `type<TAB>session<TAB>name<TAB>detail`.
    private static func emit(_ type: String, _ session: SessionId, _ only: SessionId?, _ fields: [String: JSONValue] = [:],
                             json: Bool) {
        guard only == nil || only == session else { return }
        var object = fields
        object["type"] = .string(type)
        object["session"] = .string(session.description)
        object["name"] = .string(SessionName.of(session))
        if json {
            Output.json(.object(object))
        } else {
            let detail = ["state", "reason", "title", "body"].compactMap { key -> String? in
                if case .string(let text)? = fields[key] { return Output.escape(text) }
                return nil
            }.joined(separator: " ")
            Output.line([type, session.description, SessionName.of(session), detail].joined(separator: "\t"))
        }
    }

    static func describe(_ reason: ExitReason) -> String {
        switch reason {
        case .exited(let code): "exited \(code)"
        case .signaled(let signal): "signaled \(signal)"
        case .serverStopped: "server stopped"
        case .ended, .unknown: "ended"
        }
    }
}

/// `integrations report`: an agent's hook reports its state. It prints nothing and
/// never fails, so an agent never sees an error from Tab.
enum AgentEventReport {
    static let timeout: TimeInterval = 2

    static func send(provider: AgentProvider, state: AgentState?) async {
        let environment = ProcessInfo.processInfo.environment
        guard let session = environment["TAB_SESSION_ID"].flatMap(SessionId.init(string:)),
              let server = environment["TAB_SERVER_ID"].flatMap(ServerId.init(string:)),
              let local = try? LocalServer.profile(),
              let client = try? await local.connect(kind: .cli, start: false, timeout: timeout) else { return }
        defer { client.close() }
        guard client.server.server == server, client.supports(.agentStateReports) else { return }
        _ = try? await client.request(.reportAgentState(AgentStateReport(session: session, provider: provider, state: state)),
                                      timeout: timeout)
    }
}
