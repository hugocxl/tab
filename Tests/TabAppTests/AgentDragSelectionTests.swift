import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentDragSelectionTests: XCTestCase {
    /// A drag from a paragraph through a code block into the next paragraph selects the
    /// code whole and the next paragraph up to the pointer.
    func testDragCarriesSelectionAcrossBlocks() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        response.setContent("First paragraph.\n\n```swift\nlet code = 1\n```\n\nLast paragraph here.", theme: AppTheme(systemIsDark: true))
        let height = response.height(for: 500)
        response.frame = NSRect(x: 0, y: 0, width: 500, height: height)
        response.layoutSubtreeIfNeeded()
        let views = AgentTranscriptSelection.textViews(in: response)
            .sorted { response.convert($0.bounds, from: $0).minY < response.convert($1.bounds, from: $1).minY }
        XCTAssertEqual(views.count, 3)
        let (first, code, last) = (views[0], views[1], views[2])
        first.setSelectedRange(NSRange(location: 6, length: 10))
        let lastFrame = response.convert(last.bounds, from: last)
        let point = NSPoint(x: lastFrame.minX + 40, y: lastFrame.midY)
        AgentTranscriptSelection.extendDrag(in: response, from: first, to: point)
        XCTAssertEqual(code.selectedRange(), NSRange(location: 0, length: code.string.utf16.count))
        XCTAssertEqual(last.selectedRange().location, 0)
        XCTAssertGreaterThan(last.selectedRange().length, 0)
        XCTAssertLessThan(last.selectedRange().length, last.string.utf16.count)
        XCTAssertEqual(first.selectedRange(), NSRange(location: 6, length: 10), "The source keeps its own drag's selection")

        // Dragging back up over the source releases the blocks below.
        let firstFrame = response.convert(first.bounds, from: first)
        AgentTranscriptSelection.extendDrag(in: response, from: first, to: NSPoint(x: 10, y: firstFrame.midY))
        XCTAssertEqual(code.selectedRange().length, 0)
        XCTAssertEqual(last.selectedRange().length, 0)
    }
}

@MainActor
final class AgentCodeFoldTests: XCTestCase {
    func testLongFinishedCodeFoldsAndOpensWhole() throws {
        _ = NSApplication.shared
        let theme = AppTheme(systemIsDark: true)
        let body = (1...120).map { "line \($0)" }.joined(separator: "\n")
        let response = AgentResponseView(frame: .zero)
        response.isStreaming = true
        response.setContent("```swift\n" + body, theme: theme)
        let streaming = response.height(for: 500)
        let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        XCTAssertFalse(code.isFoldable, "A block still streaming never folds under the reader")
        response.isStreaming = false
        response.setContent("```swift\n" + body + "\n```", theme: theme)
        let folded = response.height(for: 500)
        XCTAssertTrue(code.isFoldable)
        XCTAssertLessThan(folded, streaming / 2)
        XCTAssertEqual(code.more.title, "Show all 120 lines")
        code.more.onPress?()
        XCTAssertGreaterThan(response.height(for: 500), streaming)
        XCTAssertEqual(code.captureState().expanded, true, "Opening survives the row leaving the screen")
    }
}

@MainActor
final class AgentReadingGapsTests: XCTestCase {
    func testShellVariablesAreNotMath() {
        XCTAssertTrue(AgentMarkdownMath.extract("Copy $FOO/$BAR there").spans.isEmpty)
        XCTAssertTrue(AgentMarkdownMath.extract("Use $HOME and $PATH").spans.isEmpty)
        XCTAssertEqual(AgentMarkdownMath.extract("Area $x^2$ grows").spans.count, 1)
    }

    func testHTMLTablesRenderAsTables() {
        let blocks = AgentResponseParser.parse("<table>\n<tr><th>Name</th><th>State</th></tr>\n<tr><td>Build</td><td><b>Ready</b></td></tr>\n</table>\n\nAfter")
        guard case .table(let headers, let rows, _)? = blocks.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(headers, ["Name", "State"])
        XCTAssertEqual(rows, [["Build", "<b>Ready</b>"]])
        XCTAssertEqual(blocks.last, .paragraph("After"))
        // Until it closes, a streaming table stays text rather than a half-built grid.
        XCTAssertNil(AgentResponseParser.htmlTable(["<table>", "<tr><td>a</td></tr>"], from: 0))
    }

