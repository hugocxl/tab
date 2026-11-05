import Foundation
import TabClient
import TabCore
import TabProtocol

/// `agent`: Tab's own agent panes, read, waited for and messaged.
enum Agents {
    static func run(_ command: CLIAgent, client: ServerClient, json: Bool) async throws {
        switch command {
        case .read(let selector, let all):
            let snapshot = try await read(try await resolve(selector, client: client), client: client)
            report(snapshot, all: all, json: json)
        case .wait(let selector, let timeoutMs):
            let agent = try await resolve(selector, client: client)
            let snapshot = try await wait(agent, timeout: TimeInterval(timeoutMs) / 1000, client: client)
            report(snapshot, all: false, json: json)
        case .send(let selector, let text):
            let snapshot = try await read(try await resolve(selector, client: client), client: client)
            _ = try await client.agentChat(.send(session: snapshot.session, text: text, model: snapshot.model,
                                                 reasoningEffort: snapshot.reasoningEffort))
            Output.ok(json: json)
        }
    }

    /// The Tab agent this command runs in, when it belongs to `server`.
    static func hostingAgent(server: ServerId,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> SessionId? {
        guard let inherited = environment["TAB_SERVER_ID"].flatMap(ServerId.init(string:)), inherited == server else {
            return nil
        }
        return environment["TAB_AGENT_ID"].flatMap(SessionId.init(string:))
    }

    /// The agent `selector` names: an ID, or a start or name of one the server knows.
    static func resolve(_ selector: String, client: ServerClient) async throws -> SessionId {
        if let id = SessionId(string: selector) { return id }
        guard SessionSelector.isValid(selector) else {
            throw CLIError("an agent is an ID, a start of one with at least 4 characters, or a name such as wispy-cedar")
        }
        return try SessionSelector.resolve(selector, among: try await client.activity().agents.map(\.session))
    }

    static func read(_ agent: SessionId, client: ServerClient) async throws -> AgentChatSnapshot {
        do {
            return try await client.agentChat(.read(session: agent))
        } catch let error as ClientError where error.serverCode == .unknownSession {
            throw CLIError("no agent \(agent); tab agent takes the ID tab pane new agent prints")
        }
    }

    /// Follows the agent until it is idle, failing when it needs the user,
    /// fails, closes, or `timeout` passes.
    static func wait(_ agent: SessionId, timeout: TimeInterval, client: ServerClient) async throws -> AgentChatSnapshot {
        let finished = try await withThrowingTaskGroup(of: AgentChatSnapshot?.self) { group in
            group.addTask {
                // Read after subscribing, so a change between the two isn't missed.
                var events = client.events.makeAsyncIterator()
                var snapshot = try await read(agent, client: client)
                while try settled(snapshot) == nil {
                    guard let event = await events.next() else { throw CLIError("lost the connection to the server") }
                    switch event {
                    case .agentChatChanged(agent, _): snapshot = try await read(agent, client: client)
                    case .disconnected(let error): throw error
                    case .serverRestarting: throw CLIError("the server is restarting")
                    default: continue
                    }
                }
                return snapshot
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let snapshot = first else {
                throw CLIError("timed out after \(Int(timeout))s; the agent is still working")
            }
            return snapshot
        }
        return finished
    }

    /// `snapshot` when the agent is done, `nil` while it works; throws when
    /// it can't go on by itself.
    private static func settled(_ snapshot: AgentChatSnapshot) throws -> AgentChatSnapshot? {
        switch snapshot.status {
        case .idle: return snapshot
        case .working: return nil
        case .waiting:
            let request = snapshot.items.last { $0.kind == .approval && !$0.isComplete }?.text ?? "a tool"
            throw CLIError("the agent is waiting for the user to approve \(request)")
        case .failed:
            let notice = snapshot.items.last { $0.kind == .notice }?.text ?? "the agent failed"
            throw CLIError(notice)
        case .closed: throw CLIError("the agent was closed")
        }
    }

    /// The last message of the latest reply: what the agent said after the
    /// user's last message, without the progress notes before it.
    static func reply(_ snapshot: AgentChatSnapshot) -> String {
        let lastUser = snapshot.items.lastIndex { $0.kind == .user } ?? -1
        return snapshot.items.indices.reversed().first { index in
            index > lastUser && snapshot.items[index].kind == .assistant
        }.map { snapshot.items[$0].text } ?? ""
    }

    static func report(_ snapshot: AgentChatSnapshot, all: Bool, json: Bool) {
        let messages = snapshot.items.filter { $0.kind == .user || $0.kind == .assistant }
        guard json else {
            guard all else { return Output.line(reply(snapshot)) }
            Output.line(messages.map { "\($0.kind.rawValue):\n\($0.text)" }.joined(separator: "\n\n"))
            return
        }
        var record: [String: JSONValue] = [
            "id": .string(snapshot.session.description),
            "name": .string(SessionName.of(snapshot.session)),
            "projectId": .string(snapshot.project.description),
            "provider": .string(snapshot.provider.rawValue),
            "status": .string(snapshot.status.rawValue),
            "reply": .string(reply(snapshot)),
        ]
        if all {
            record["messages"] = .array(messages.map { message in
                .object(["role": .string(message.kind.rawValue), "text": .string(message.text)])
            })
        }
        Output.json(.object(record))
    }
}
