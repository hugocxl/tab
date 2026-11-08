import AppKit
import TabClient
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

/// What an agent's `tab pane` commands do to the window: they act on the pane
/// they name and no other, and the agent's own pane is never closed.
@MainActor
final class PaneControlTests: XCTestCase {
    private func model(projects: [ProjectDescriptor] = []) async throws -> AppModel {
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(
            server: identity, home: home.id, revision: 1, projects: [home] + projects
        ))
        let model = ModelFixtures.model(try ModelFixtures.profile(), server: server)
        model.start()
        let ready = await ModelFixtures.wait { model.state.serverIdentity(.local) != nil }
        XCTAssertTrue(ready)
        return model
    }

    private func panes(_ reply: AppReply) throws -> [JSONValue] {
        guard case .ok(let value) = reply, case .array(let tabs)? = value["tabs"], tabs.count == 1,
              case .array(let panes)? = tabs[0]["panes"] else { throw ModelError("not one tab: \(reply)") }
        return panes
    }

    func testAnAgentListsPlacesResizesAndClosesThePanesBesideIt() async throws {
        let model = try await model()
        defer { model.connection(.local)?.disconnect() }
        let handler = AppSocketHandler(model: model)
        let project = try XCTUnwrap(model.addProject(try ModelFixtures.folder("app")))
        let agent = try XCTUnwrap(model.newAgent(in: project))
        let session = try XCTUnwrap(model.state.pane(agent)?.content.activitySession)
        func control(_ action: AppPaneControl.Action, pane: String? = nil, other: String? = nil, edge: Direction? = nil,
                     percent: Int? = nil, axis: Axis? = nil) async -> AppReply {
            await handler.handle(.pane(AppPaneControl(action, pane: pane, other: other, edge: edge, percent: percent,
                                                      axis: axis, caller: session)))
        }

        // "Open the page below me", then "and one on the right".
        let below = try model.openBrowserPane(url: "about:blank", profile: nil, project: nil, beside: session,
                                              newTab: false, edge: .down, anchor: nil)
        let right = try model.openBrowserPane(url: "about:blank", profile: nil, project: nil, beside: session,
                                              newTab: false, edge: .right, anchor: "self")
        XCTAssertEqual(model.state.neighbor(of: agent, .down)?.description, below.tabId)
        XCTAssertEqual(model.state.neighbor(of: agent, .right)?.description, right.tabId)
        XCTAssertThrowsError(try model.openBrowserPane(url: nil, profile: nil, project: nil, beside: session,
                                                       newTab: false, edge: nil, anchor: "nowhere"))

        let listed = try panes(await control(.list))
        XCTAssertEqual(listed.map { $0["id"]?.string }, [agent.description, right.tabId, below.tabId])
        XCTAssertEqual(listed.map { $0["kind"]?.string }, ["agent", "browser", "browser"])
        XCTAssertEqual(listed.map { $0["position"]?.string }, ["top left", "top right", "bottom"])
        XCTAssertEqual(listed[0]["flags"]?.string, "self")
        XCTAssertEqual(listed[0]["session"]?.string, session.description)

        // "Put that one below the other page", "make me 70% wide", "swap them back".
        let moved = await control(.move, pane: "right", other: below.tabId, edge: .down)
        XCTAssertEqual(moved, .ok(.bool(true)))
        XCTAssertEqual(model.state.neighbor(of: try XCTUnwrap(PaneId(below.tabId)), .down)?.description, right.tabId)
        let grown = await control(.resize, pane: "self", percent: 70, axis: .vertical)
        XCTAssertEqual(grown, .ok(.bool(true)))
        let resized = try panes(await control(.list))
        XCTAssertEqual(resized.first { $0["id"]?.string == agent.description }?["height"], .int(70))
        let swapped = await control(.swap, pane: below.tabId, other: right.tabId)
        XCTAssertEqual(swapped, .ok(.bool(true)))
        XCTAssertEqual(model.state.neighbor(of: agent, .down)?.description, right.tabId)

        // The agent's own pane stays; the one it names closes, and only that one.
        guard case .failed = await control(.close, pane: "self") else { return XCTFail("closed its own pane") }
        guard case .failed = await control(.move, pane: "self", other: "self", edge: .left) else {
            return XCTFail("moved a pane beside itself")
        }
        let closed = await control(.close, pane: String(below.tabId.prefix(8)))
        XCTAssertEqual(closed, .ok(.bool(true)))
        XCTAssertNil(model.state.pane(try XCTUnwrap(PaneId(below.tabId))))
        XCTAssertNotNil(model.state.pane(agent))
        XCTAssertNotNil(model.state.pane(try XCTUnwrap(PaneId(right.tabId))))
        guard case .failed(let message) = await control(.focus, pane: below.tabId) else { return XCTFail("focused a closed pane") }
        XCTAssertTrue(message.contains("no pane is named"))

        // Outside any pane, the list is the tab on screen and every tab with --all.
        let outside = await handler.handle(.pane(AppPaneControl(.list)))
        XCTAssertEqual(try panes(outside).count, 2)
        guard case .ok(let all) = await handler.handle(.pane(AppPaneControl(.list, all: true))),
              case .array(let tabs)? = all["tabs"] else { return XCTFail("no tabs") }
        XCTAssertEqual(tabs.count, model.state.projects.flatMap(\.tabs).count)
    }
}
