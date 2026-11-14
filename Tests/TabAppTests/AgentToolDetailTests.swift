import AppKit
import TabProtocol
@testable import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentToolDetailTests: XCTestCase {
    func testConversationIconTintRetainsTranslucentAlpha() throws {
        let icon = try XCTUnwrap(AppIcon.wrench.image(size: 24, color: .black.withAlphaComponent(0.4)))
        let bitmap = try XCTUnwrap(icon.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var maximumAlpha: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                maximumAlpha = max(maximumAlpha, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        XCTAssertGreaterThan(maximumAlpha, 0.3)
        XCTAssertLessThanOrEqual(maximumAlpha, 0.41, "Tinting must not leave an opaque black icon behind")
    }

    func testToolHeadersOnlyOfferDisclosureWhenContentExists() throws {
        let row = AgentActivityRow(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        row.update([.init(id: "tool", kind: .tool, text: "Read", tool: .init(category: .read))])
        row.layoutRow(width: 400)
        let header = try XCTUnwrap(descendants(row).compactMap { $0 as? AgentToolHeader }.first)
        XCTAssertFalse(header.isEnabled)
        XCTAssertEqual(header.activityIcon, .eye)
        XCTAssertEqual(header.font?.pointSize, 14)
        var toggles = 0
        row.onDisclosure = { toggles += 1 }
        header.performClick(nil)
        XCTAssertEqual(toggles, 0)
        row.update([.init(id: "tool", kind: .tool, text: "Read", tool: .init(category: .read, output: "File contents"))])
        XCTAssertTrue(header.isEnabled)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        header.keyDown(with: enter)
        XCTAssertEqual(toggles, 1)
        XCTAssertTrue(row.captureState().toolExpandedIDs.contains("tool"))
    }

    func testHeaderNamesToolAndBoxesOpenResult() throws {
        let row = AgentActivityRow(frame: .zero)
        let item = AgentChatItem(id: "tool", kind: .tool, text: "Run command", tool: .init(
            name: "Bash", category: .command, input: #"{"command":"echo hello"}"#, output: "hello", startedAt: Date()))
        row.update([item])
        XCTAssertEqual(row.preferredHeight(for: 400), 30)
        row.frame = NSRect(x: 0, y: 0, width: 400, height: 30)
        row.layoutRow(width: 400)
        let header = try XCTUnwrap(descendants(row).compactMap { $0 as? AgentToolHeader }.first)
        XCTAssertEqual(header.title, "Bash")
        XCTAssertEqual(header.operation, "echo hello")
        XCTAssertLessThan(header.frame.width, 400, "The header hugs the tool name and its operation")
        XCTAssertNotNil(header.timestampTooltip)
        row.restoreState(AgentTimelineRowState(toolExpandedIDs: [item.id]))
        let state = row.captureState()
        XCTAssertGreaterThan(row.preferredHeight(for: 400), 30 + 24, "The open result sits in a padded box")
        row.grouped = true
        XCTAssertEqual(row.captureState().toolExpandedIDs, state.toolExpandedIDs)
        row.restoreState(AgentTimelineRowState())
        XCTAssertEqual(row.preferredHeight(for: 400), 30)
        row.update([.init(id: "undated", kind: .tool, text: "Read", detail: "Output")])
        XCTAssertNil(header.timestampTooltip, "Reused tool rows must clear a previous activity's timestamp")
    }

    func testImageOnlyToolResultCanExpand() throws {
        let view = AgentToolDisclosure(frame: .zero)
        let attachment = AgentChatAttachment(name: "Result", mimeType: "image/png", data: Data())
        view.update(.init(id: "image", kind: .tool, text: "Render image", tool: .init(
            name: "render", status: .completed, presentation: .dynamicTool), attachments: [attachment.descriptor]),
                    expanded: false, theme: AppTheme.shared)
        let header = try XCTUnwrap(descendants(view).compactMap { $0 as? AgentToolHeader }.first)
        XCTAssertTrue(header.isEnabled)
        var expanded = false
        view.onDisclosure = { expanded = true }
        header.performClick(nil)
        XCTAssertTrue(expanded)
    }

    func testToolFailuresKeepSourceLabelsAndOnlyTintCategoryIcons() throws {
        let cases: [(AgentToolActivity.Status, Int?, String, Bool)] = [
            (.failed, nil, "Command failed", true),
            (.denied, nil, "Permission denied", true),
            (.interrupted, nil, "Cancelled", false),
            (.completed, 2, "Process finished", true),
            (.completed, 0, "No error found", false),
            (.completed, nil, "The word error is documentation", false),
        ]
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let view = AgentToolDisclosure(frame: .zero)
            for (status, code, output, failure) in cases {
                let activity = AgentToolActivity(category: .command, input: "check", output: output,
                    status: status, startedAt: Date(timeIntervalSince1970: 100), exitCode: code)
                view.update(.init(id: "tool", kind: .tool, text: "Run check", tool: activity), expanded: false, theme: theme)
                let header = try XCTUnwrap(descendants(view).compactMap { $0 as? AgentToolHeader }.first)
                XCTAssertEqual(header.title, "Bash")
                XCTAssertEqual(header.operation, "check", "Command rows display the command input without an added lifecycle suffix")
                XCTAssertEqual(header.labelColor, theme.fg)
                XCTAssertEqual(header.activityIcon, .terminal)
                XCTAssertEqual(header.iconColor, failure ? AgentToolRowPresentation.failureIconColor(theme: theme) : theme.fgDim)
                XCTAssertTrue(header.toolTip?.contains(status.rawValue.capitalized) == true)
                XCTAssertEqual(header.accessibilityLabel()?.contains("tool call failed"), failure)
                XCTAssertTrue(header.accessibilityLabel()?.contains(status.rawValue.capitalized) == true)
                let tooltip = header.toolTip
                view.refresh(theme: theme)
                XCTAssertEqual(header.toolTip, tooltip, "Streaming refreshes must not duplicate the date tooltip")
            }
        }
    }

    /// Running, interrupted and finished tools used to look the same.
    func testToolLifecycleIsVisibleInTheHeader() throws {
        let view = AgentToolDisclosure(frame: NSRect(x: 0, y: 0, width: 500, height: 30))
        let start = Date(timeIntervalSince1970: 100)
        func header(_ item: AgentChatItem, expanded: Bool = false) throws -> AgentToolHeader {
            view.update(item, expanded: expanded, theme: .shared)
            return try XCTUnwrap(descendants(view).compactMap { $0 as? AgentToolHeader }.first)
        }
        func glyphShown(_ header: AgentToolHeader) -> Bool {
            header.subviews.contains { $0 is ActivityGlyph && !$0.isHidden }
        }
        let running = AgentToolActivity(category: .command, input: "swift build", status: .running, startedAt: start)
        var item = AgentChatItem(id: "t", kind: .tool, text: "Bash", isComplete: false, tool: running)
        var shown = try header(item)
        XCTAssertTrue(shown.running)
        XCTAssertTrue(glyphShown(shown), "A running tool shows the activity glyph in its icon slot")
        XCTAssertNil(shown.suffix)

        // An older server finished the turn without updating the tool.
        item.isComplete = true
        shown = try header(item)
        XCTAssertEqual(AgentToolRowPresentation.status(item), .interrupted)
        XCTAssertFalse(glyphShown(shown))
        XCTAssertEqual(shown.suffix, "Interrupted")
        XCTAssertEqual(shown.iconColor, AppTheme.shared.fgDim, "Interrupted is not a failure")
        XCTAssertEqual(AgentCommandPresentation.output(AgentToolActivity(status: .interrupted), theme: .shared).string,
                       "Interrupted before output")
        XCTAssertEqual(AgentCommandPresentation.output(AgentToolActivity(status: .completed), theme: .shared).string, "No output.")

        var failed = running
        failed.status = .failed
        failed.exitCode = 2
        failed.completedAt = start.addingTimeInterval(4)
        shown = try header(.init(id: "t", kind: .tool, text: "Bash", tool: failed))
        XCTAssertEqual(shown.suffix, "exit 2 · 4s")
        failed.exitCode = nil
        failed.category = .read
        failed.completedAt = start.addingTimeInterval(0.4)
        shown = try header(.init(id: "t", kind: .tool, text: "Read", tool: failed))
        XCTAssertEqual(shown.suffix, "Failed", "Under a second shows no duration")
        var done = running
        done.status = .completed
        done.completedAt = start.addingTimeInterval(75)
        shown = try header(.init(id: "t", kind: .tool, text: "Bash", tool: done))
        XCTAssertEqual(shown.suffix, "1m, 15s")
    }

    func testFoldSummaryCountsCallsAndFailuresNotThinkingOrCards() throws {
        let row = AgentCompletedWorkRow(frame: .zero)
        row.update([
            .init(id: "think", kind: .tool, text: "Thinking", detail: "Hmm", workContext: .init(itemType: "reasoning")),
            .init(id: "todo", kind: .tool, text: "TodoWrite", detail: "{}", tool: .init(name: "TodoWrite"), workContext: .init(itemType: "todo_list")),
            .init(id: "ok", kind: .tool, text: "Read", tool: .init(category: .read, status: .completed)),
            .init(id: "bad", kind: .tool, text: "Bash", tool: .init(category: .command, status: .completed, exitCode: 1)),
            .init(id: "stopped", kind: .tool, text: "Bash", tool: .init(category: .command, status: .interrupted)),
            .init(id: "note", kind: .assistant, text: "Looking"),
        ])
        XCTAssertEqual(row.summary, "3 tool calls, 1 message · 1 failed")
    }

    func testEditsAreTitledByWhatTheyDidAndCountTheirLines() throws {
        func title(_ name: String, kind: String) -> String {
            AgentToolPresentation.displayName(.init(name: name, category: .edit, fileChanges: [.init(path: "a.swift", diff: "+x", kind: kind)]))
        }
        XCTAssertEqual(title("apply_patch", kind: "add"), "Create")
        XCTAssertEqual(title("Write", kind: "write"), "Write")
        XCTAssertEqual(title("Edit", kind: "update"), "Edit")
        XCTAssertEqual(title("apply_patch", kind: "delete"), "Delete")
        let view = AgentToolDisclosure(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
        view.update(.init(id: "e", kind: .tool, text: "Edit", tool: .init(name: "Edit", category: .edit, status: .completed,
            fileChanges: [.init(path: "a.swift", diff: "-old\n+new\n+more", kind: "update")], presentation: .fileChange)),
                    expanded: false, theme: .shared)
        let header = try XCTUnwrap(descendants(view).compactMap { $0 as? AgentToolHeader }.first)
        XCTAssertEqual(header.suffix, "+2 −1", "The collapsed row says how big the edit is")
    }

    /// Paths and commands in tool rows were inert; the header now offers what the tool touched.
    func testToolRowsOfferTheirActionsAndLinkPathLines() throws {
        let view = AgentToolDisclosure(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        var ran: String?, shown: String?, opened: (String, Int?)?
        view.onRunShellCommand = { ran = $0 }
        view.onShowFullOutput = { shown = $0 }
        view.onOpenFile = { opened = ($0, $1) }
        var tool = AgentToolActivity(name: "Bash", category: .command, input: #"{"command":"swift build"}"#,
                                     output: "Sources/App.swift:12:5: error: missing", status: .failed, presentation: .command)
        tool.fullOutputBytes = 40_000
        view.update(.init(id: "b", kind: .tool, text: "Bash", tool: tool), expanded: true, theme: .shared)
        view.layoutSubtreeIfNeeded()
        let menu = try XCTUnwrap(view.actionsMenu())
        XCTAssertEqual(menu.items.map(\.title), ["Copy Command", "Run in Terminal", "Copy Output", "Show Full Output"])
        for title in ["Run in Terminal", "Show Full Output", "Copy Command"] {
            let item = try XCTUnwrap(menu.items.first { $0.title == title })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        XCTAssertEqual(ran, "swift build")
        XCTAssertEqual(shown, "b")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "swift build")
        XCTAssertTrue(descendants(view).contains { ($0 as? NSButton)?.title == "Show full output" && !$0.isHidden })

        let linked = AgentToolText.linkingPathLines(NSAttributedString(string: "Sources/App.swift:12:5: error and origin/main:3"), theme: .shared)
        let url = try XCTUnwrap(linked.attribute(.link, at: 0, effectiveRange: nil) as? URL)
        XCTAssertEqual(url.scheme, "agent-file")
        XCTAssertTrue(url.absoluteString.contains("line=12"))
        let branch = (linked.string as NSString).range(of: "origin/main:3")
        XCTAssertNil(linked.attribute(.link, at: branch.location, effectiveRange: nil), "Not a file")
        _ = opened
    }

    func testSmallerToolPresentationDetails() {
        XCTAssertEqual(AgentToolPresentation.displayName(.init(name: "mcp__linear__create_issue")), "create_issue (linear)")
        XCTAssertEqual(AgentWebSearchPanel.paragraphs("First   line\nsame paragraph\n\n\nSecond\tparagraph"),
                       "First line same paragraph\n\nSecond paragraph")
        let thinking = AgentChatItem(id: "r", kind: .tool, text: "Thinking", detail: "…", isComplete: true,
                                     createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 12),
                                     workContext: .init(itemType: "reasoning"))
        XCTAssertEqual(AgentToolDisclosure.thinkingTime(thinking), "12s")
        let usage = AgentTurnUsage(inputTokens: 12_300, outputTokens: 900, costUSD: 0.02, model: "claude-opus-5-5", stopReason: "max_tokens")
        XCTAssertEqual(AgentMessageRow.describe(usage), ["claude-opus-5-5", "12.3k tokens in · 900 out", "$0.0200", "Stopped: reached a limit (max_tokens)"])
    }

    func testACutDiffIsMarkedTruncated() {
        let parsed = AgentToolDiff.parse("@@ -1,2 +1,2 @@\n-old\n+new\n" + AgentToolActivity.diffTruncationMarker)
        XCTAssertTrue(parsed.truncated)
        XCTAssertEqual(parsed.rows.map(\.text), ["@@ -1,2 +1,2 @@", "-old", "+new"])
        XCTAssertFalse(AgentToolDiff.parse("@@ -1 +1 @@\n-a\n+b").truncated)
    }

    func testFailureIconUsesSelectedAppDangerColorWithQuietOpacity() throws {
        for dark in [false, true] {
            let scheme = ColorScheme(background: RGBColor(dark ? 0x102030 : 0xF0E0D0), foreground: RGBColor(dark ? 0xD0E0F0 : 0x203040), palette: [1: RGBColor(0xAA3377)])
            let theme = AppTheme(catalog: ThemeCatalog(entries: [ThemeEntry(name: "Custom", scheme: scheme)]), darkTheme: "Custom", lightTheme: "Custom", systemIsDark: dark)
            XCTAssertEqual(AgentToolRowPresentation.failureIconColor(theme: theme), theme.danger.withAlphaComponent(0.28))
        }
    }

    func testRecordedCommandOutputUsesTerminalColorsAndCarriageReturn() {
        let theme = AppTheme(systemIsDark: true)
        let text = AgentToolText.terminalText("\u{1b}[32mstream line 2\u{1b}[0m\nprogress 50%\rprogress 100%\n", theme: theme, terminal: true)
        XCTAssertEqual(text.string, "stream line 2\nprogress 100%\n")
        XCTAssertEqual(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemGreen)
        XCTAssertNotNil(text.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testInputOutputDiffAndFileLinksArePresentedTogether() {
        let theme = AppTheme(systemIsDark: true)
        var item = AgentChatItem(id: "edit", kind: .tool, text: "Edit")
        item.tool = AgentToolActivity(name: "Edit", category: .edit, input: #"{"file_path":"Sources/main.swift"}"#,
                                      output: "Updated", status: .completed, filePaths: ["Sources/main.swift"],
                                      fileChanges: [.init(path: "Sources/main.swift", diff: "-old\n+new", kind: "update")])
        let text = AgentToolText.content(item, theme: theme)
        XCTAssertTrue(text.string.contains("Input"))
        XCTAssertTrue(text.string.contains("Updated"))
        let added = (text.string as NSString).range(of: "+new")
        XCTAssertEqual(text.attribute(.foregroundColor, at: added.location, effectiveRange: nil) as? NSColor, theme.diffAdd)
        let removed = (text.string as NSString).range(of: "-old")
        XCTAssertEqual(text.attribute(.foregroundColor, at: removed.location, effectiveRange: nil) as? NSColor, theme.diffRemove)
        let path = (text.string as NSString).range(of: "Sources/main.swift")
        XCTAssertEqual((text.attribute(.link, at: path.location, effectiveRange: nil) as? URL)?.scheme, "agent-file")
    }

    func testDisclosureTriggersParentReflowAndMeasuresExpandedContent() async throws {
        let view = AgentActivityRow(frame: .zero)
        view.update([.init(kind: .tool, text: "Read", detail: "File contents")])
        let collapsed = view.preferredHeight(for: 500)
        view.frame = NSRect(x: 0, y: 0, width: 500, height: collapsed)
        view.layoutRow(width: 500)
        var disclosures = 0
        view.onDisclosure = { disclosures += 1 }
        let button = try XCTUnwrap(descendants(view).compactMap { $0 as? AgentToolHeader }.first)
        button.onPress?()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThan(disclosures, 0)
        XCTAssertGreaterThan(view.preferredHeight(for: 500), collapsed)
        let beforeCollapse = disclosures
        button.onPress?()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThan(disclosures, beforeCollapse)
        XCTAssertEqual(view.preferredHeight(for: 500), collapsed)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
