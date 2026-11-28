import Foundation
import TabClient
import TabCore
import TabProtocol

/// `agent`: Tab's own agent panes, read, waited for and messaged.
enum Agents {
    static func run(_ command: CLIAgent, client: ServerClient, json: Bool) async throws {
        switch command {
        case .read(let selector, let all):
            let snapshot = try await read(try await resolve(selector, client: client), client: client, collect: true)
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
        case .list(let children):
            try requireLineage(client)
            var agents = try await conversations(client: client)
            if children {
                guard let me = hostingAgent(server: client.server.server) else {
                    throw CLIError("--children lists the agents a Tab agent pane started; this isn't one")
                }
                agents = agents.filter { $0.parent == me }
            }
            let projects = try await client.catalog().projects
            Output.list(agents.map { listRecord($0, projects: projects) },
                        columns: ["id", "name", "state", "parent", "provider", "project", "title"], json: json)
        case .stop(let selector, let only):
            try requireLineage(client)
            let agent = try await resolve(selector, client: client)
            _ = try await client.agentChat(.stop(session: agent, descendants: !only))
            Output.ok(json: json)
        case .providers:
            let summaries = try await providers(client: client)
            let now = Date()
            if json {
                Output.json(.array(summaries.map { $0.record(now: now) }))
            } else if summaries.isEmpty {
                Output.error("no provider is added yet; the user adds them in Settings › Agents")
            } else {
                Output.list(summaries.map { $0.row(now: now) }, columns: AgentProviderSummary.columns, json: false)
            }
        }
    }

    /// The server's providers with their last checks, usage and models, read side by side.
    /// Usage and models are left out where a server or CLI doesn't give them.
    static func providers(client: ServerClient) async throws -> [AgentProviderSummary] {
        let state = try await client.agentProviders()
        let configs = state.settings.providers
        guard !configs.isEmpty else { return [] }
        async let usage = try? await client.agentUsageLimits(.init()).providers
        let project = try? await Sessions.ownProject(client: client).id
        let models = await withTaskGroup(of: (String, [AgentModelDescriptor]?).self) { group in
            for config in configs where config.enabled && state.status(config) != .error {
                guard let project else { break }
                group.addTask {
                    let reply = try? await client.agentModelCatalog(.init(project: project, provider: config.kind,
                                                                          providerID: config.id))
                    return (config.id, reply?.models)
                }
            }
            var models: [String: [AgentModelDescriptor]] = [:]
            for await (id, list) in group { models[id] = list }
            return models
        }
        let limits = await usage ?? []
        return configs.map { config in
            AgentProviderSummary(config: config, health: state.health(config.id),
                                 usage: AgentProviderSummary.usage(for: config, in: limits, providers: configs),
                                 models: models[config.id])
        }
    }

    /// How long a new agent waits on its provider's usage before starting without it.
    static let usageWait: TimeInterval = 5

