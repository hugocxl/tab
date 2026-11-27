import Foundation
import XCTest
@testable import TabApp

final class BoundedProcessTests: XCTestCase {
    private func shell(_ script: String, timeout: TimeInterval = 20, limit: Int = 256 * 1024) throws -> BoundedProcess.Output {
        try BoundedProcess.run(program: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
                               directory: NSTemporaryDirectory(), timeout: timeout, limit: limit)
    }

    func testNullByteInvocationsNeverLaunch() {
        XCTAssertThrowsError(try shell("printf 'hidden'\0ignored")) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .io("Process arguments contain a null byte"))
        }
    }

    func testAFinishedProgramIsNotHeldOpenByItsHelpers() throws {
        let started = Date()
        let output = try shell("sleep 30 & echo answer")
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "answer\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testATimeoutStopsTheProgramAndItsHelpers() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("tab-process-\(UUID().uuidString)")
        let started = Date()
        XCTAssertThrowsError(try shell("(sleep 1; touch '\(marker.path)') & sleep 30", timeout: 0.3)) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the helper outlived its program")
    }

    func testOverrunningOutputIsRefused() {
        XCTAssertThrowsError(try shell("yes", limit: 64 * 1024)) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .tooLarge)
        }
    }

    func testAFailingProgramReportsItsErrorOutput() {
        XCTAssertThrowsError(try shell("echo 'not logged in' >&2; exit 3")) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .exited("not logged in"))
        }
        XCTAssertThrowsError(try shell("exit 4")) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .exited("exit status: 4"))
        }
    }
}
