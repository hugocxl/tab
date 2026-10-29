import Foundation
import TabProtocol
import XCTest
@testable import TabTerminal

final class PTYTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var chunks = 0
        let closed = XCTestExpectation(description: "reader closed")

        func append(_ data: Data) {
            lock.lock()
            bytes.append(data)
            chunks += 1
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private func request(_ script: String, environment: [String: String] = [:]) -> SpawnRequest {
        SpawnRequest(
            program: "/bin/sh", arguments: ["-c", script], environment: environment,
            workingDirectory: NSTemporaryDirectory(), size: Size(cols: 80, rows: 24))
    }

    private func start(_ pty: PTY) throws -> Collector {
        let collector = Collector()
        try pty.startReader(output: { collector.append($0) }, closed: { collector.closed.fulfill() })
        return collector
    }

    private func waitFor(_ text: String, in collector: Collector) {
        let deadline = Date().addingTimeInterval(10)
        while !collector.text.contains(text), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testEchoReachesTheReaderAndTheExitIsReported() throws {
        let pty = try PTY(spawning: request("echo hi; exit 3"))
        let output = try start(pty)
        wait(for: [output.closed], timeout: 10)
        XCTAssertTrue(output.text.contains("hi"), output.text)
        XCTAssertEqual(try pty.waitForExit(), .exited(code: 3))
        XCTAssertEqual(pty.exitReason(), .exited(code: 3))
    }

    func testProgramGetsAControllingTerminalEnvironmentAndDirectory() throws {
        let script = ": </dev/tty && echo ctty-ok; echo \"$TAB_TEST\"; pwd -P"
        let pty = try PTY(spawning: request(script, environment: ["TAB_TEST": "value"]))
        let output = try start(pty)
        wait(for: [output.closed], timeout: 10)
        XCTAssertTrue(output.text.contains("ctty-ok"), output.text)
        XCTAssertTrue(output.text.contains("value"), output.text)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        XCTAssertTrue(output.text.contains(directory), output.text)
    }

    func testResizeIsVisibleToTheProgram() throws {
        let pty = try PTY(spawning: request("read line; stty size"))
        let output = try start(pty)
        try pty.resize(Size(cols: 120, rows: 40))
        try pty.write(Data("go\n".utf8))
        wait(for: [output.closed], timeout: 10)
        XCTAssertTrue(output.text.contains("40 120"), output.text)
        XCTAssertEqual(try pty.waitForExit(), .exited(code: 0))
    }

    func testWrittenInputEchoesAndKillEndsTheProgram() throws {
        let pty = try PTY(spawning: SpawnRequest(
            program: "/bin/cat", workingDirectory: NSTemporaryDirectory(), size: Size(cols: 80, rows: 24)))
        let output = try start(pty)
        try pty.write(Data("abc\n".utf8))
        waitFor("abc", in: output)
        XCTAssertTrue(output.text.contains("abc"), output.text)
        XCTAssertNil(pty.exitReason())
        try pty.kill()
        wait(for: [output.closed], timeout: 10)
        XCTAssertEqual(try pty.waitForExit(), .signaled(signal: SIGHUP))
    }

    func testMissingProgramFailsToSpawn() {
        XCTAssertThrowsError(try PTY(spawning: SpawnRequest(
            program: "/nonexistent/program", workingDirectory: "/", size: Size(cols: 80, rows: 24)))) {
            XCTAssertEqual(($0 as? PTYError)?.step, .spawn)
        }
    }
}
