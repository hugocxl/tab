import Foundation
import XCTest
@testable import TabCore

/// A temporary folder removed when the test ends.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("tab-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    @discardableResult
    func write(_ name: String, _ text: String) throws -> URL {
        let file = file(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: file(name), encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
}

func decodeState(_ object: Any) throws -> AppState {
    try AppStateStore.decode(JSONSerialization.data(withJSONObject: object))
}

func assertClose(_ actual: Double, _ expected: Double, accuracy: Double = 1e-5, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, expected, accuracy: accuracy, message, file: file, line: line)
}

extension AppState {
    var activePane: PaneId? { window.activePane }
}

extension AppState {
    /// Opens a terminal and returns the tab holding it.
    @discardableResult
    mutating func openTerminalTab(_ project: ProjectId) throws -> TabId {
        let pane = try openTerminal(project)
        return try XCTUnwrap(self.project(project)?.tabs.first { $0.layout.contains(pane) }?.id)
    }

    /// Answers as `server` would after taking every change waiting for it,
    /// with `change` made on the server meanwhile.
    mutating func confirmTabs(_ server: ServerId = .local, _ change: (inout TabBoard) -> Void = { _ in }) throws {
        let home = try XCTUnwrap(serverHome(server)?.id)
        let state = servers[server] ?? ServerState()
        var board = TabBoard(home: home, projects: state.tabs?.projects ?? [])
        let isProject: (ProjectId) -> Bool = { id in self.project(id)?.serverId == server }
        for legacy in state.legacyTabs {
            try TabReducer.apply(.adoptTabs(project: legacy.project, tabs: legacy.tabs), to: &board, isProject: isProject)
        }
        for intent in state.pendingTabs { try TabReducer.apply(intent.mutation, to: &board, isProject: isProject) }
        change(&board)
        applyTabs(server, TabsSnapshot(revision: (tabsRevision(server) ?? 0) + 1,
                                       applied: state.pendingTabs.map(\.operation), projects: board.projects))
        completeLegacyTabs(server)
    }

    /// Shows `session` in `pane`, as its server does once it starts it.
    mutating func setPaneSession(_ pane: PaneId, _ session: SessionId, proxy: Bool = false) throws {
        let server = try XCTUnwrap(paneServer(pane))
        try confirmTabs(server) { XCTAssertTrue(TabReducer.bind(session, to: pane, proxy: proxy, in: &$0)) }
    }

    /// `state.json` as a build from before servers kept tabs wrote it: each
    /// project with its tabs, titles and zoom.
    func legacyJSON() throws -> [String: Any] {
        var object = try jsonObject(self)
        var projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        for index in projects.indices {
            let id = try XCTUnwrap((projects[index]["id"] as? String).flatMap(ProjectId.init(string:)))
            let tabs = self.project(id)?.tabs ?? []
            var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tabs)) as? [[String: Any]])
            for (t, tab) in tabs.enumerated() {
                if let zoomed = tab.zoomed { encoded[t]["zoomed"] = zoomed.description }
                var panes = try XCTUnwrap(encoded[t]["panes"] as? [[String: Any]])
                for p in panes.indices { panes[p]["title"] = tab.panes[p].title }
                encoded[t]["panes"] = panes
            }
            projects[index]["tabs"] = encoded
        }
        object["projects"] = projects
        object["servers"] = [String: Any]()
        object["paneTitles"] = nil
        var window = try XCTUnwrap(object["window"] as? [String: Any])
        window["zoomed"] = nil
        object["window"] = window
        return object
    }
}
