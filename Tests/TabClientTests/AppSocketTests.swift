import Darwin
import TabProtocol
import XCTest
@testable import TabClient

final class AppSocketTests: XCTestCase {
    private func json(_ value: some Encodable) throws -> String {
        String(decoding: try AppSocket.encode(value), as: UTF8.self)
    }

    func testRequestAndReplyShapes() throws {
        XCTAssertEqual(try json(AppRequest.open(path: "/Users/me/code/app")),
                       #"{"path":"/Users/me/code/app","type":"open"}"#)
        let click = AppRequest.browser(command: BrowserCommand.click.rawValue,
                                       args: ["tabId": .string("T"), "selector": .string("#go")])
        XCTAssertEqual(try json(click), ##"{"args":{"selector":"#go","tabId":"T"},"verb":"browser.click"}"##)
        XCTAssertEqual(try json(AppReply.ok(.string("tab-1"))), #"{"ok":true,"value":"tab-1"}"#)
        XCTAssertEqual(try json(AppReply.failed("No tab with that ID")), #"{"error":"No tab with that ID","ok":false}"#)
        let evaluate = AppRequest.browser(command: "evaluate", args: ["tabId": .string("T"), "script": .string("1")])
        XCTAssertEqual(try json(evaluate), #"{"args":{"script":"1","tabId":"T"},"verb":"browser.eval"}"#)
        let session = SessionId(), project = ProjectId()
        let show = AppRequest.show(AppPane(kind: .agent, session: session, project: project, provider: .codex))
        XCTAssertEqual(try json(show), #"{"pane":{"kind":"agent","placement":"pane","project":"\#(project)","#
                       + #""provider":"codex","session":"\#(session)"},"type":"show"}"#)
        XCTAssertEqual(try JSONDecoder().decode(AppRequest.self, from: AppSocket.encode(show)), show)
        let older = #"{"pane":{"kind":"terminal","project":"\#(project)","session":"\#(session)"},"type":"show"}"#
        XCTAssertEqual(try JSONDecoder().decode(AppRequest.self, from: Data(older.utf8)),
                       .show(AppPane(kind: .terminal, session: session, project: project)))
        XCTAssertEqual(BrowserCommand.storageGet.rawValue, "storage.get")

        XCTAssertEqual(BrowserCommand.waitForNavigation.rawValue, "waitForNavigation")
    }

    func testShapesRoundTripAndToleratePartialMessages() throws {
        let values: [AppRequest] = [
            .open(path: "/tmp/a b"),
            .browser(command: "cookies.set", args: [
                "tabId": .string("T"), "expires": .int(1_767_225_600), "secure": .bool(true), "ratio": .double(0.5),
                "list": .array([.null, .string("x")]), "nested": .object(["a": .int(-1)]),
            ]),
            .add(AppNewPane(content: .simulator(SimulatorPane(udid: "U", name: "iPhone 17")), project: ProjectId(),
                            beside: SessionId())),
            .add(AppNewPane(content: .editor(path: "/srv/app/a.swift", line: 3), project: ProjectId(), placement: .tab)),
            .add(AppNewPane(content: .diff(path: "README.md", staged: true), project: ProjectId())),
        ]
        for value in values {
            XCTAssertEqual(try JSONDecoder().decode(AppRequest.self, from: AppSocket.encode(value)), value)
        }
        let decode = { (text: String) in try JSONDecoder().decode(AppRequest.self, from: Data(text.utf8)) }
        XCTAssertEqual(try decode(#"{"verb":"browser.list"}"#), .browser(command: "list", args: [:]))
        XCTAssertEqual(try decode(#"{"type":"focus","window":1}"#), .unknown("focus"))
        let reply = { (text: String) in try JSONDecoder().decode(AppReply.self, from: Data(text.utf8)) }
        XCTAssertEqual(try reply(#"{"ok":true}"#), .ok(.null))
        XCTAssertEqual(try reply(#"{"ok":false}"#), .failed("Tab did not handle the request"))
        XCTAssertEqual(try reply(#"{"ok":"true","error":3}"#), .failed("Tab did not handle the request"))
        XCTAssertEqual(try reply("null"), .failed("Tab did not handle the request"))
        XCTAssertEqual(try reply("[]"), .failed("Tab did not handle the request"))
        XCTAssertThrowsError(try decode(#"{"verb":"browser.list","args":null}"#))
        XCTAssertEqual(try reply(#"{"ok":true,"value":[{"tabId":"a","active":true}],"extra":1}"#),
                       .ok(.array([.object(["tabId": .string("a"), "active": .bool(true)])])))
    }

    func testPaneControlAndPlacementShapes() throws {
        let caller = SessionId()
        let move = AppRequest.pane(AppPaneControl(.move, pane: "9a2e", other: "self", edge: .down, caller: caller))
        XCTAssertEqual(try json(move), #"{"control":{"action":"move","caller":"\#(caller)","edge":"down","#
                       + #""other":"self","pane":"9a2e"},"type":"pane"}"#)
        for control in AppPaneControl.Action.allCases.map({ AppPaneControl($0, percent: 40, axis: .vertical, all: true) }) {
            let request = AppRequest.pane(control)
            XCTAssertEqual(try JSONDecoder().decode(AppRequest.self, from: AppSocket.encode(request)), request)
        }
        let decode = { (text: String) in try JSONDecoder().decode(AppRequest.self, from: Data(text.utf8)) }
        // A newer tab's action is unknown to this app, not a broken request.
        XCTAssertEqual(try decode(#"{"type":"pane","control":{"action":"tile"}}"#), .unknown("pane"))
        XCTAssertEqual(try decode(#"{"type":"pane","control":{"action":"list","later":1}}"#),
                       .pane(AppPaneControl(.list)))

        let session = SessionId(), project = ProjectId()
        let placed = AppRequest.show(AppPane(kind: .terminal, session: session, project: project, beside: caller,
                                             edge: .down, anchor: "left"))
        XCTAssertEqual(try JSONDecoder().decode(AppRequest.self, from: AppSocket.encode(placed)), placed)
        let added = AppRequest.add(AppNewPane(content: .diff(path: "a", staged: false), project: project, edge: .up,
                                              anchor: "9a2e"))
        XCTAssertEqual(try JSONDecoder().decode(AppRequest.self, from: AppSocket.encode(added)), added)
        // An older app reads a placed pane as one beside the caller.
        let older = try JSONDecoder().decode(AppNewPane.self, from: Data(
            #"{"content":{"diff":{"path":"a","staged":false}},"project":"\#(project)","placement":"pane"}"#.utf8))
        XCTAssertNil(older.edge)
        XCTAssertNil(older.anchor)
    }

    func testTheAppAnswersOverItsSocket() async throws {
        let socket = URL(fileURLWithPath: "/tmp/tab-app-\(UUID().uuidString.prefix(8)).sock")
        XCTAssertThrowsError(try AppSocket.call(socket: socket, .open(path: "/"), timeout: 1)) { error in
            XCTAssertEqual(error as? AppSocketError, .notRunning)
        }
        let server: AppSocketServer
        do {
            server = try AppSocketServer(socket: socket) { request in
                switch request {
                case .open(let path): return .ok(.object(["opened": .string(path)]))
                case .browser(let command, _) where command == "slow":
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return .ok(.null)
                case .browser(let command, let args): return .failed("\(command) \(args["tabId"]?.string ?? "")")
                case .show(let pane): return .ok(.string(pane.session.description))
                case .add: return .ok(.bool(true))
                case .pane(let control): return .ok(.string(control.action.rawValue))
                case .unknown(let type): return .failed(type)

                }
            }
        } catch let error as TransportError {
            if case .system(_, let code) = error, code == EPERM || code == EACCES {
                throw XCTSkip("AppSocketTests requires unsandboxed Unix sockets: \(error)")
            }
            throw error
        }
        defer { server.close() }
        let opened = try await blocking { try AppSocket.call(socket: socket, .open(path: "/srv/app"), timeout: 5) }
        XCTAssertEqual(opened, .object(["opened": .string("/srv/app")]))
        do {
            _ = try await blocking {
                try AppSocket.call(socket: socket, .browser(command: "close", args: ["tabId": .string("T9")]), timeout: 5)
            }
            XCTFail("an error reply throws")
        } catch let error as AppSocketError {
            XCTAssertEqual(error, .failed("close T9"))
        }
        do {
            _ = try await blocking {
                try AppSocket.call(socket: socket, .browser(command: "slow", args: [:]), timeout: 0.2)
            }
            XCTFail("a slow app times out")
        } catch let error as AppSocketError {
            XCTAssertEqual(error, .noResponse)
        }
    }
}
