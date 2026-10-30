import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentComposerContextServiceTests: XCTestCase {
    func testVarAndPrivateVarProjectAliasesDiscoverTheSameSkills() async throws {
        let fixture = try ComposerSkillsFixture()
        defer { fixture.remove() }
        try fixture.write("project/.claude/skills/alias/SKILL.md", "Alias instructions")
        let path = fixture.root.path
        let shortPath: String
        if path.hasPrefix("/private/var/") {
            shortPath = String(path.dropFirst("/private".count))
        } else if path.hasPrefix("/var/") {
            shortPath = path
        } else {
            throw XCTSkip("This regression requires the macOS /var to /private/var alias")
        }
        var replies: [AgentComposerContextReply] = []
        for rootPath in [shortPath, "/private" + shortPath] {
            let root = URL(fileURLWithPath: rootPath)
            let project = root.appendingPathComponent("project")
            let service = AgentComposerContextService(home: root.appendingPathComponent("home")) { _ in project }
            let reply = try await service.handle(.init(project: ProjectId(), provider: .claude))
            XCTAssertEqual(reply.skills.map(\.name), ["alias"])
            XCTAssertEqual(reply.skills.first?.instructions, "Alias instructions")
            XCTAssertFalse(reply.truncated)
            replies.append(reply)
        }
        XCTAssertEqual(replies[0], replies[1], "Both aliases must yield the same canonical skill IDs and paths")
    }

    func testClaudeProjectPrecedenceCommandsAndProviderIsolation() async throws {
        let fixture = try ComposerSkillsFixture()
        defer { fixture.remove() }
        try fixture.write("project/.claude/skills/review/SKILL.md", "---\nname: review\ndescription: 'Project review'\n---\nProject instructions")
        try fixture.write("home/.claude/skills/review/SKILL.md", "---\nname: review\n---\nGlobal instructions")
        try fixture.write("home/.claude/skills/personal/SKILL.md", "Personal instructions")
        try fixture.write("project/.claude/commands/ship.md", "---\ndescription: >\n  Ship the\n  project\n---\nShip instructions")
        try fixture.write("project/.agents/skills/codex-only/SKILL.md", "Codex instructions")
        let reply = try await fixture.service().handle(.init(project: ProjectId(), provider: .claude))
        XCTAssertEqual(Set(reply.skills.map(\.name)), ["review", "personal", "ship"])
        let review = try XCTUnwrap(reply.skills.first { $0.name == "review" })
        XCTAssertEqual(review.description, "Project review")
        XCTAssertTrue(review.instructions.contains("Project instructions"))
        XCTAssertTrue(review.path.rawValue.contains("/project/.claude/"))
        XCTAssertEqual(reply.skills.first { $0.name == "ship" }?.description, "Ship the project")
        XCTAssertFalse(reply.truncated)
        try reply.validate()
    }

    func testCodexProjectAgentsThenGlobalAgentsThenCodex() async throws {
        let fixture = try ComposerSkillsFixture()
        defer { fixture.remove() }
        try fixture.write("project/.agents/skills/shared/SKILL.md", "Project")
        try fixture.write("home/.agents/skills/shared/SKILL.md", "Global agents")
        try fixture.write("home/.codex/skills/shared/SKILL.md", "Global codex")
        try fixture.write("home/.codex/skills/legacy/SKILL.md", "Legacy")
        let reply = try await fixture.service().handle(.init(project: ProjectId(), provider: .codex))
        XCTAssertEqual(Set(reply.skills.map(\.name)), ["shared", "legacy"])
        XCTAssertEqual(reply.skills.first { $0.name == "shared" }?.instructions, "Project")
    }

    func testSymlinkFilesDirectoriesAndRootsAreNotRead() async throws {
        let fixture = try ComposerSkillsFixture()
        defer { fixture.remove() }
        try fixture.write("project/.claude/skills/safe/SKILL.md", "Safe")
        try fixture.write("outside/leak/SKILL.md", "Secret")
        try fixture.link("project/.claude/skills/linked", to: "outside/leak")
        try fixture.link("project/.claude/skills/safe/linked.md", to: "outside/leak/SKILL.md")
        try fixture.link("project/.claude/skills/safe/SKILL2.md", to: "outside/leak/SKILL.md")
        try fixture.link("home/.claude/skills", to: "outside")
        try fixture.link("project/.claude/skills/SKILL.md", to: "outside/leak/SKILL.md")
        let reply = try await fixture.service().handle(.init(project: ProjectId(), provider: .claude))
        XCTAssertEqual(reply.skills.map(\.name), ["safe"])
        XCTAssertFalse(reply.skills.contains { $0.instructions.contains("Secret") })
    }

    func testOversizeFilesAreOmittedWholeAndCatalogIsBounded() async throws {
        let fixture = try ComposerSkillsFixture()
        defer { fixture.remove() }
        let limit = AgentComposerContextReply.maxInstructionBytes
        try fixture.write("project/.agents/skills/oversize/SKILL.md", String(repeating: "x", count: limit + 1))
        for index in 0..<8 {
            try fixture.write("project/.agents/skills/skill-\(index)/SKILL.md", String(repeating: "y", count: limit))
        }
        let reply = try await fixture.service().handle(.init(project: ProjectId(), provider: .codex))
        XCTAssertTrue(reply.truncated)
        XCTAssertEqual(reply.skills.count, 3, "Metadata also consumes the 128 KiB budget")
        XCTAssertTrue(reply.skills.allSatisfy { $0.instructions.utf8.count == limit })
        XCTAssertFalse(reply.skills.contains { $0.name == "oversize" })
        try reply.validate()
    }

    func testHiddenAgentOnlyInvalidNamesAndNonUTF8AreOmitted() async throws {
        let fixture = try ComposerSkillsFixture()
        defer { fixture.remove() }
        try fixture.write("project/.claude/skills/agent/SKILL.md", "---\nuser-invocable: false\n---\nAgent only")
        try fixture.write("project/.claude/skills/invalid/SKILL.md", "---\nname: bad name\n---\nInvalid token")
        try fixture.write("project/.claude/skills/valid/SKILL.md", "Valid")
        let invalid = "project/.claude/skills/binary/SKILL.md"
        try fixture.write(invalid, "placeholder")
        try Data([0xFF, 0xFE]).write(to: fixture.root.appendingPathComponent(invalid))
        let reply = try await fixture.service().handle(.init(project: ProjectId(), provider: .claude))
        XCTAssertEqual(reply.skills.map(\.name), ["valid"])
    }

    func testUnknownProjectDoesNotFallBackToGlobalCatalog() async throws {
        let fixture = try ComposerSkillsFixture()
        defer { fixture.remove() }
        let service = AgentComposerContextService(home: fixture.root.appendingPathComponent("home")) { _ in
            throw ServiceError(.badRequest, "Unknown project")
        }
        do {
            _ = try await service.handle(.init(project: ProjectId(), provider: .claude))
            XCTFail("Unknown project must fail")
        } catch {}
    }

    func testDeepTreesAreBoundedAndCRLFFrontmatterWorks() async throws {
        let fixture = try ComposerSkillsFixture()
        defer { fixture.remove() }
        try fixture.write("project/.agents/skills/short/SKILL.md",
                          "---\r\nname: windows\r\ndescription: Windows lines\r\n---\r\nInstructions")
        let deep = Array(repeating: "nested", count: 10).joined(separator: "/")
        try fixture.write("project/.agents/skills/\(deep)/SKILL.md", "Too deep")
        let reply = try await fixture.service().handle(.init(project: ProjectId(), provider: .codex))
        XCTAssertEqual(reply.skills.map(\.name), ["windows"])
        XCTAssertEqual(reply.skills.first?.description, "Windows lines")
        XCTAssertTrue(reply.truncated)
    }
}

private struct ComposerSkillsFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("composer-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func link(_ path: String, to target: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent(target))
    }

    func service() -> AgentComposerContextService {
        let project = root.appendingPathComponent("project")
        return AgentComposerContextService(home: root.appendingPathComponent("home")) { _ in project }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
