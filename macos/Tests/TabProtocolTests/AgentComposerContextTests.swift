import Foundation
import TabProtocol
import XCTest

final class AgentComposerContextTests: XCTestCase {
    func testRequestAndReplyRoundTrip() throws {
        let request = Message.request(RequestId(1), .agentComposerContext(.init(project: ProjectId(), provider: .codex)))
        let context = AgentComposerContextReply(skills: [.init(id: "/project/.agents/skills/review/SKILL.md",
            name: "review", description: "Review code", path: ServerPath("/project/.agents/skills/review/SKILL.md"),
            instructions: "Review the code carefully.")])
        let reply = Message.reply(RequestId(1), .agentComposerContext(context))
        for message in [request, reply] {
            try message.validate()
            XCTAssertEqual(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message)), message)
        }
    }

    func testRejectOversizeInstructionsAndDuplicateIDs() throws {
        let skill = AgentComposerSkill(id: "/skill", name: "review", description: "", path: ServerPath("/skill"),
            instructions: String(repeating: "x", count: AgentComposerContextReply.maxInstructionBytes + 1))
        XCTAssertThrowsError(try AgentComposerContextReply(skills: [skill]).validate())
        var valid = skill
        valid.instructions = "Review"
        XCTAssertThrowsError(try AgentComposerContextReply(skills: [valid, valid]).validate())
    }
}
