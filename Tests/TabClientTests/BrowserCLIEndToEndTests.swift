import Darwin
import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabClient

/// Runs the actual CLI against an independent JSON-speaking desktop stand-in.
final class BrowserCLIEndToEndTests: XCTestCase {
    private var root: URL!
    private var socket: URL { root.appendingPathComponent("app.sock") }
    private var products: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent() }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/tbr-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private func run(_ arguments: [String], timeout: String? = nil) throws -> Output {
        let process = Process()
        process.executableURL = products.appendingPathComponent("tab")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TAB_DIR"] = root.path
        environment["TAB_CLI_TIMEOUT"] = timeout
        environment["SSH_CONNECTION"] = arguments.first == "browser" ? "test" : nil
        environment["SSH_TTY"] = nil
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
                      stderr: String(decoding: stderr, as: UTF8.self))
    }

    private final class Received: @unchecked Sendable {
        var bytes = Data()
        var error: Error?
    }

    /// Uses raw JSON rather than AppRequest/AppReply so matching client and
    /// server codec mistakes cannot make a wire compatibility test pass.
    private func exchange(_ arguments: [String], reply: String, delay: TimeInterval = 0,
                          timeout: String? = nil, pause: TimeInterval = 0) throws -> (JSONValue, Output) {
        let listener: UnixSocketListener
        do {
            listener = try UnixSocketListener(path: socket.path)
        } catch let error as TransportError {
            if case .system(_, let code) = error, code == EPERM || code == EACCES {
                throw XCTSkip("BrowserCLIEndToEndTests requires unsandboxed Unix sockets: \(error)")
            }
            throw error
        }
        defer { listener.close() }
        let received = Received()
        let done = DispatchSemaphore(value: 0)
        Thread {
            defer { done.signal() }
            do {
                let client = try listener.accept()
                defer { client.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = try bytes.withUnsafeMutableBytes { try client.read(into: $0) }
                    if count == 0 { break }
                    received.bytes.append(contentsOf: bytes[..<count])
                }
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                let response = Data(reply.utf8)
                if pause > 0 {
                    let middle = response.count / 2
                    try? client.write(response.prefix(middle))
                    Thread.sleep(forTimeInterval: pause)
                    try? client.write(response.suffix(from: middle))
                } else {
                    try? client.write(response)
                }
            } catch {
                received.error = error
            }
        }.start()
        let result = try run(arguments, timeout: timeout)
        guard done.wait(timeout: .now() + 5) == .success else {
            listener.close()
            throw CLIError("the CLI did not contact the app: \(result.stderr)")
        }
        if let error = received.error { throw error }
        return (try JSONDecoder().decode(JSONValue.self, from: received.bytes), result)
    }

    private let actions: [(String, String, String)] = [

        ("open", "browser.open", ##"{"split":false}"##),
        ("open a.test --split --project App --worktree fix --profile Work", "browser.open",
         ##"{"url":"a.test","split":true,"project":"App","worktree":"fix","profile":"Work"}"##),
        ("navigate T a.test", "browser.navigate", ##"{"tabId":"T","url":"a.test"}"##),
        ("list", "browser.list", "{}"),
        ("list --project App --worktree fix --json", "browser.list", ##"{"project":"App","worktree":"fix"}"##),
        ("read T", "browser.read", ##"{"tabId":"T"}"##),
        ("close T", "browser.close", ##"{"tabId":"T"}"##),
        ("eval T 1+1", "browser.eval", ##"{"tabId":"T","script":"1+1"}"##),
        ("evaluate T 1+1", "browser.eval", ##"{"tabId":"T","script":"1+1"}"##),
        ("click T #go", "browser.click", ##"{"tabId":"T","selector":"#go"}"##),
        ("type T #q rust", "browser.type", ##"{"tabId":"T","selector":"#q","text":"rust","submit":false}"##),
        ("type T #q rust --submit", "browser.type", ##"{"tabId":"T","selector":"#q","text":"rust","submit":true}"##),
        ("fill T #q rust", "browser.fill", ##"{"tabId":"T","selector":"#q","text":"rust"}"##),
        ("press T Enter", "browser.press", ##"{"tabId":"T","key":"Enter"}"##),
        ("press T Enter #q", "browser.press", ##"{"tabId":"T","key":"Enter","selector":"#q"}"##),
        ("select T #s L", "browser.select", ##"{"tabId":"T","selector":"#s","value":"L"}"##),
        ("hover T #m", "browser.hover", ##"{"tabId":"T","selector":"#m"}"##),
        ("scroll-into-view T #m", "browser.scrollIntoView", ##"{"tabId":"T","selector":"#m"}"##),
        ("check T #ok", "browser.setChecked", ##"{"tabId":"T","selector":"#ok","checked":true}"##),
        ("uncheck T #ok", "browser.setChecked", ##"{"tabId":"T","selector":"#ok","checked":false}"##),
        ("is T visible #ok", "browser.is", ##"{"tabId":"T","property":"visible","selector":"#ok"}"##),
        ("wait T", "browser.wait", ##"{"tabId":"T"}"##),
        ("wait T --selector #a --text Done --url-contains /done --function ready --timeout-ms 250", "browser.wait",
         ##"{"tabId":"T","selector":"#a","text":"Done","urlContains":"/done","function":"ready","timeoutMs":250}"##),
        ("wait-for T #a", "browser.waitFor", ##"{"tabId":"T","selector":"#a"}"##),
        ("wait-for T #a 800", "browser.waitFor", ##"{"tabId":"T","selector":"#a","timeoutMs":800}"##),
        ("wait-for-navigation T", "browser.waitForNavigation", ##"{"tabId":"T"}"##),
        ("wait-for-navigation T 900", "browser.waitForNavigation", ##"{"tabId":"T","timeoutMs":900}"##),
        ("wait-for-navigation T --timeout-ms 700", "browser.waitForNavigation", ##"{"tabId":"T","timeoutMs":700}"##),
        ("get-text T h1", "browser.getText", ##"{"tabId":"T","selector":"h1"}"##),
        ("get-html T", "browser.getHTML", ##"{"tabId":"T"}"##),
        ("get-html T main", "browser.getHTML", ##"{"tabId":"T","selector":"main"}"##),
        ("get-value T #q", "browser.getValue", ##"{"tabId":"T","selector":"#q"}"##),
        ("get-attribute T a href", "browser.getAttribute", ##"{"tabId":"T","selector":"a","attribute":"href"}"##),
        ("get-count T li", "browser.getCount", ##"{"tabId":"T","selector":"li"}"##),
        ("find T role button", "browser.find", ##"{"tabId":"T","kind":"role","value":"button"}"##),
        ("snapshot T", "browser.snapshot", ##"{"tabId":"T"}"##),
        ("snapshot T form", "browser.snapshot", ##"{"tabId":"T","selector":"form"}"##),
        ("reload T", "browser.reload", ##"{"tabId":"T"}"##),
        ("back T", "browser.back", ##"{"tabId":"T"}"##),
        ("forward T", "browser.forward", ##"{"tabId":"T"}"##),
        ("screenshot T", "browser.screenshot", ##"{"tabId":"T"}"##),
        ("storage get T k", "browser.storage.get", ##"{"tabId":"T","key":"k","kind":"local"}"##),
        ("storage set T k v session", "browser.storage.set", ##"{"tabId":"T","key":"k","value":"v","kind":"session"}"##),
        ("storage clear T", "browser.storage.clear", ##"{"tabId":"T","kind":"local"}"##),
        ("cookies get T", "browser.cookies.get", ##"{"tabId":"T"}"##),
        ("cookies get T a.test", "browser.cookies.get", ##"{"tabId":"T","url":"a.test"}"##),
        ("cookies set T id 1 a.test", "browser.cookies.set", ##"{"tabId":"T","name":"id","value":"1","domain":"a.test"}"##),
        ("cookies set T id 1 a.test --path /app --secure --http-only --expires 1767225600", "browser.cookies.set",
         ##"{"tabId":"T","name":"id","value":"1","domain":"a.test","path":"/app","secure":true,"httpOnly":true,"expires":1767225600}"##),
        ("cookies delete T id", "browser.cookies.delete", ##"{"tabId":"T","name":"id"}"##),
        ("cookies delete T id a.test", "browser.cookies.delete", ##"{"tabId":"T","name":"id","domain":"a.test"}"##),
        ("cookies clear T", "browser.cookies.clear", ##"{"tabId":"T"}"##),
    ]

    func testEveryBrowserVerbWireEncodingWithoutASocket() throws {
        for (line, verb, arguments) in actions {
            let invocation = try CLIParser.parse(["browser"] + line.split(separator: " ").map(String.init))
            guard case .browser(let browser) = invocation.command else {
                XCTFail("expected a browser invocation: \(line)")
                continue
            }
            let actual = try JSONDecoder().decode(JSONValue.self, from: AppSocket.encode(browser.request))
            XCTAssertEqual(actual, .object(["verb": .string(verb), "args":
                try JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8))]), line)
        }
    }

    func testEveryBrowserVerbEncodesArgumentsAndDecodesItsReply() throws {
        for (line, verb, arguments) in actions {
            let value: String
            let expected: String
            switch verb {
            case "browser.open":
                value = #""tab-1""#
                expected = "tab-1\n"
            case "browser.list":
                value = #"[{"tabId":"t1","title":"Docs\tHome\nPage\r","url":"https://a.test/","profile":null,"active":true}]"#
                expected = line.contains("--json")
                    ? try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)).description + "\n"
                    : "t1\tDocs Home Page \thttps://a.test/\t\ttrue\n"
            case "browser.read":
                value = #"{"title":"Example","url":"https://example.com/","text":"Hello\nworld"}"#
                expected = "Example\nhttps://example.com/\nHello\nworld\n"
            case "browser.navigate", "browser.close":
                value = "null"
                expected = "ok\n"
            case "browser.screenshot":
                value = #"{"png":"iVBORw0KGgo="}"#
                expected = "iVBORw0KGgo=\n"
            case "browser.snapshot":
                value = ##"[{"selector":"#go","role":"button","text":"Go"}]"##
                expected = try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)).description + "\n"
            case "browser.wait", "browser.waitFor", "browser.waitForNavigation":
                value = "false"
                expected = "false\n"
            case "browser.eval", "browser.getText", "browser.getHTML", "browser.getValue", "browser.getAttribute":
                value = #""Text\nwith quotes: \"ok\"""#
                expected = value + "\n"
            case "browser.storage.get":
                value = "null"
                expected = "null\n"
            default:
                value = #"{"nested":[true,null,42,0.5]}"#
                expected = value + "\n"
            }
            let (request, output) = try exchange(["browser"] + line.split(separator: " ").map(String.init),
                                                 reply: "{\"ok\":true,\"value\":\(value)}")
            XCTAssertEqual(request, .object(["verb": .string(verb), "args":
                try JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8))]), line)
            XCTAssertEqual(output.status, 0, line + output.stderr)
            XCTAssertEqual(output.stdout, expected, line)
            XCTAssertEqual(output.stderr, "", line)
        }
    }

    func testErrorsMalformedRepliesAndNotRunningMatchCodesh() throws {
        for (reply, message) in [
            (#"{"ok":false,"error":"browser tab not found missing"}"#, "browser tab not found missing"),
            (#"{"ok":false}"#, "Tab did not handle the request"),
            (#"{"ok":"true","error":7}"#, "Tab did not handle the request"),
            ("[]", "Tab did not handle the request"),
            ("not json", "invalid reply from Tab"),
            ("", "no response from Tab"),
        ] {
            let (_, result) = try exchange(["browser", "click", "missing", "#go"], reply: reply)
            XCTAssertEqual(result.status, 1)
            XCTAssertEqual(result.stdout, "")
            XCTAssertEqual(result.stderr, "tab: \(message)\n")
        }
    }

    func testCLIListRequiresTheDesktopApp() throws {
        let absent = try run(["browser", "list"])
        XCTAssertEqual(absent.status, 1)
        XCTAssertEqual(absent.stdout, "")
        XCTAssertEqual(absent.stderr, "tab: the Tab desktop app is not running\n")
    }

    func testHelpAndArgumentErrors() throws {
        let help = try run(["browser", "--help"])
        XCTAssertEqual(help.status, 0)
        XCTAssertEqual(help.stdout, CLIHelp.browser + "\n")
        XCTAssertEqual(help.stderr, "")
        let rootHelp = try run(["--help"])
        XCTAssertEqual(rootHelp.status, 0)
        XCTAssertEqual(rootHelp.stdout, CLIHelp.root + "\n")
        for (arguments, message) in [
            (["click", "T"], "usage: tab browser click <tab-id> <selector>"),
            (["open", "--project"], "missing value for --project"),
            (["wait", "T", "--timeout-ms", "-5"], "invalid value for --timeout-ms"),
            (["wait", "T", "--text", "a", "--text", "b"], "duplicate option --text"),
            (["type", "T", "#q", "x", "--submit", "--submit"], "duplicate option --submit"),
            (["screenshot", "T", "page.png"], "usage: tab browser screenshot <tab-id>"),
            (["nope"], "unknown browser command; run tab browser --help"),
        ] {
            let result = try run(["browser"] + arguments)
            XCTAssertEqual(result.status, 1)
            XCTAssertEqual(result.stdout, "")
            XCTAssertEqual(result.stderr, "tab: \(message)\n")
        }
        let invalidTimeout = try run(["browser", "list"], timeout: "0")
        XCTAssertEqual(invalidTimeout.status, 1)
        XCTAssertEqual(invalidTimeout.stderr, "tab: TAB_CLI_TIMEOUT must be a whole number of seconds\n")
    }

    func testWaitAddsItsDurationAndTimeoutFailsWithCodeshMessage() throws {
        let (_, waited) = try exchange(["browser", "wait", "T", "--timeout-ms", "2000"],
                                       reply: #"{"ok":true,"value":false}"#, delay: 1.2, timeout: "1")
        XCTAssertEqual(waited.status, 0, waited.stderr)
        XCTAssertEqual(waited.stdout, "false\n")
        let (_, expired) = try exchange(["browser", "wait", "T", "--timeout-ms", "0"],
                                        reply: #"{"ok":true,"value":true}"#, delay: 1.2, timeout: "1")
        XCTAssertEqual(expired.status, 1)
        XCTAssertEqual(expired.stdout, "")
        XCTAssertEqual(expired.stderr, "tab: no response from Tab\n")
    }

    func testEachReplyReadRenewsTheSocketTimeout() throws {
        let (_, result) = try exchange(["browser", "eval", "T", "6*7"],
                                       reply: #"{"ok":true,"value":42}"#, delay: 0.7, timeout: "1", pause: 0.7)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "42\n")
    }

    func testFolderSocketExtensionPreservesCanonicalPathAndRaisesWindow() throws {
        let folder = root.appendingPathComponent("My Project café $(literal)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let (request, output) = try exchange([alias.path], reply: #"{"ok":true,"value":true}"#)
        XCTAssertEqual(request, .object(["type": .string("open"), "path": .string(folder.resolvingSymlinksInPath().path)]))
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertEqual(output.stdout, "")
        let (raise, raised) = try exchangeRequest(.open(path: ""))
        XCTAssertEqual(raise, .object(["type": .string("open"), "path": .string("")]))
        XCTAssertEqual(raised, .bool(true))
    }

    private func exchangeRequest(_ request: AppRequest) throws -> (JSONValue, JSONValue) {
        let listener = try UnixSocketListener(path: socket.path)
        defer { listener.close() }
        let received = Received()
        let done = DispatchSemaphore(value: 0)
        Thread {
            defer { done.signal() }
            do {
                let client = try listener.accept()
                defer { client.close() }
                received.bytes = try AppSocket.readAll(client, limit: AppSocket.maxRequestBytes)
                try client.write(Data(#"{"ok":true,"value":true}"#.utf8))
            } catch { received.error = error }
        }.start()
        let reply = try AppSocket.call(socket: socket, request, timeout: 2)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        if let error = received.error { throw error }
        return (try JSONDecoder().decode(JSONValue.self, from: received.bytes), reply)
    }
}