    func testTallInlineMathGrowsItsLine() {
        let theme = AppTheme(systemIsDark: false)
        let text = AgentMarkdown.render(AgentResponseParser.parse("Sum $\\displaystyle\\sum_{i=1}^{n}\\frac{a_i}{b_i}$ here"), theme: theme)
        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.maximumLineHeight, 0)
        let plain = AgentMarkdown.render(AgentResponseParser.parse("Plain words"), theme: theme)
        XCTAssertGreaterThan((plain.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.maximumLineHeight ?? 0, 0)
    }

    func testUnsupportedDiagramFamilyIsANoteNotAnError() {
        guard case .failure(let error) = AgentDiagramCache.parseUncached("erDiagram\n  A ||--o{ B : has") else { return XCTFail() }
        XCTAssertTrue(error.unsupported)
        guard case .failure(let broken) = AgentDiagramCache.parseUncached("flowchart LR\n  A --> ") else { return }
        XCTAssertFalse(broken.unsupported)
    }
}

@MainActor
final class AgentKeyboardAccessTests: XCTestCase {
    func testComposerControlsShowKeyboardFocus() {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        for control in [surface.send, surface.stop, surface.microphone, surface.contextIndicator] as [NSView] {
            XCTAssertEqual(control.focusRingType, .exterior, "\(type(of: control))")
        }
    }

    func testNextFailureAndScrollKeysReachTheConversation() throws {
        let pane = AgentPaneController(session: SessionId(), project: ProjectId(), provider: .claude) { _ in throw CancellationError() }
        defer { pane.dispose() }
        var snapshot = AgentChatSnapshot(session: pane.session, project: ProjectId(), provider: .claude, status: .idle, revision: 1)
        snapshot.items = [AgentChatItem(kind: .user, text: "Build it"),
                          AgentChatItem(id: "ok", kind: .tool, text: "Bash", tool: .init(name: "Bash", status: .completed)),
                          AgentChatItem(id: "bad", kind: .tool, text: "Bash", tool: .init(name: "Bash", status: .failed))]
        XCTAssertFalse(pane.performConversationShortcut(.agentNextFailure), "Nothing has failed yet")
        pane.surface.render(snapshot)
        XCTAssertTrue(pane.performConversationShortcut(.agentNextFailure))
        XCTAssertTrue(pane.performConversationShortcut(.scrollToBottom))
        XCTAssertNotNil(Keymap().chord(.agentPreviousPrompt))
        XCTAssertFalse(pane.performConversationShortcut(.submitAgentAnswers), "Without a form the key goes on to the composer")
    }

    func testWrittenAnswersTakeSeveralLines() throws {
        let form = AgentQuestionnaire(questions: [.init(id: "why", title: "Why?")])
        let item = AgentChatItem(id: "form", kind: .approval, text: "Questions", isComplete: false, questionnaire: form)
        let view = AgentQuestionView(frame: NSRect(x: 0, y: 0, width: 360, height: 280))
        view.update(item, enabled: true)
        let short = view.preferredHeight(for: 360)
        var sent: [String: [String]]?
        view.onAnswer = { _, answers, _ in sent = answers }
        let field = try XCTUnwrap(allViews(view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertFalse(field.usesSingleLineMode)
        field.stringValue = "First line\nSecond line\nThird line"
        XCTAssertGreaterThan(view.preferredHeight(for: 360), short, "The field grows with the answer")
        XCTAssertTrue(view.submitAnswers())
        XCTAssertEqual(sent?["why"], ["First line\nSecond line\nThird line"])
    }

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
}

@MainActor
final class AgentTableResizeTests: XCTestCase {
    func testResizingMeasuresCellsOnce() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        response.setContent("| Name | Notes |\n| --- | --- |\n| Build | A long note that wraps when the pane is narrow enough |", theme: AppTheme(systemIsDark: true))
        let widths: [CGFloat] = [700, 520, 360, 600]
        let heights = widths.map { response.height(for: $0) }
        let table = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseTable }.first)
        XCTAssertEqual(table.cellMeasurements, 1, "A split drag lays the grid out again without measuring every cell")
        XCTAssertGreaterThan(heights[2], heights[0], "The narrow width still wraps")
    }
}
