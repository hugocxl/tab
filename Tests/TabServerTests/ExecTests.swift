import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class ExecTests: XCTestCase {
    func testAProgramRunsInTheProjectFolder() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let home = try client.home()
        let echo = try client.request(.exec(ExecRequest(job: 1, project: home, argv: ["/bin/echo", "hi"])))
        XCTAssertEqual(echo, .exec(ExecResult(stdout: "hi\n", exitCode: 0)))
        let pwd = try client.request(.exec(ExecRequest(job: 2, project: home, argv: ["/bin/pwd"])))
        guard case .exec(let result) = pwd else { return XCTFail("\(pwd)") }
        XCTAssertTrue(result.stdout.trimmingCharacters(in: .newlines).hasSuffix(server.root.path), result.stdout)
    }

    func testCancellingStopsAProgram() throws {
        let server = try CoreTestServer()
        let client = try server.connect()
        let id = try client.send(.exec(ExecRequest(job: 7, project: try client.home(), argv: ["/bin/sleep", "30"])))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(try client.request(.cancelExec(job: 7)), .execCancelled)
        let reply = try client.reply(to: id, timeout: 5)
        guard case .exec(let result) = reply else { return XCTFail("\(reply)") }
        XCTAssertTrue(result.cancelled)
    }

    func testOutputAndTimeAreBounded() throws {
        let request = ExecRequest(job: 1, project: ProjectId(), shell: "yes | head -c 5000000; sleep 30",
                                  timeoutMs: 1000)
        let started = Date()
        let result = try Exec.run(request, root: "/tmp") { false }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, Limits.maxExecOutput)
    }
}
