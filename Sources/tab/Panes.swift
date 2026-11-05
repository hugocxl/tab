import Foundation
import TabClient
import TabCore
import TabProtocol

/// `pane new` and `tab new`: terminals, agents, browsers, devices, editors
/// and diffs shown in the app on this computer.
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
        if let content = try await content(pane, client: client) {
            let project = try await project(pane, client: client, target: target)
            let request = AppNewPane(content: try file(content, in: project), project: project.id, beside: caller,
                                     placement: pane.placement)
            do {
                _ = try App.call(.add(request), timeout: try App.replyTime(), startApp: true)
            } catch {
                throw CLIError("could not open the pane: \(CLI.message(error))")
            }
            return Output.ok(json: json)
        }
        let shown: AppPane
        let record: JSONValue
        var started: AgentChatSnapshot?
        var message: String?
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
        case .agent(let provider, let text):
            let project = try await project(pane, client: client, target: target).id
            let snapshot = try await client.agentChat(.create(session: SessionId(), project: project, provider: provider))
            shown = AppPane(kind: .agent, session: snapshot.session, project: snapshot.project,
                            provider: snapshot.provider, beside: caller, placement: pane.placement)
            record = agentRecord(snapshot)
            started = snapshot
            message = text
        case .fork(let agent, let selector, let text):
            guard let source = agent.flatMap(SessionId.init(string:)) ?? Agents.hostingAgent(server: client.server.server)
            else { throw CLIError("give an agent ID; this isn't a Tab agent on that server") }
            var project: ProjectId?
            if let selector { project = try await Projects.resolve(selector, client: client, target: target).id }
            let snapshot = try await client.agentChat(.fork(session: SessionId(), from: source, project: project))
            if let project, snapshot.project != project {
                // A server older than forking into another project forked in place.
                _ = try? await client.agentChat(.close(session: snapshot.session))
                throw CLIError("the server can't fork into another project; update Tab")
            }
            shown = AppPane(kind: .agent, session: snapshot.session, project: snapshot.project,
                            provider: snapshot.provider, beside: caller, placement: pane.placement)
            record = agentRecord(snapshot)
            started = snapshot
            message = text
        case .browser, .device, .editor, .diff:
            return
        }
        do {
            _ = try App.call(.show(shown), timeout: try App.replyTime(), startApp: true)
        } catch {
            throw CLIError("started \(shown.session), but could not show it: \(CLI.message(error))")
        }
        if let started, let message {
            do {
                _ = try await client.agentChat(.send(session: started.session, text: message, model: started.model,
                                                     reasoningEffort: started.reasoningEffort))
            } catch {
                throw CLIError("started \(started.session), but could not send it the message: \(CLI.message(error))")
            }
        }
        Output.record(record, columns: ["id"], json: json)
    }

    /// A device, editor or diff pane's content, with its device found on the
    /// server; `nil` for other panes.
    static func content(_ pane: CLIPane, client: ServerClient) async throws -> AppNewPane.Content? {
        switch pane.content {
        case .device(let name):
            let running = try await client.listDevices().filter(\.booted)
            let chosen = name == nil && running.count != 1 ? nil : try await Devices.resolve(name, client: client)
            guard let device = chosen else { return .device(DevicePane()) }
            return .device(device.device.platform == .iOS ? DevicePane(udid: device.device.id, name: device.name)
                                                          : DevicePane(avd: device.device.id, name: device.name))
        case .editor(let path, let line): return .editor(path: path, line: line)
        case .diff(let path, let staged): return .diff(path: path, staged: staged)
        case .terminal, .agent, .fork, .browser: return nil
        }
    }

    /// `content` with its file made absolute, refusing one outside `project`
    /// or, for an editor, one that isn't a file.
    static func file(_ content: AppNewPane.Content, in project: ProjectDescriptor) throws -> AppNewPane.Content {
        let root = project.directory.rawValue
        func inside(_ path: String) throws -> String {
            let absolute = Paths.absolute(path)
            guard absolute.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
                throw CLIError("\(path) isn't in the project \(project.name) (\(root))")
            }
            return absolute
        }
        switch content {
        case .device: return content
        case .editor(let path, let line):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: Paths.absolute(path), isDirectory: &isDirectory),
                  !isDirectory.boolValue else { throw CLIError("\(path) isn't a file") }
            return .editor(path: try inside(path), line: line)
        case .diff(let path, let staged): return .diff(path: try inside(path), staged: staged)
        }
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
