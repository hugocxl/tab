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
        XCTAssertEqual(try json(click), ##"{"args":{"selector":"#go","tabId":"T"},"command":"click","type":"browser"}"##)
        XCTAssertEqual(try json(AppReply.ok(.string("tab-1"))), #"{"ok":true,"result":"tab-1"}"#)
        XCTAssertEqual(try json(AppReply.failed("No tab with that ID")), #"{"error":"No tab with that ID","ok":false}"#)
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
        ]
        for value in values {
            XCTAssertEqual(try JSONDecoder().decode(AppRequest.self, from: AppSocket.encode(value)), value)
        }
        let decode = { (text: String) in try JSONDecoder().decode(AppRequest.self, from: Data(text.utf8)) }
        XCTAssertEqual(try decode(#"{"type":"browser","command":"list"}"#), .browser(command: "list", args: [:]))
        XCTAssertEqual(try decode(#"{"type":"focus","window":1}"#), .unknown("focus"))
        let reply = { (text: String) in try JSONDecoder().decode(AppReply.self, from: Data(text.utf8)) }
        XCTAssertEqual(try reply(#"{"ok":true}"#), .ok(.null))
        XCTAssertEqual(try reply(#"{"ok":false}"#), .failed("Tab did not handle the request"))
        XCTAssertEqual(try reply(#"{"ok":true,"result":[{"tabId":"a","active":true}],"extra":1}"#),
                       .ok(.array([.object(["tabId": .string("a"), "active": .bool(true)])])))
    }

    func testTheAppAnswersOverItsSocket() async throws {
        let socket = URL(fileURLWithPath: "/tmp/tab-app-\(UUID().uuidString.prefix(8)).sock")
        XCTAssertThrowsError(try AppSocket.call(socket: socket, .open(path: "/"), timeout: 1)) { error in
            XCTAssertEqual(error as? AppSocketError, .notRunning)
        }
        let server = try AppSocketServer(socket: socket) { request in
            switch request {
            case .open(let path): return .ok(.object(["opened": .string(path)]))
            case .browser(let command, _) where command == "slow":
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return .ok(.null)
            case .browser(let command, let args): return .failed("\(command) \(args["tabId"]?.string ?? "")")
            case .unknown(let type): return .failed(type)
            }
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
