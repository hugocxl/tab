import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentComposerCoordinatorTests: XCTestCase {
    func testMentionSelectionReplacesOnlyTokenAndAttachesThreadContext() async throws {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        let coordinator = AgentComposerCoordinator(surface: surface)
        coordinator.loadFiles = { ["Sources/Reader.swift"] }
        coordinator.loadThreads = { [.init(id: "thread", title: "Reader review", context: "Assistant: relevant earlier answer")] }
        var context = ""
        coordinator.onContext = { _, text in context = text }
        surface.composer.string = "Compare @re with this"
        surface.composer.setSelectedRange(NSRange(location: 11, length: 0))
        coordinator.changed()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(surface.suggestions.items.first?.kind, .thread)
        surface.suggestions.moveSelection(-surface.suggestions.selectedIndex)
        XCTAssertTrue(coordinator.handle(#selector(NSResponder.insertTab(_:))))
        XCTAssertTrue(surface.composer.string.hasPrefix("Compare @\"Reader review\" "))
        XCTAssertTrue(surface.composer.string.hasSuffix("with this"))
        XCTAssertTrue(context.contains("relevant earlier answer"))
        XCTAssertTrue(surface.suggestions.isHidden)
    }

    func testEscapeDismissesAndSkillsUseRealInstructions() async throws {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        let coordinator = AgentComposerCoordinator(surface: surface)
        coordinator.loadSkills = { [.init(id: "review", name: "review", description: "Review native code",
                                          path: ServerPath("/workspace/.claude/skills/review/SKILL.md"), instructions: "Check layout constraints.")] }
        surface.composer.string = "/skill:rev"
        surface.composer.setSelectedRange(NSRange(location: 10, length: 0))
        coordinator.changed()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(surface.suggestions.items.first?.title, "/skill:review")
        var context = ""
        coordinator.onContext = { _, value in context = value }
        XCTAssertTrue(coordinator.handle(#selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(context.contains("Check layout constraints."))
        XCTAssertTrue(context.contains("/workspace/.claude/skills/review"))
        surface.composer.string = "/"
        surface.composer.setSelectedRange(NSRange(location: 1, length: 0))
        coordinator.changed()
        XCTAssertTrue(coordinator.handle(#selector(NSResponder.cancelOperation(_:))))
        coordinator.changed()
        XCTAssertTrue(surface.suggestions.isHidden)
    }
}
