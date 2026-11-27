import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentBackgroundShellTests: XCTestCase {
    func testReadsOnlyTheTasksOwnOutputFile() {
        let result = "Command running in background with ID: b2szwct93. Output is being written to: "
            + "/private/tmp/claude-501/p/698f/tasks/b2szwct93.output. You will be notified when it completes."
        XCTAssertEqual(AgentBackgroundShell.outputFile(in: result, task: "b2szwct93")?.path, "/private/tmp/claude-501/p/698f/tasks/b2szwct93.output")
        XCTAssertNil(AgentBackgroundShell.outputFile(in: result, task: "other"))
        XCTAssertNil(AgentBackgroundShell.outputFile(in: "Output is being written to: /etc/passwd", task: "passwd"))
        XCTAssertNil(AgentBackgroundShell.outputFile(in: "Output is being written to: tasks/a.output", task: "a"))
        XCTAssertEqual(AgentBackgroundShell.outputFile(in: "Done\n\nOutput was written to: /t/tasks/a.output", task: "a")?.path, "/t/tasks/a.output")
    }

    func testStepShowsTheEndOfTheOutputFromAWholeLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("tasks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let file = directory.appendingPathComponent("b1.output")
        let lines = (0..<20_000).map { "line \($0)" }.joined(separator: "\n")
        try Data(lines.utf8).write(to: file)
        let item = AgentChatItem(id: "tool", kind: .tool, text: "Bash", tool: AgentToolActivity(name: "Bash",
            output: "Command running in background with ID: b1. Output is being written to: \(file.path)", status: .completed))
        let step = AgentBackgroundShell.step(item, task: AgentSubagent(id: "b1", toolUseID: "tool", description: "Run", agentType: "Shell"))
        let output = try XCTUnwrap(step.tool?.output)
        XCTAssertEqual(step.tool?.status, .running)
        XCTAssertTrue(output.hasPrefix("[Earlier output omitted]\nline "))
        XCTAssertTrue(output.hasSuffix("line 19999"))
        XCTAssertLessThanOrEqual(output.utf8.count, AgentBackgroundShell.tailBytes + 64)
    }
}
