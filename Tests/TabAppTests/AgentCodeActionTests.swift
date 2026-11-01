import AppKit
import XCTest
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class AgentCodeActionTests: XCTestCase {
    func testRunEligibilityMatchesSourceCommandChecks() {
        for language in ["sh", "bash", "zsh", "fish", "shell", "powershell", "pwsh"] {
            XCTAssertEqual(AgentCodeFenceInfo.runnableCommand(language: language, code: "  echo hello  \n"), "echo hello")
        }
        for code in ["echo hello", "\n", "echo \\\n", "echo first\necho second\n", "echo\thello\n", "echo \u{202e}hidden\n", "echo \u{200b}hidden\n", "echo hello\r\n"] {
            XCTAssertNil(AgentCodeFenceInfo.runnableCommand(language: "sh", code: code), "Must not run \(code.debugDescription)")
        }
        XCTAssertNil(AgentCodeFenceInfo.runnableCommand(language: "swift", code: "print(42)\n"))
    }

    func testRunRequiresClosedFenceCompletedMessageAndAvailableHandler() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        let theme = AppTheme(systemIsDark: false)
        var commands: [String] = []
        response.onRunShellCommand = { commands.append($0) }
        response.setContent("```sh\necho hello\n", theme: theme)
        let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        XCTAssertTrue(code.run.isHidden, "A trailing newline is not proof of a closing fence")
        response.isStreaming = true
        response.setContent("```sh\necho hello\n```", theme: theme)
        XCTAssertTrue(code.run.isHidden)
        response.isStreaming = false
        XCTAssertFalse(code.run.isHidden)
        code.run.perform()
        XCTAssertEqual(commands, ["echo hello"])
        response.onRunShellCommand = nil
        XCTAssertTrue(code.run.isHidden)
        code.run.perform()
        XCTAssertEqual(commands.count, 1)
    }

    func testCopyGoesThroughTheConversationActionsWhenAvailable() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        let services = AgentConversationLinkServices()
        var copied: [String] = []
        services.copyText = { copied.append($0) }
        response.linkServices = services
        response.setContent("```sh\necho hello\n```", theme: AppTheme(systemIsDark: false))
        let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        code.copyCode()
        XCTAssertEqual(copied, ["echo hello\n"])
    }

    func testNestedCodeAndUserMessagesRespectRunAvailability() throws {
        let theme = AppTheme(systemIsDark: false)
        let response = AgentResponseView(frame: .zero)
        response.onRunShellCommand = { _ in }
        response.isStreaming = true
        response.setContent("> ```sh\n> echo nested\n> ```", theme: theme)
        let code = try XCTUnwrap(descendants(response).compactMap { $0 as? AgentResponseCode }.first)
        XCTAssertTrue(code.run.isHidden)
        response.isStreaming = false
        XCTAssertFalse(code.run.isHidden)
        let row = AgentMessageRow(frame: .zero)
        row.onRunShellCommand = { _ in XCTFail("User messages do not expose Run") }
        row.update([AgentChatItem(id: "user", kind: .user, text: "```sh\necho user\n```")])
        XCTAssertTrue(try XCTUnwrap(descendants(row).compactMap { $0 as? AgentResponseCode }.first).run.isHidden)
    }

    func testCompactActionsPreserveCopyAndResetFeedback() async throws {
        let restoreClipboard = preserveAgentTestClipboard()
        defer { restoreClipboard() }
        let response = AgentResponseView(frame: .zero)
        response.onRunShellCommand = { _ in }
        response.setContent("```sh title=\"check.sh\"\necho hello\n```", theme: AppTheme(systemIsDark: false))
        _ = response.height(for: 240)
        let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        for button in [code.copy, code.wrap, code.run] {
            XCTAssertEqual(button.title, "")
            XCTAssertNotNil(button.image)
            XCTAssertEqual(button.frame.width, 24)
        }
        XCTAssertLessThan(code.wrap.frame.maxX, code.run.frame.minX)
        XCTAssertLessThan(code.run.frame.maxX, code.copy.frame.minX)
        code.copyCode()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "echo hello\n")
        XCTAssertEqual(code.copy.toolTip, "Copied")
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(code.copy.toolTip, "Copy code")
        code.wrap.perform()
        XCTAssertEqual(code.wrap.toolTip, "Wrap lines")
    }

    func testConversationRunCreatesTerminalInItsProjectWithExactCommand() throws {
        _ = NSApplication.shared
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(server: identity, home: home.id, revision: 1, projects: [home]))
        let model = ModelFixtures.model(try ModelFixtures.profile(), server: server)
        defer { model.connection(.local)?.disconnect() }
        let project = model.state.home
        var opened: PaneId?
        XCTAssertTrue(model.edit { opened = try $0.openAgent(project.id, provider: .claude) })
        let paneID = try XCTUnwrap(opened)
        let pane = AgentPaneController(context: PaneContext(pane: try XCTUnwrap(model.state.pane(paneID)), project: project, model: model))
        defer { pane.dispose() }
        let run = try XCTUnwrap(pane.surface.onRunShellCommand)
        run("printf '%s' 'exact command'")
        let terminal = try XCTUnwrap(model.activePane)
        XCTAssertNotEqual(terminal, paneID)
        XCTAssertEqual(model.state.paneProject(terminal), project.id)
        XCTAssertEqual(model.state.startupCommand(terminal), "printf '%s' 'exact command'")
        var state = model.state
        XCTAssertEqual(state.prepareCreation(terminal, directory: "/wrong-fallback"), project.directory)
    }

    func testCodeHeaderSnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let response = AgentResponseView(frame: .zero)
            response.onRunShellCommand = { _ in }
            response.setContent("```sh title=\"scripts/check.sh\"\nswift test --filter AgentRenderingTests\n```\n\n```swift title=\"Sources/Example.swift\"\nlet result = calculateAnswer()\n```", theme: theme)
            let height = response.height(for: 360)
            let background = ThemedBackground(color: { $0.card })
            background.theme = theme
            background.frame = NSRect(x: 0, y: 0, width: 384, height: height + 24)
            background.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            response.frame = NSRect(x: 12, y: 12, width: 360, height: height)
            background.addSubview(response)
            background.themeDidChange()
            background.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(background.bitmapImageRepForCachingDisplay(in: background.bounds))
            background.cacheDisplay(in: background.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output + "/code-header-\(dark ? "dark" : "light").png"))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
