import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentComposerCoordinatorTests: XCTestCase {
    func testProviderCommandSelectionPreservesCommandForNativeExecution() async throws {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        let coordinator = AgentComposerCoordinator(surface: surface)
        coordinator.providerCommands = ["compact", "context", "clear"]
        surface.composer.string = "/compact"
        surface.composer.setSelectedRange(NSRange(location: 8, length: 0))
        coordinator.changed()
        XCTAssertEqual(surface.suggestions.items.first?.kind, .providerCommand)
        XCTAssertTrue(coordinator.handle(#selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(surface.composer.string, "/compact ")
        XCTAssertFalse(coordinator.performTypedAction(), "Provider commands must reach the provider")
        // The provider's /clear would reset its context under a transcript that still shows it.
        var action: String?
        coordinator.onAction = { action = $0 }
        surface.composer.string = "/clear"
        XCTAssertTrue(coordinator.performTypedAction())
        XCTAssertEqual(action, "clear-conversation")
    }

    func testMenuHidesUnusableCommandsAndKeepsIdentitiesUnique() async throws {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        let coordinator = AgentComposerCoordinator(surface: surface)
        coordinator.providerCommands = ["compact", "heapdump", "__remote-workflow", "clear", "model", "code-review", "status"]
        coordinator.loadSkills = { [.init(id: "/s/code-review/SKILL.md", name: "code-review", description: "",
                                          path: ServerPath("/s/code-review/SKILL.md"), instructions: ""),
                                    .init(id: "/s/notes/SKILL.md", name: "notes", description: "",
                                          path: ServerPath("/s/notes/SKILL.md"), instructions: "")] }
        surface.composer.string = "/"
        surface.composer.setSelectedRange(NSRange(location: 1, length: 0))
        coordinator.changed()
        try await Task.sleep(for: .milliseconds(250))
        let items = surface.suggestions.items
        let titles = items.map(\.title)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        XCTAssertEqual(titles.filter { $0 == "/clear" }.count, 1)
        XCTAssertEqual(items.first { $0.title == "/clear" }?.kind, .action)
        XCTAssertEqual(titles.filter { $0 == "/status" }.count, 1)
        for hidden in ["/heapdump", "/__remote-workflow", "/access", "/skill:code-review"] {
            XCTAssertFalse(titles.contains(hidden), hidden)
        }
        XCTAssertTrue(titles.contains("/code-review"))
        XCTAssertTrue(titles.contains("/skill:notes"))
        surface.composer.string = "/skill:code"
        surface.composer.setSelectedRange(NSRange(location: 11, length: 0))
        coordinator.changed()
        XCTAssertEqual(surface.suggestions.items.first?.title, "/skill:code-review", "Browsing skills lists every skill")
    }

    func testCommandNameIgnoresPaths() {
        XCTAssertEqual(AgentComposerCoordinator.commandName(in: "  /compact focus on tests"), "compact")
        XCTAssertEqual(AgentComposerCoordinator.commandName(in: "/skill:review now"), "skill:review")
        XCTAssertNil(AgentComposerCoordinator.commandName(in: "/Users/me/App.swift crashes"))
        XCTAssertNil(AgentComposerCoordinator.commandName(in: "/ hello"))
        XCTAssertNil(AgentComposerCoordinator.commandName(in: "compact"))
    }

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
