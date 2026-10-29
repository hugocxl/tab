import Foundation
import TabClient
import TabCore
import TabProtocol

/// `server`, `project`, `session`, `worktree`, `settings`, `activity`, `git`,
/// `files` and `exec`.
enum Manage {
    static func run(_ invocation: ManageInvocation, host: SSHTarget?) async throws {
        let target = Target(host: host)
        let json = invocation.json
        if case .server(let command) = invocation.action, host == nil {
            return try await localServer(command, json: json)
        }
        var start = true
        if case .server(let command) = invocation.action, command != .start { start = false }
        let client = try await target.connect(start: start)
        defer { client.close() }
        try await target.explaining {
            _ = try await client.identify(.cli)
            try await execute(invocation.action, client: client, target: target, json: json)
        }
    }

    /// This computer's server: `status` and `stop` never start it.
    static func localServer(_ command: CLIServer, json: Bool) async throws {
        let server = try LocalServer.profile()
        switch command {
        case .start:
            let client = try await server.connect(kind: .cli)
            defer { client.close() }
            Output.json(serverRecord(client.hello))
        case .status:
            switch await server.status() {
            case .running(let hello): Output.json(serverRecord(hello))
            case .notRunning: throw CLIError("the server isn't running")
            case .incompatible(let versions):
                throw CLIError("the running server speaks protocol \(versions.map(\.description).joined(separator: ", ")), "
                    + "this tab speaks \(ProtocolVersion.supported.map(\.description).joined(separator: ", "))")
            }
        case .stop(let force):
            let client: ServerClient
            do {
                client = try await server.connect(kind: .cli, start: false)
            } catch LocalServerError.notRunning {
                throw CLIError("the server isn't running")
            }
            defer { client.close() }
            try await stop(client, force: force, json: json)
        }
    }

    static func stop(_ client: ServerClient, force: Bool, json: Bool) async throws {
        let stopped = force ? try await client.stopServer(force: true) : try await client.stopServerIfIdle()
        guard stopped else { throw CLIError("server has running terminals; use --force to end them") }
        Output.ok(json: json)
    }

    static func serverRecord(_ hello: HelloReply) -> JSONValue {
        .object([
            "version": .string(hello.server.build.version),
            "protocol": .int(Int64(hello.version.rawValue)),
            "server": .string(hello.server.server.description),
            "instance": .string(String(hello.server.instance)),
            "features": .array(hello.features.map { .string($0.rawValue) }),
        ])
    }

    static func execute(_ action: ManageAction, client: ServerClient, target: Target, json: Bool) async throws {
        switch action {
        case .server(let command):
            switch command {
            case .start, .status: Output.json(serverRecord(client.hello))
            case .stop(let force): try await stop(client, force: force, json: json)
            }
        case .project(let command):
            try await Projects.run(command, client: client, target: target, json: json)
        case .worktree(let command):
            try await Projects.worktree(command, client: client, target: target, json: json)
        case .session(let command):
            try await Sessions.run(command, client: client, target: target, json: json)
        case .settingsGet:
            let settings = try await client.serverSettings()
            Output.json(.object([
                "defaultShell": settings.defaultShell.map { .string($0.rawValue) } ?? .null,
                "historyBudgetBytes": .int(Int64(clamping: settings.historyBudgetBytes)),
                "shellIntegration": .bool(settings.shellIntegration),
            ]))
        case .settingsSet(let key, let value):
            var settings = try await client.serverSettings()
            switch key {
            case "default-shell":
                if value == "default" {
                    settings.defaultShell = nil
                } else {
                    guard value.hasPrefix("/") else { throw CLIError("default-shell must be an absolute path or 'default'") }
                    settings.defaultShell = ServerPath(value)
                }
            case "history-budget-bytes":
                guard let bytes = UInt64(value) else { throw CLIError("history-budget-bytes must be an integer") }
                settings.historyBudgetBytes = bytes
            case "shell-integration":
                guard let enabled = Bool(value) else { throw CLIError("shell-integration must be true or false") }
                settings.shellIntegration = enabled
            default:
                throw CLIError("unknown server setting; run tab settings --help")
            }
            do {
                try settings.validate()
            } catch {
                throw CLIError("invalid setting: \(error.rawValue)")
            }
            try await client.writeServerSettings(settings)
            Output.ok(json: json)
        case .activityList:
            let snapshot = try await client.activity()
            if json {
                try Output.wire(snapshot)
            } else {
                Output.list(activityRows(snapshot), columns: ["session", "project", "provider", "state", "event", "kind"],
                            json: false)
            }
        case .activityAck(let events):
            try await client.acknowledgeActivity(events)
            Output.ok(json: json)
        case .git(let project, let actionJSON):
            let action: GitAction
            do {
                action = try WireJSON.decode(GitAction.self, from: Data(actionJSON.utf8))
            } catch {
                throw CLIError("invalid Git action JSON; run tab git --help")
            }
            if action == .watch || action == .unwatch { throw CLIError("watch requires a persistent client") }
            let id = try await Projects.resolve(project, client: client, target: target).id
            try Output.wire(try await client.git(GitRequest(project: id, action: action)))
        case .files(let project, let actionJSON):
            let action: FilesAction
            do {
                action = try WireJSON.decode(FilesAction.self, from: Data(actionJSON.utf8))
            } catch {
                throw CLIError("invalid files action JSON; run tab files --help")
            }
            if action == .watch || action == .unwatch { throw CLIError("watch requires a persistent client") }
            let id = try await Projects.resolve(project, client: client, target: target).id
            try Output.wire(try await client.files(FilesRequest(project: id, action: action)))
        case .exec(let project, let argv, let timeoutMs):
            let id = try await Projects.resolve(project, client: client, target: target).id
            let result = try await client.exec(ExecRequest(job: 1, project: id, argv: argv, timeoutMs: timeoutMs))
            if json {
                try Output.wire(result)
            } else {
                FileHandle.standardOutput.write(Data(result.stdout.utf8))
                FileHandle.standardError.write(Data(result.stderr.utf8))
            }
            if result.exitCode != 0 || result.timedOut || result.cancelled || result.truncated {
                throw CLIError("exec failed: exit=\(result.exitCode), timedOut=\(result.timedOut), "
                    + "cancelled=\(result.cancelled), truncated=\(result.truncated)")
            }
        }
    }

    /// One row per session with an agent or an unread event: the agent's
    /// state and the session's latest unread event.
    static func activityRows(_ snapshot: ActivitySnapshot) -> [JSONValue] {
        var rows: [[String: JSONValue]] = snapshot.agents.map { agent in
            ["session": .string(agent.session.description), "project": .string(agent.project.description),
             "provider": .string(agent.provider.rawValue), "state": .string(agent.state.rawValue)]
        }
        for event in snapshot.events where !event.read {
            let session = JSONValue.string(event.session.description)
            let index = rows.firstIndex { $0["session"] == session } ?? {
                rows.append(["session": session, "project": .string(event.project.description),
                             "provider": .string(event.provider.rawValue)])
                return rows.count - 1
            }()
            rows[index]["event"] = .string(String(event.id))
            rows[index]["kind"] = .string(event.kind.rawValue)
        }
        return rows.map(JSONValue.object)
    }
}
