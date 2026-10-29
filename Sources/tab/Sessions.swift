import Foundation
import TabClient
import TabCore
import TabProtocol

/// `session`.
enum Sessions {
    static func run(_ command: CLISession, client: ServerClient, target: Target, json: Bool) async throws {
        switch command {
        case .list(let selector, let all):
            let projects = if let selector {
                [try await Projects.resolve(selector, client: client, target: target)]
            } else {
                try await client.catalog().projects
            }
            var records: [JSONValue] = []
            for project in projects {
                for session in try await client.allProjectSessions(project.id) where all || session.status == .live {
                    records.append(record(session))
                }
            }
            Output.list(records, columns: ["id", "projectId", "status", "attached", "directory"], json: json)
        case .create(let selector, let directory, let size, let command):
            try await create(selector, directory: directory, size: size, command: command, client: client,
                             target: target, json: json)
        case .end(let selector):
            try await client.endSession(try await calling(selector, client: client))
            Output.ok(json: json)
        case .discard(let selector):
            try await client.discardSession(try await calling(selector, client: client))
            Output.ok(json: json)
        case .send(let selector, let text):
            try await input(Data(text.utf8), session: try await calling(selector, client: client), client: client)
            Output.ok(json: json)
        case .keys(let selector, let bytes):
            try await input(bytes, session: try await calling(selector, client: client), client: client)
            Output.ok(json: json)
        case .readScreen(let selector, let lines, let saved):
            let session = try await calling(selector, client: client)
            let grid = if saved {
                RunGrid(saved: try await client.readSavedScreen(session))
            } else {
                try await attached(session, client: client) { RunGrid(snapshot: $0.snapshot) }
            }
            let text = grid.screenText(lines: lines)
            if json {
                Output.json(.object([
                    "id": .string(session.description), "text": .string(text), "saved": .bool(saved),
                    "size": try JSONValue(encoding: grid.size), "cursor": try JSONValue(encoding: grid.cursor),
                ]))
            } else {
                Output.line(text)
            }
        case .history(let selector, let before, let limit, let saved):
            let session = try await calling(selector, client: client)
            let cursor = before == 0 ? nil : HistoryCursor(before)
            let page = if saved {
                try await client.savedHistoryPage(session: session, before: cursor, maxRows: limit)
            } else {
                try await attached(session, client: client) {
                    try await client.historyPage(channel: $0.channel, before: cursor, maxRows: limit)
                }
            }
            Output.json(.object([
                "prompts": .array(page.prompts.map { .int(Int64($0)) }),
                "rows": .array(page.rows.map { .string(text($0.runs)) }),
                "next": page.next.map { .string(String($0.rawValue)) } ?? .null,
                "totalRows": .string(String(page.totalRows)),
                "screen": page.screen.map { screen in .array(screen.rows.map { .string(text($0.runs)) }) } ?? .null,
            ]))
        case .search(let selector, let query, let before, let limit, let ignoreCase, let saved):
            let session = try await calling(selector, client: client)
            let cursor = before == 0 ? nil : HistoryCursor(before)
            let page = if saved {
                try await client.searchHistory(.saved(session), query: query, ignoreCase: ignoreCase, before: cursor,
                                               maxResults: limit)
            } else {
                try await attached(session, client: client) {
                    try await client.searchHistory(.live($0.channel), query: query, ignoreCase: ignoreCase,
                                                   before: cursor, maxResults: limit)
                }
            }
            Output.json(.object([
                "matches": .array(page.matches.map { match in
                    .object(["row": .string(String(match.row)), "start": .int(Int64(match.start)),
                             "end": .int(Int64(match.end))])
                }),
                "next": page.next.map { .string(String($0.rawValue)) } ?? .null,
                "totalRows": .string(String(page.totalRows)),
                "scannedRows": .string(String(page.scannedRows)),
            ]))
        case .wait(let selector, let until, let timeoutMs):
            let session = try await calling(selector, client: client)
            let waited = try await wait(session, until: until, timeout: TimeInterval(timeoutMs) / 1000, client: client)
            report(waited, session: session, json: json)
        }
    }

