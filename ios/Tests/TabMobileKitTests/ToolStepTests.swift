import TabProtocol
import XCTest
@testable import TabMobileKit

final class ToolStepTests: XCTestCase {
    private func item(_ name: String, input: String, running: Bool = false) -> AgentChatItem {
        AgentChatItem(kind: .tool, text: name, isComplete: !running,
                      tool: AgentToolActivity(name: name, category: AgentToolActivity.category(for: name), input: input,
                                              status: running ? .running : .completed))
    }

    /// Agents prefix nearly every command with `cd <project> &&`, which used
    /// to fill the row with the path.
    func testCommandsDropTheLeadingDirectoryChange() {
        XCTAssertEqual(ToolStep.withoutDirectoryChange("cd /Users/me/app && git push origin main"), "git push origin main")
        XCTAssertEqual(ToolStep.withoutDirectoryChange("cd \"/a b/c\"; swift build"), "swift build")
        XCTAssertEqual(ToolStep.withoutDirectoryChange("cd /tmp"), "cd /tmp")
        XCTAssertEqual(ToolStep.withoutDirectoryChange("S=abc; cd /x && scripts/run.sh $S"), "scripts/run.sh $S")
        XCTAssertEqual(ToolStep.withoutDirectoryChange("python3 - <<'EOF'\nprint(1)\nEOF"), "python3 - <<'EOF'")
    }

    func testStepsReadAsASentence() {
        let push = ToolStep(item("Bash", input: #"{"command":"cd /x && git push"}"#, running: true))
        XCTAssertEqual([push.verb, push.subject], ["Running", "git push"])
        XCTAssertEqual(push.command, "cd /x && git push")
        let read = ToolStep(item("Read", input: #"{"file_path":"/Users/me/app/Sources/View.swift"}"#))
        XCTAssertEqual([read.verb, read.subject], ["Read", "View.swift"])
        let web = ToolStep(item("WebFetch", input: #"{"url":"https://www.apple.com/ios/"}"#))
        XCTAssertEqual(web.subject, "apple.com")
    }
}
