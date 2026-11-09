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
        XCTAssertEqual(text.attribute(.foregroundColor, at: added.location, effectiveRange: nil) as? NSColor, .systemGreen)
        let removed = (text.string as NSString).range(of: "-old")
        XCTAssertEqual(text.attribute(.foregroundColor, at: removed.location, effectiveRange: nil) as? NSColor, .systemRed)
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