    static func text(_ runs: [Run]) -> String {
        runs.map(\.text).joined()
    }

    static func record(_ session: ProjectSession) -> JSONValue {
        .object([
            "id": .string(session.info.id.description),
            "projectId": .string(session.info.project.description),
            "directory": .string(session.info.directory.rawValue),
            "status": .string(session.status.rawValue),
            "attached": .bool(session.attached),
            "owner": session.owner.map { owner in
                .object(["id": .string(owner.id.description), "kind": .string(owner.kind.rawValue)])
            } ?? .null,
        ])
    }

    /// The session named on the command line, or else the terminal this
    /// command runs in, when that terminal belongs to the server `client` uses.
    static func calling(_ selector: String?, client: ServerClient) async throws -> SessionId {
        if let selector {
            if let id = SessionId(string: selector) { return id }
            let live = try await client.sessions().map(\.id)
            if let id = try? SessionSelector.resolve(selector, among: live) { return id }
            var all: [SessionId] = []
            for project in try await client.catalog().projects {
                all += try await client.allProjectSessions(project.id).map(\.info.id)
            }
            return try SessionSelector.resolve(selector, among: all)
        }
        guard let session = hostingSession(server: client.server.server) else {
            throw CLIError("give a session ID; this isn't a Tab terminal on that server")
        }
        return session
    }

