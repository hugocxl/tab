import Foundation
import XCTest
@testable import TabApp

final class AIProcessTests: XCTestCase {
    private func shell(_ script: String, timeout: TimeInterval = 20, limit: Int = AIProvider.outputLimit,
                       cancellation: AICancellation = AICancellation()) throws -> BoundedProcess.Output {
        try BoundedProcess.run(program: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
                               directory: NSTemporaryDirectory(), timeout: timeout, limit: limit, cancellation: cancellation)
    }

    func testAFinishedToolIsNotHeldOpenByItsHelpers() throws {
        let started = Date()
        let output = try shell("sleep 30 & echo answer")
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "answer\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCancellationStopsARunningToolAndItsHelpers() throws {
        let cancellation = AICancellation()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("tab-ai-\(UUID().uuidString)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellation.cancel() }
        let started = Date()
        XCTAssertThrowsError(try shell("(sleep 1; touch '\(marker.path)') & sleep 30", cancellation: cancellation)) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the helper outlived its tool")
    }

    func testOverrunningTimeAndOutputAreRefused() {
        XCTAssertThrowsError(try shell("sleep 30", timeout: 0.3)) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .timedOut)
        }
        XCTAssertThrowsError(try shell("yes", limit: 64 * 1024)) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .tooLarge)
        }
    }

    func testAFailingToolReportsItsErrorOutput() {
        XCTAssertThrowsError(try shell("echo 'not logged in' >&2; exit 3")) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .exited("not logged in"))
        }
        XCTAssertThrowsError(try shell("exit 4")) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .exited("exit status: 4"))
        }
    }

    func testProvidersRunInTheProjectWithThePromptAsTheirLastArgument() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-ai-\(UUID().uuidString)")
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nfor last; do :; done\nprintf '%s|%s' \"$(pwd -P)\" \"$last\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let provider = try XCTUnwrap(AIProvider.provider(id: "claude"))
        XCTAssertEqual(AIProvider.installed(search: [bin]), [provider])
        let original = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(bin.path):\(original)", 1)
        defer { setenv("PATH", original, 1) }
        let output = try provider.generate(prompt: "-starts with a dash", in: folder)
        let physical = try XCTUnwrap(realpath(folder.path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) })
        XCTAssertEqual(output, "\(physical)| -starts with a dash")
        XCTAssertThrowsError(try provider.generate(prompt: "x", in: folder.appendingPathComponent("missing"))) { error in
            XCTAssertEqual((error as? AIActionError)?.message, "The project directory isn't available on this Mac")
        }
    }
}
