import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

final class AgentSessionsTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var homePath: String { home.path }

    @discardableResult
    private func fixture(_ relative: String, _ records: [[String: Any]]) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: url)
        return url
    }

    private func append(_ url: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func line(_ record: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self) + "\n"
    }

    // MARK: Ported from codesh-app-core agent_sessions tests

    func testReadsNativeFormatsAndScopesToTheExactProject() throws {
        let project = home.appendingPathComponent("project").path
        let worktree = (project as NSString).appendingPathComponent("worktree")
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let examples: [(String, [String: Any])] = [
            (".claude/projects/project/claude.jsonl",
             ["type": "user", "sessionId": "claude-1", "cwd": project,
              "message": ["content": [["type": "text", "text": "Fix regression"]]]]),
            (".codex/sessions/2026/01/01/codex.jsonl", ["type": "session_meta", "payload": ["id": "codex-1", "cwd": project]]),
            (".copilot/session-state/copilot-1/events.jsonl",
             ["type": "session.start", "data": ["sessionId": "copilot-1", "context": ["cwd": project]]]),
            (".factory/sessions/project/droid.jsonl",
             ["type": "session_start", "id": "droid-1", "cwd": project, "title": "Fix regression"]),
            (".pi/agent/sessions/project/pi.jsonl", ["type": "session", "id": "pi-1", "cwd": project]),
            (".omp/agent/sessions/project/omp.jsonl", ["type": "session", "id": "omp-1", "cwd": project]),
            (".xal/sessions/project/xal.jsonl", ["type": "meta", "meta": ["id": "xal-1", "cwd": project]]),
        ]
        for (path, record) in examples { try fixture(path, [record]) }
        try fixture(".claude/projects/worktree/child.jsonl", [["type": "user", "sessionId": "worktree-1", "cwd": worktree]])
        try fixture(".claude/projects/project/sidechain.jsonl",
                    [["type": "user", "sessionId": "sidechain-1", "cwd": project, "isSidechain": true]])
        try fixture(".codex/sessions/2026/01/01/child.jsonl",
                    [["type": "session_meta", "payload": ["id": "subagent-1", "cwd": project, "source": ["subagent": [:] as [String: Any]]]]])
        let roots = AgentSessionRoots(home: homePath)
        var catalog = AgentSessionCatalog()
        let listing = catalog.scan(roots, project: project)
        XCTAssertEqual(listing.sessions.count, 7)
        XCTAssertTrue(listing.warnings.isEmpty)
        for provider in AgentSessionProviders.supported {
            XCTAssertTrue(listing.sessions.contains { $0.provider == provider }, "missing \(provider)")
        }
        let worktreeListing = catalog.scan(roots, project: worktree)
        XCTAssertEqual(worktreeListing.sessions.map(\.id), ["worktree-1"])
        let batch = catalog.scan(roots, projects: [project, worktree])
        XCTAssertEqual(batch.sessions.count, 8)
        XCTAssertEqual(batch.sessions.filter { $0.directory == AgentSessionParser.normalized(worktree) }.count, 1)
        XCTAssertEqual(catalog.scan(roots, project: project).sessions.count, 7,
                       "a batched scan must not leak another checkout into the session panel")
    }

    func testRefreshHandlesAppendsPartialRecordsRenamesAndDeletions() throws {
        let url = try fixture(".claude/projects/project/one.jsonl",
                              [["type": "user", "sessionId": "session-1", "cwd": homePath, "message": ["content": "Initial prompt"]]])
        let roots = AgentSessionRoots(home: homePath)
        var catalog = AgentSessionCatalog()
        XCTAssertEqual(catalog.scan(roots, project: homePath).sessions.first?.title, "Initial prompt")
        try append(url, #"{"type":"custom-title","customTitle":"Renamed"}"#)
        XCTAssertEqual(catalog.scan(roots, project: homePath).sessions.first?.title, "Initial prompt", "a partial record is ignored")
        try append(url, "\n")
        let listing = catalog.scan(roots, project: homePath)
        XCTAssertEqual(listing.sessions.first?.title, "Renamed")
        XCTAssertTrue(listing.sessions[0].matches("rename CLAUDE"))
        XCTAssertFalse(listing.sessions[0].matches("missing"))
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(catalog.scan(roots, project: homePath).sessions.isEmpty)
    }

    func testTitlesSurviveTranscriptGrowthOnRefreshAndFreshScans() throws {
        let url = try fixture(".claude/projects/project/one.jsonl", [
            ["type": "user", "sessionId": "session-1", "cwd": homePath, "message": ["content": "Initial prompt"]],
            ["type": "custom-title", "customTitle": "Renamed"],
        ])
        let roots = AgentSessionRoots(home: homePath)
        var catalog = AgentSessionCatalog()
        XCTAssertEqual(catalog.scan(roots, project: homePath).sessions.first?.title, "Renamed")
        let message = try line(["type": "assistant", "message": ["content": String(repeating: "x", count: 1024)]])
        for count in [128, 1024] {
            try append(url, String(repeating: message, count: count))
            var fresh = AgentSessionCatalog()
            for listing in [catalog.scan(roots, project: homePath), fresh.scan(roots, project: homePath)] {
                XCTAssertEqual(listing.sessions.count, 1)
                XCTAssertEqual(listing.sessions.first?.title, "Renamed")
            }
        }
    }

    func testLongMalformedTranscriptsAreBoundedAndAppendedTitlesAreRead() throws {
        let url = try fixture(".xal/sessions/project/one.jsonl", [
            ["type": "meta", "meta": ["id": "session-1", "cwd": homePath]],
            ["type": "item", "item": ["type": "user_message", "text": "Initial"]],
        ])
        try append(url, String(repeating: "x", count: 2 * 1024 * 1024) + "\n")
        try append(url, try line(["type": "event", "event": ["type": "session_title_changed", "title": "Final title"]]))
        var catalog = AgentSessionCatalog()
        let listing = catalog.scan(AgentSessionRoots(home: homePath), project: homePath)
        XCTAssertEqual(listing.sessions.count, 1)
        XCTAssertEqual(listing.sessions.first?.title, "Final title")
    }

    func testResumeCommandsNeverInterpolateTranscriptTextOrPaths() {
        var session = AgentSession(provider: .xal, id: "a123-456", title: "$(touch /tmp/unsafe)", directory: "/project",
                                   path: "/home/'$(unsafe)/session.jsonl", modified: Date(timeIntervalSince1970: 0))
        let commands: [(AgentProvider, String)] = [
            (.claude, "claude --resume"), (.codex, "codex resume"), (.copilot, "copilot --resume"),
            (.droid, "droid --resume"), (.pi, "pi --session"), (.ohMyPi, "omp --resume"), (.xal, "xal resume"),
        ]
        for (provider, command) in commands {
            session.provider = provider
            XCTAssertEqual(session.resumeCommand, "\(command) a123-456")
        }
        session.provider = .cursor
        XCTAssertNil(session.resumeCommand, "unsupported providers have no resume command")
        session.provider = .claude
        for id in ["", "--help", "a;exit", "a\nexit", "$(exit)", "a%PATH%", "a'", "../a", String(repeating: "a", count: 201)] {
            session.id = id
            XCTAssertNil(session.resumeCommand, id)
        }
    }

    func testSymlinkedTranscriptsAreNotFollowedButProjectAliasesMatch() throws {
        let project = home.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let alias = home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        let url = try fixture(".pi/agent/sessions/project/one.jsonl", [["type": "session", "id": "one", "cwd": alias.path]])
        try FileManager.default.createSymbolicLink(at: url.deletingLastPathComponent().appendingPathComponent("link.jsonl"),
                                                   withDestinationURL: url)
        var catalog = AgentSessionCatalog()
        XCTAssertEqual(catalog.scan(AgentSessionRoots(home: homePath), project: project.path).sessions.count, 1)
    }

    func testALargeProviderHistoryDoesNotStarveOtherProvidersOnFirstOpen() throws {
        for index in 0 ..< 70 {
            let url = try fixture(".claude/projects/project/\(index).jsonl",
                                  [["type": "user", "sessionId": "claude-\(index)", "cwd": homePath]])
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 1024 * 1024)
            try handle.close()
        }
        try fixture(".codex/sessions/2026/01/01/codex.jsonl", [["type": "session_meta", "payload": ["id": "codex-1", "cwd": homePath]]])
        try fixture(".xal/sessions/project/xal.jsonl", [["type": "meta", "meta": ["id": "xal-1", "cwd": homePath]]])
        let roots = AgentSessionRoots(home: homePath)
        var catalog = AgentSessionCatalog()
        var listing = catalog.scan(roots, project: homePath)
        for provider in [AgentProvider.claude, .codex, .xal] {
            XCTAssertTrue(listing.sessions.contains { $0.provider == provider }, "missing \(provider) on first scan")
        }
        XCTAssertTrue(listing.pending)
        XCTAssertFalse(listing.limited)
        for _ in 0 ..< 10 where listing.pending {
            let count = listing.sessions.count
            listing = catalog.scan(roots, project: homePath)
            XCTAssertGreaterThan(listing.sessions.count, count, "each batch makes progress")
        }
        XCTAssertFalse(listing.pending)
        XCTAssertEqual(listing.sessions.count, 72)
    }

    func testExhaustedReadBudgetDoesNotReadPastTheLimit() throws {
        let url = try fixture("session.jsonl", [
            ["type": "session", "id": "one", "cwd": homePath],
            ["type": "message", "message": ["role": "user", "content": "Fix regression"]],
        ])
        var budget: UInt64 = 10
        XCTAssertNil(try AgentSessionParser.read(path: url.path, provider: .pi, modified: Date(), budget: &budget))
        XCTAssertEqual(budget, 0)
        budget = 4096
        let session = try AgentSessionParser.read(path: url.path, provider: .pi, modified: Date(), budget: &budget)
        XCTAssertEqual(session?.title, "Fix regression")
        XCTAssertGreaterThan(budget, 0)
    }

    // MARK: Titles per provider

    func testTitlesComeFromEachProvidersRecords() throws {
        let project = homePath
        try fixture(".claude/projects/p/a.jsonl", [
            ["type": "user", "sessionId": "c1", "cwd": project, "isMeta": true, "message": ["content": "meta note"]],
            ["type": "user", "sessionId": "c1", "cwd": project, "message": ["content": "<command-name>/clear</command-name>"]],
            ["type": "user", "sessionId": "c1", "cwd": project, "message": ["content": "Typed\u{7}prompt"]],
        ])
        try fixture(".codex/sessions/2026/02/03/b.jsonl", [
            ["type": "session_meta", "payload": ["id": "x1", "cwd": project]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Codex prompt"]],
        ])
        try fixture(".copilot/session-state/s/events.jsonl", [
            ["type": "session.start", "data": ["sessionId": "p1", "context": ["cwd": project]]],
            ["type": "user.message", "agentId": "sub", "data": ["content": "From a subagent"]],
            ["type": "user.message", "data": ["content": "Copilot prompt"]],
            ["type": "session.title_changed", "data": ["title": "Copilot title"]],
        ])
        try fixture(".omp/agent/sessions/p/d.jsonl", [
            ["type": "session", "id": "o1", "cwd": project],
            ["type": "message", "message": ["role": "user", "content": [["type": "input_text", "text": "OMP prompt"]]]],
        ])
        try fixture(".claude/projects/p/summary.jsonl", [
            ["type": "user", "sessionId": "c2", "cwd": project, "message": ["content": "Prompt"]],
            ["type": "summary", "summary": "Summarized"],
        ])
        try fixture(".pi/agent/sessions/p/relative.jsonl", [["type": "session", "id": "r1", "cwd": "relative/path"]])
        var catalog = AgentSessionCatalog()
        let titles = Dictionary(uniqueKeysWithValues: catalog.scan(AgentSessionRoots(home: homePath), project: project)
            .sessions.map { ($0.id, $0.title) })
        XCTAssertEqual(titles, [
            "c1": "Typed prompt", "x1": "Codex prompt", "p1": "Copilot title", "o1": "OMP prompt", "c2": "Summarized",
        ])
    }

    func testEnvironmentOverridesOnlyAbsoluteFolders() throws {
        let roots = try XCTUnwrap(AgentSessionRoots.fromEnvironment(["HOME": "/Users/me", "CLAUDE_CONFIG_DIR": "/cfg/claude", "CODEX_HOME": "relative"]))
        let byProvider = Dictionary(uniqueKeysWithValues: roots.sources.map { ($0.provider.rawValue, $0.root) })
        XCTAssertEqual(byProvider["claude"], "/cfg/claude/projects")
        XCTAssertEqual(byProvider["codex"], "/Users/me/.codex/sessions")
        XCTAssertEqual(byProvider["copilot"], "/Users/me/.copilot/session-state")
        XCTAssertEqual(byProvider["xal"], "/Users/me/.xal/sessions")
        let codex = try XCTUnwrap(AgentSessionRoots.fromEnvironment(["HOME": "/Users/me", "CODEX_HOME": "/opt/codex"]))
        XCTAssertEqual(codex.sources.first { $0.provider == .codex }?.root, "/opt/codex/sessions")

        try fixture("custom/projects/p/one.jsonl", [["type": "user", "sessionId": "custom-1", "cwd": homePath]])
        let custom = try XCTUnwrap(AgentSessionRoots.fromEnvironment(["HOME": homePath, "CLAUDE_CONFIG_DIR": home.appendingPathComponent("custom").path]))
        var catalog = AgentSessionCatalog()
        XCTAssertEqual(catalog.scan(custom, project: homePath).sessions.map(\.id), ["custom-1"])
    }

    // MARK: List

    private func session(_ provider: AgentProvider, _ id: String, _ title: String, age: TimeInterval, now: Date) -> AgentSession {
        AgentSession(provider: provider, id: id, title: title, directory: "/p", path: "/t/\(id)", modified: now.addingTimeInterval(-age))
    }

    func testListFiltersBySearchAndProvidersWithCountsAndRecencySections() {
        let now = Date()
        let sessions = [
            session(.claude, "a", "Fix login bug", age: 60, now: now),
            session(.codex, "b", "Fix layout", age: 3 * 86_400, now: now),
            session(.claude, "c", "Write docs", age: 30 * 86_400, now: now),
            session(.xal, "d", "Fix tests", age: 40 * 86_400, now: now),
        ]
        var list = AgentSessionList()
        let shown = list.rebuild(sessions, providers: [.claude, .codex], query: "fix", now: now)
        XCTAssertEqual(shown, [0, 1])
        XCTAssertEqual(list.counts, [.claude: 1, .codex: 1, .xal: 1], "counts include unselected providers")
        XCTAssertEqual(list.entries, [
            .section(.recent), .session(index: 0, key: AgentSessionKey(sessions[0])),
            .section(.week), .session(index: 1, key: AgentSessionKey(sessions[1])),
        ])
        XCTAssertEqual(list.selectedIndex, 0)
        XCTAssertEqual(list.advance(backwards: false), 3)
        XCTAssertEqual(list.selectedIndex, 1)
        XCTAssertNil(list.advance(backwards: false), "the last row stays selected")
        XCTAssertEqual(list.advance(backwards: true), 1)

        list.advance(backwards: false)
        list.rebuild(sessions, providers: [.claude, .codex], query: "fix", now: now)
        XCTAssertEqual(list.selectedIndex, 1, "a refresh keeps the selection")
        list.rebuild(sessions, providers: [.claude, .codex, .xal], query: "fix", now: now)
        XCTAssertEqual(list.selectedIndex, 0, "a new filter selects the first row")

        XCTAssertEqual(list.rebuild(sessions, providers: AgentSessionProviders.supported, query: "CODEX", now: now), [1],
                       "provider names are searched")
        XCTAssertEqual(list.rebuild(sessions, providers: [], query: "", now: now), [])
        XCTAssertNil(list.selectedIndex)
    }

    // MARK: Controller

    @MainActor
    func testControllerListsTheProjectsSessionsAndResumesWithTheProvidersCommand() throws {
        let project = home.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try fixture(".claude/projects/p/one.jsonl", [["type": "user", "sessionId": "claude-1", "cwd": project.path, "message": ["content": "Fix it"]]])
        try fixture(".codex/sessions/2026/01/01/two.jsonl", [["type": "session_meta", "payload": ["id": "codex-1", "cwd": homePath]]])
        let host = StubSessionsHost(project: AgentSessionsProject(id: ProjectId(), name: "project", path: project.path, isLocal: true))
        let controller = AgentSessionsController(host: host, roots: AgentSessionRoots(home: homePath))
        _ = controller.view
        controller.projectDidChange()
        let deadline = Date().addingTimeInterval(5)
        while controller.isLoading && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(controller.listing.sessions.map(\.id), ["claude-1"], "only the selected folder's sessions")
        controller.resumeSelected()
        XCTAssertEqual(host.resumed.map(\.0), ["claude --resume claude-1"])
        XCTAssertEqual(host.resumed.map(\.1), ["Fix it"])

        controller.setProviders([.codex])
        XCTAssertEqual(host.appearance.agentSessionsProviders, [.codex])
        XCTAssertEqual(controller.emptyMessage.0, "No matching sessions")

        host.project = AgentSessionsProject(id: ProjectId(), name: "remote", path: "/srv", isLocal: false)
        controller.projectDidChange()
        XCTAssertTrue(controller.listing.sessions.isEmpty, "remote projects never show this Mac's sessions")
        XCTAssertEqual(controller.emptyMessage.0, "Select a local project to browse its saved agent sessions.")
    }
}

@MainActor
final class StubSessionsHost: AgentSessionsHost {
    var theme = AppTheme(systemIsDark: true)
    var appearance = Appearance()
    var project: AgentSessionsProject?
    var resumed: [(String, String)] = []
    var errors: [String] = []

    init(project: AgentSessionsProject?) { self.project = project }

    var agentSessionsProject: AgentSessionsProject? { project }
    func updateAppearance(_ change: (inout Appearance) -> Void) { change(&appearance) }
    func resumeAgentSession(command: String, title: String, in project: ProjectId) { resumed.append((command, title)) }
    func focusActivePane() {}
    func closeAgentSessions() {}
    func agentSessionsLayoutDidChange() {}
    func showError(_ message: String) { errors.append(message) }
}