    /// Refuses to start an agent on `config` when it is off, missing, signed out or out of
    /// usage for `model`. A signed-out or missing provider is checked again first, as the
    /// user may have just fixed it; usage that is slow to read doesn't hold the agent up.
    static func checkCanStart(_ config: AgentProviderConfig, health: AgentProviderHealth?, model: String?,
                              client: ServerClient) async throws {
        var health = health
        if AgentProviderSummary.refusal(config, health: health, usage: nil, model: model) != nil,
           let checked = try? await client.checkAgentProviders() {
            health = checked.health(config.id)
        }
        if let refusal = AgentProviderSummary.refusal(config, health: health, usage: nil, model: model) {
            throw CLIError(refusal)
        }
        guard AgentUsageLimits.reportingKinds.contains(config.kind) else { return }
        let limits = await withTaskGroup(of: [AgentUsageLimits]?.self) { group in
            group.addTask { try? await client.agentUsageLimits(.init()).providers }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(usageWait * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        let configs = (try? await client.agentProviders())?.settings.providers ?? [config]
        let usage = limits.flatMap { AgentProviderSummary.usage(for: config, in: $0, providers: configs) }
        if let refusal = AgentProviderSummary.refusal(config, health: health, usage: usage, model: model) {
            throw CLIError(refusal)
        }
    }

    /// The provider a new conversation starts with: `name`, an added provider's ID or a kind
    /// whose first added provider it means, else the first one added. A server that predates
    /// provider settings runs `name`'s kind, Claude Code by default. With nothing added, the
    /// pane opens asking for a provider, unless a message has to be sent.
    /// With `sending`, refuses a provider that can't run the message; `model`, when given, is
    /// checked against its usage, as some windows stop one model only.
    static func provider(_ name: String?, sending: Bool, model: String? = nil,
                         client: ServerClient) async throws -> (AgentChatProvider, String?) {
        guard let state = try? await client.agentProviders() else {
            guard let kind = AgentChatProvider(rawValue: name ?? AgentChatProvider.claude.rawValue), kind.hasBuiltIn else {
                throw CLIError("--provider must be one of \(AgentChatProvider.builtIn.map(\.rawValue).joined(separator: ", ")) on this server")
            }
            return (kind, nil)
        }
        let added = state.settings.providers
        let choices = added.filter(\.enabled).map(\.id).joined(separator: ", ")
        // Work sent to a provider that can't run it would only fail in its pane; one opened
        // without a message waits for the user, who can sign it in there.
        func checked(_ provider: AgentProviderConfig) async throws -> (AgentChatProvider, String?) {
            if sending { try await checkCanStart(provider, health: state.health(provider.id), model: model, client: client) }
            return (provider.kind, provider.id)
        }
        guard let name else {
            if let first = added.first(where: \.enabled) { return try await checked(first) }
            guard !sending else {
                throw CLIError(added.isEmpty ? "no provider is added yet; add one in Settings › Agents"
                                             : "every provider is off; turn one on in Settings › Agents")
            }
            return (.claude, nil)
        }
        if let provider = added.first(where: { $0.id == name }) {
            guard provider.enabled else { throw CLIError("\(provider.title) is off; turn it on in Settings › Agents") }
            return try await checked(provider)
        }
        if let kind = AgentChatProvider(rawValue: name) {
            if let provider = added.first(where: { $0.kind == kind && $0.enabled }) { return try await checked(provider) }
            throw CLIError("\(kind.name) isn't added; add it in Settings › Agents" + (choices.isEmpty ? "" : ", or use \(choices)"))
        }
        throw CLIError("no provider \(name)" + (choices.isEmpty ? "; add one in Settings › Agents" : "; use \(choices)"))
    }

    /// Refuses commands a server that predates agent lineage can't run.
    static func requireLineage(_ client: ServerClient) throws {
        guard client.supports(.agentLineage) else {
            throw CLIError("this Tab server predates agent lineage; update Tab")
        }
    }

    /// The agent conversations the server lists, leaving out agents that run in terminals.
    static func conversations(client: ServerClient) async throws -> [AgentActivity] {
        let terminals = Set(try await client.sessions().map(\.id))
        return try await client.activity().agents.filter { !terminals.contains($0.session) }
    }

    static func listRecord(_ agent: AgentActivity, projects: [ProjectDescriptor]) -> JSONValue {
        .object([
            "id": .string(agent.session.description),
            "name": .string(SessionName.of(agent.session)),
            "state": .string(agent.state.rawValue),
            "parent": agent.parent.map { .string($0.description) } ?? .null,
            "provider": .string(agent.provider.rawValue),
            "projectId": .string(agent.project.description),
            "project": .string(projects.first { $0.id == agent.project }?.name ?? agent.project.description),
            "title": agent.title.map(JSONValue.string) ?? .null,
        ])
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

    /// With `collect`, the caller takes in what the agent did, so a report on it still
    /// queued to the caller, its parent, is withdrawn; see `AgentChatRequest.collect`.
    static func read(_ agent: SessionId, client: ServerClient, collect: Bool = false) async throws -> AgentChatSnapshot {
        do {
            let request: AgentChatRequest = collect && client.supports(.agentLineage)
                ? .collect(session: agent) : .read(session: agent)
            return try await client.agentChat(request)
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
                var snapshot = try await read(agent, client: client, collect: true)
                while try settled(snapshot) == nil {
                    guard let event = await events.next() else { throw CLIError("lost the connection to the server") }
                    switch event {
                    case .agentChatChanged(agent, _): snapshot = try await read(agent, client: client, collect: true)
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
            "parent": snapshot.parent.map { .string($0.description) } ?? .null,
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