    static func hostingSession(server: ServerId,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> SessionId? {
        guard let inherited = environment["TAB_SERVER_ID"].flatMap(ServerId.init(string:)), inherited == server else {
            return nil
        }
        return environment["TAB_SESSION_ID"].flatMap(SessionId.init(string:))
    }

    /// The project of the terminal this command runs in.
    static func ownProject(client: ServerClient) async throws -> ProjectDescriptor {
        guard let session = hostingSession(server: client.server.server) else {
            throw CLIError("give a project; this isn't a Tab terminal on that server")
        }
        guard let info = try await client.sessions().first(where: { $0.id == session }) else {
            throw CLIError("this terminal's session is no longer running")
        }
        guard let project = try await client.catalog().projects.first(where: { $0.id == info.project }) else {
            throw CLIError("this terminal's project no longer exists")
        }
        return project
    }

    static func create(_ selector: String?, directory: String?, size: Size, command: String?, client: ServerClient,
                       target: Target, json: Bool) async throws {
        let project = if let selector {
            try await Projects.resolve(selector, client: client, target: target)
        } else {
            try await ownProject(client: client)
        }
        let folder = try directory.map(target.directory) ?? project.directory.rawValue
        let typed = command.map { Data(($0 + "\r").utf8) }
        if let typed {
            do {
                try Validation.input(typed)
            } catch {
                throw CLIError("the command is too long")
            }
        }
        let session = try await client.createSession(CreateSession(project: project.id, directory: ServerPath(folder),
                                                                   size: size))
        if let typed {
            do {
                try await client.writeInput(session: session.id, bytes: typed)
            } catch {
                throw CLIError("created session \(session.id), but could not type the command: \(CLI.message(error))")
            }
        }
        Output.record(.object([
            "id": .string(session.id.description),
            "projectId": .string(session.project.description),
            "directory": .string(session.directory.rawValue),
        ]), columns: ["id"], json: json)
    }

    static func input(_ bytes: Data, session: SessionId, client: ServerClient) async throws {
        do {
            try Validation.input(bytes)
        } catch {
            throw CLIError("the input is too long")
        }
        try await client.writeInput(session: session, bytes: bytes)
    }

    /// Runs `action` while attached without resizing, then detaches; a
    /// session that ended meanwhile still counts as a success.
    static func attached<T>(_ session: SessionId, client: ServerClient,
                            _ action: (Attachment) async throws -> T) async throws -> T {
        let attachment = try await client.attachWithoutResize(session: session)
        let result: T
        do {
            result = try await action(attachment)
        } catch {
            try? await client.detach(channel: attachment.channel)
            throw error
        }
        try await client.detach(channel: attachment.channel)
        return result
    }

    enum Waited {
        case line(String)
        case ended(ExitReason)
    }

    /// Follows the session's screen until `until` happens or `timeout` passes.
    static func wait(_ session: SessionId, until: CLIWaitUntil, timeout: TimeInterval,
                     client: ServerClient) async throws -> Waited {
        let attachment: Attachment
        do {
            attachment = try await client.attachWithoutResize(session: session)
        } catch let error as ClientError where error.serverCode == .unknownSession {
            let saved = try await client.readSavedScreen(session)
            switch until {
            case .exit: return .ended(saved.reason ?? .ended)
            case .text(let text, let ignoreCase): return try savedLine(saved, text, ignoreCase)
            }
        }
        let waited: Waited
        do {
            waited = try await withThrowingTaskGroup(of: Waited?.self) { group in
                group.addTask { try await follow(attachment, session: session, until: until, client: client) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let waited = first else {
                    throw CLIError("timed out after \(Int(timeout * 1000))ms")
                }
                return waited
            }
        } catch {
            try? await client.detach(channel: attachment.channel)
            throw error
        }
        try await client.detach(channel: attachment.channel)
        return waited
    }

    private static func follow(_ attachment: Attachment, session: SessionId, until: CLIWaitUntil,
                               client: ServerClient) async throws -> Waited {
        var grid = RunGrid(snapshot: attachment.snapshot)
        if case .text(let text, let ignoreCase) = until, let line = matchingLine(grid, text, ignoreCase) {
            return .line(line)
        }
        for await event in attachment.events {
            switch event {
            case .frame(let frame):
                grid.apply(frame)
                try client.ack(channel: attachment.channel, seq: frame.seq)
                if case .text(let text, let ignoreCase) = until, let line = matchingLine(grid, text, ignoreCase) {
                    return .line(line)
                }
            case .ended(let reason):
                switch until {
                case .exit: return .ended(reason)
                case .text(let text, let ignoreCase):
                    // The last output before an exit may never reach a frame.
                    return try savedLine(try await client.readSavedScreen(session), text, ignoreCase)
                }
            case .metadata, .resized:
                continue
            }
        }
        try Task.checkCancellation()
        throw CLIError("lost the connection to the server")
    }

    static func savedLine(_ saved: SavedScreen, _ text: String, _ ignoreCase: Bool) throws -> Waited {
        guard let line = matchingLine(RunGrid(saved: saved), text, ignoreCase) else {
            throw CLIError("the session ended before the text appeared")
        }
        return .line(line)
    }

    static func matchingLine(_ grid: RunGrid, _ text: String, _ ignoreCase: Bool) -> String? {
        grid.screenText(lines: grid.rows.count).split(separator: "\n", omittingEmptySubsequences: false)
            .first { line in
                ignoreCase ? line.localizedCaseInsensitiveContains(text) : line.contains(text)
            }.map(String.init)
    }

    static func report(_ waited: Waited, session: SessionId, json: Bool) {
        switch waited {
        case .line(let line):
            if json {
                Output.json(.object(["id": .string(session.description), "line": .string(line)]))
            } else {
                Output.line(line)
            }
        case .ended(let reason):
            let text = switch reason {
            case .exited(let code): "exited \(code)"
            case .signaled(let signal): "signaled \(signal)"
            case .serverStopped: "server stopped"
            case .ended, .unknown: "ended"
            }
            if json {
                Output.json(.object(["id": .string(session.description),
                                     "ended": (try? JSONValue(encoding: reason)) ?? .string(text)]))
            } else {
                Output.line(text)
            }
        }
    }
}
