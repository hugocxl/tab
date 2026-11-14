import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationFindTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.close() }
        windows.removeAll()
        super.tearDown()
    }

    private func makeSnapshot(_ items: [AgentChatItem], turns: [AgentChatTurn]? = nil) -> AgentChatSnapshot {
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex,
                                         status: .idle, revision: 1, items: items)
        snapshot.turns = turns
        return snapshot
    }

    private func makePane(_ items: [AgentChatItem], turns: [AgentChatTurn]? = nil) -> AgentPaneView {
        let pane = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 680, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        windows.append(window)
        pane.layoutSubtreeIfNeeded()
        pane.render(makeSnapshot(items, turns: turns))
        pane.layoutSubtreeIfNeeded()
        return pane
    }

    private func type(_ query: String, in pane: AgentPaneView) {
        guard let bar = pane.findBar else { return XCTFail("The find bar is not open") }
        bar.query = query
        bar.findBar(bar.bar, didChangeQuery: query)
    }

    private func textViews(_ root: NSView) -> [NSTextView] {
        root.subviews.flatMap { child -> [NSTextView] in
            (child as? NSTextView).map { [$0] } ?? textViews(child)
        }
    }

    /// Text views with at least one painted match, and the painted ranges' text.
    private func painted(_ pane: AgentPaneView) -> [(view: NSTextView, texts: [String], colors: [NSColor])] {
        textViews(pane.transcript).compactMap { view in
            guard let manager = view.layoutManager, let length = view.textStorage?.length else { return nil }
            var texts: [String] = []
            var colors: [NSColor] = []
            var location = 0
            while location < length {
                var effective = NSRange()
                let color = manager.temporaryAttribute(.agentFindHighlight, atCharacterIndex: location,
                                                       longestEffectiveRange: &effective,
                                                       in: NSRange(location: 0, length: length)) as? NSColor
                if let color {
                    texts.append((view.string as NSString).substring(with: effective))
                    colors.append(color)
                }
                location = max(location + 1, NSMaxRange(effective))
            }
            return texts.isEmpty ? nil : (view, texts, colors)
        }
    }

    // MARK: Routing

    func testFindShortcutsMapToConversationFindActions() {
        XCTAssertEqual(AgentConversationFindAction(shortcut: .find), .open)
        XCTAssertEqual(AgentConversationFindAction(shortcut: .findNext), .next)
        XCTAssertEqual(AgentConversationFindAction(shortcut: .findPrevious), .previous)
        XCTAssertNil(AgentConversationFindAction(shortcut: .newTab))
        XCTAssertNil(AgentConversationFindAction(shortcut: .copy))
    }

    func testPaneHandlesFindShortcutsAndPassesOthersOn() {
        let snapshot = makeSnapshot([.init(id: "answer", kind: .assistant, text: "A retained answer")])
        let pane = AgentPaneController(session: snapshot.session, project: snapshot.project, provider: .codex) { _ in snapshot }
        defer { pane.dispose() }
        pane.surface.render(snapshot)
        XCTAssertFalse(pane.performConversationShortcut(.newTab))
        XCTAssertFalse(pane.performConversationShortcut(.findNext), "Cmd-G goes on while the bar is closed")
        XCTAssertTrue(pane.performConversationShortcut(.find))
        XCTAssertTrue(pane.surface.isFindOpen)
        XCTAssertTrue(pane.performConversationShortcut(.findNext))
        XCTAssertTrue(pane.performConversationShortcut(.findPrevious))
    }

    // MARK: Bar

    func testOpenShowsTheBarAndFocusesTheField() throws {
        let pane = makePane([.init(id: "a", kind: .assistant, text: "Hello")])
        XCTAssertNil(pane.findBar)
        XCTAssertTrue(pane.performFind(.open))
        let bar = try XCTUnwrap(pane.findBar)
        XCTAssertFalse(bar.isHidden)
        XCTAssertTrue(bar.isEditing)
        XCTAssertEqual(bar.frame.minY, 0)
        XCTAssertEqual(bar.frame.width, pane.bounds.width)
        XCTAssertEqual(bar.counter, "")
    }

    func testOpenAgainRefocusesTheFieldAndKeepsTheQuery() throws {
        let pane = makePane([.init(id: "a", kind: .assistant, text: "needle needle")])
        pane.performFind(.open)
        type("needle", in: pane)
        pane.performFind(.next)
        pane.window?.makeFirstResponder(pane.composer)
        let bar = try XCTUnwrap(pane.findBar)
        XCTAssertFalse(bar.isEditing)
        XCTAssertTrue(pane.performFind(.open))
        XCTAssertTrue(bar.isEditing)
        XCTAssertEqual(bar.query, "needle")
        XCTAssertEqual(bar.counter, "2 of 2", "Refocusing does not reset the selection")
    }

    func testNextAndPreviousMoveTheSelectionAndCounter() throws {
        let pane = makePane([
            .init(id: "a", kind: .user, text: "Where is the needle?"),
            .init(id: "b", kind: .assistant, text: "The needle is here, and another needle there."),
        ])
        pane.performFind(.open)
        type("NEEDLE", in: pane)
        let bar = try XCTUnwrap(pane.findBar)
        XCTAssertEqual(bar.counter, "1 of 3")
        pane.performFind(.next)
        XCTAssertEqual(bar.counter, "2 of 3")
        XCTAssertEqual(pane.findModel?.selected?.itemID, "b")
        pane.performFind(.next)
        pane.performFind(.next)
        XCTAssertEqual(bar.counter, "1 of 3")
        pane.performFind(.previous)
        XCTAssertEqual(bar.counter, "3 of 3")
        bar.findBar(bar.bar, step: true)
        XCTAssertEqual(bar.counter, "2 of 3", "Shift-Return and the previous button step back")
        type("haystack", in: pane)
        XCTAssertEqual(bar.counter, "No results")
    }

    func testCloseHidesTheBarAndReturnsFocusToTheComposer() throws {
        let pane = makePane([.init(id: "a", kind: .assistant, text: "needle")])
        pane.performFind(.open)
        type("needle", in: pane)
        let bar = try XCTUnwrap(pane.findBar)
        bar.findBarDidClose(bar.bar)
        XCTAssertTrue(bar.isHidden)
        XCTAssertFalse(pane.isFindOpen)
        XCTAssertNil(pane.transcript.onViewportSettled)
        XCTAssertTrue(pane.window?.firstResponder === pane.composer)
        XCTAssertFalse(pane.performFind(.next))
        XCTAssertFalse(pane.performFind(.close))
    }

    // MARK: Highlights

    func testMatchesArePaintedWithoutChangingTheRenderedTextAndClearedOnClose() throws {
        let pane = makePane([
            .init(id: "a", kind: .user, text: "Find the **needle**"),
            .init(id: "b", kind: .assistant, text: "A *needle*, and a [needle](https://example.com/needle)."),
        ])
        let before = textViews(pane.transcript).map { $0.attributedString() }
        pane.performFind(.open)
        type("needle", in: pane)
        let matches = painted(pane)
        XCTAssertEqual(matches.flatMap(\.texts).map { $0.lowercased() }, ["needle", "needle", "needle"])
        let colors = matches.flatMap(\.colors)
        XCTAssertEqual(colors.filter { $0 == pane.findHighlighter.currentColor }.count, 1)
        XCTAssertEqual(colors.filter { $0 == pane.findHighlighter.matchColor }.count, 2)
        XCTAssertEqual(textViews(pane.transcript).map { $0.attributedString() }, before,
                       "Highlights are temporary attributes, not text attributes")
        pane.performFind(.close)
        XCTAssertTrue(painted(pane).isEmpty)
    }

    func testTheCurrentMatchMovesBetweenRows() throws {
        let pane = makePane([
            .init(id: "a", kind: .user, text: "needle"),
            .init(id: "b", kind: .assistant, text: "needle"),
        ])
        pane.performFind(.open)
        type("needle", in: pane)
        func currentText() -> NSTextView? {
            painted(pane).first { $0.colors.contains(pane.findHighlighter.currentColor) }?.view
        }
        let first = try XCTUnwrap(currentText())
        pane.performFind(.next)
        let second = try XCTUnwrap(currentText())
        XCTAssertFalse(first === second)
        XCTAssertEqual(painted(pane).flatMap(\.colors).filter { $0 == pane.findHighlighter.currentColor }.count, 1)
    }

    func testCodeBlocksAndTablesArePainted() throws {
        let pane = makePane([.init(id: "a", kind: .assistant, text: """
            Intro needle.

            ```swift
            let needle = 1
            ```

            | Name | Value |
            | --- | --- |
            | needle | yes |
            """)])
        pane.performFind(.open)
        type("needle", in: pane)
        XCTAssertEqual(pane.findBar?.counter, "1 of 3")
        let views = painted(pane).map(\.view)
        XCTAssertEqual(views.count, 3)
        XCTAssertTrue(views.contains { view in sequence(first: view as NSView, next: \.superview).contains { $0 is AgentResponseCode } })
        XCTAssertTrue(views.contains { view in sequence(first: view as NSView, next: \.superview).contains { $0 is AgentResponseTable } })
    }

    func testRowsMountedWhileOpenArePainted() throws {
        var items = (0..<80).map {
            AgentChatItem(id: "m\($0)", kind: .assistant, text: "Message \($0) with enough text to wrap a little.\n\nAnother paragraph.")
        }
        items[0].text = "The first needle."
        let pane = makePane(items)
        pane.performFind(.open)
        type("needle", in: pane)
        pane.performFind(.close)
        pane.scrollToEnd()
        pane.performFind(.open)
        XCTAssertTrue(painted(pane).isEmpty, "The first message is not mounted at the end")
        let clip = pane.transcriptScroll.contentView
        clip.scroll(to: .zero)
        pane.transcriptScroll.reflectScrolledClipView(clip)
        XCTAssertEqual(painted(pane).flatMap(\.texts), ["needle"])
    }

    func testStreamingUpdatesTheCountAndPaintsNewText() throws {
        var items: [AgentChatItem] = [
            .init(id: "a", kind: .user, text: "needle"),
            .init(id: "b", kind: .assistant, text: "Looking", isComplete: false),
        ]
        let pane = makePane(items)
        pane.performFind(.open)
        type("needle", in: pane)
        XCTAssertEqual(pane.findBar?.counter, "1 of 1")
        items[1].text = "Looking for the needle"
        var next = makeSnapshot(items)
        next.revision = 2
        pane.render(next)
        XCTAssertEqual(pane.findBar?.counter, "1 of 2")
        XCTAssertEqual(painted(pane).flatMap(\.texts), ["needle", "needle"])
    }

    // MARK: Scrolling

    func testCurrentMatchIsScrolledIntoView() throws {
        var items = (0..<60).map {
            AgentChatItem(id: "m\($0)", kind: .assistant, text: "Message \($0)\n\nWith a second paragraph of filler text.")
        }
        items[3].text = "An early needle."
        items[40].text = "A later needle."
        let pane = makePane(items)
        XCTAssertTrue(pane.isAtBottom)
        pane.performFind(.open)
        type("needle", in: pane)
        let first = try XCTUnwrap(pane.currentFindMatchRect())
        XCTAssertTrue(pane.findVisibleRect.contains(first), "\(first) in \(pane.findVisibleRect)")
        pane.performFind(.next)
        let second = try XCTUnwrap(pane.currentFindMatchRect())
        XCTAssertGreaterThan(second.minY, first.minY)
        XCTAssertTrue(pane.findVisibleRect.contains(second), "\(second) in \(pane.findVisibleRect)")
    }

    func testOpeningAndClosingKeepsTheReadingPosition() throws {
        let items = (0..<60).map {
            AgentChatItem(id: "m\($0)", kind: .assistant, text: "Message \($0)\n\nWith a second paragraph of filler text.")
        }
        let pane = makePane(items)
        let clip = pane.transcriptScroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: 400))
        pane.transcriptScroll.reflectScrolledClipView(clip)
        let position = clip.bounds.origin
        pane.performFind(.open)
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(clip.bounds.origin, position)
        pane.performFind(.close)
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(clip.bounds.origin, position)
    }

    func testMatchInsideAFoldedWorkGroupExpandsIt() throws {
        let date = Date()
        let turn = AgentChatTurn(userItemID: "prompt", startedAt: date, completedAt: date.addingTimeInterval(4),
                                 status: .idle, outcome: .completed)
        let items: [AgentChatItem] = [
            .init(id: "prompt", kind: .user, text: "Inspect"),
            .init(id: "commentary", kind: .assistant, text: "Checking the needle first."),
            .init(id: "tool", kind: .tool, text: "Read", tool: .init(name: "Read", input: "{}", output: "needle in output")),
            .init(id: "answer", kind: .assistant, text: "Done with the haystack."),
        ]
        let pane = makePane(items, turns: [turn])
        XCTAssertNil(pane.transcript.entryID(showing: "commentary"))
        pane.performFind(.open)
        type("haystack", in: pane)
        XCTAssertNotEqual(pane.transcript.rowStates["work:prompt"]?.expanded, true, "Matches outside a group leave it folded")
        type("needle", in: pane)
        XCTAssertEqual(pane.findBar?.counter, "1 of 2", "Tool output is searched too")
        XCTAssertEqual(pane.transcript.rowStates["work:prompt"]?.expanded, true)
        XCTAssertEqual(pane.transcript.entryID(showing: "commentary"), "commentary")
        XCTAssertEqual(painted(pane).flatMap(\.texts), ["needle"])
        // The tool's match opens its row.
        XCTAssertTrue(pane.performFind(.next))
        XCTAssertEqual(pane.findBar?.counter, "2 of 2")
        XCTAssertEqual(pane.transcript.rowStates["activity:tool"]?.toolExpandedIDs, ["tool"])
    }

    func testMatchInAProposedPlanCardIsPaintedAndRevealed() throws {
        let items: [AgentChatItem] = [
            .init(id: "prompt", kind: .user, text: "Plan the migration"),
            .init(id: "plan", kind: .tool, text: "Proposed plan", detail: "## Steps\n\n1. Move the needle\n2. Verify",
                  workContext: .init(itemType: "proposed_plan", sourceStatus: "completed", planStatus: "active")),
        ]
        let pane = makePane(items)
        pane.performFind(.open)
        type("needle", in: pane)
        XCTAssertEqual(pane.findBar?.counter, "1 of 1")
        XCTAssertEqual(painted(pane).flatMap(\.texts), ["needle"], "Plan cards are always visible; their body is searched")
        XCTAssertNotNil(pane.currentFindMatchRect())
    }

    // MARK: Rendered text

    private func escape(_ window: NSWindow?) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
                                       charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    private func filler(_ count: Int) -> [AgentChatItem] {
        (0..<count).map {
            AgentChatItem(id: "m\($0)", kind: .assistant, text: "Message \($0) with enough text to wrap a little.\n\nAnother paragraph.")
        }
    }

    func testTheCountMatchesThePaintedMatches() throws {
        let pane = makePane([
            .init(id: "a", kind: .user, text: "Find the **needle**"),
            .init(id: "b", kind: .assistant, text: "A *needle*, and a [needle](https://example.com/needle)."),
        ])
        pane.performFind(.open)
        type("needle", in: pane)
        XCTAssertEqual(pane.findBar?.counter, "1 of 3", "The link's URL is not counted")
        XCTAssertEqual(painted(pane).flatMap(\.texts).count, 3)
    }

    func testLinkTargetsAndFenceInfoAreNotMatches() throws {
        let pane = makePane([.init(id: "a", kind: .assistant, text: """
            Read [the docs](https://example.com/needle).

            ```needle
            let value = 1
            ```
            """)])
        pane.performFind(.open)
        type("needle", in: pane)
        XCTAssertEqual(pane.findBar?.counter, "No results")
        type("docs", in: pane)
        XCTAssertEqual(pane.findBar?.counter, "1 of 1")
    }

    func testUnmountedMessagesAreCountedFromTheirRenderedText() throws {
        var items = filler(80)
        items[0].text = "A [needle](https://example.com/needle) at the top."
        items[79].text = "The last needle."
        let pane = makePane(items)
        pane.findHighlighter.search = { _, _ in XCTFail("The mounted text is the text the model searched"); return [] }
        pane.performFind(.open)
        type("needle", in: pane)
        XCTAssertEqual(pane.findBar?.counter, "1 of 2")
        XCTAssertGreaterThan(pane.findTexts.renderCount, 0, "The first message was rendered off screen")
        XCTAssertEqual(painted(pane).flatMap(\.texts), ["needle"], "Revealing the first match mounts and paints it")
        XCTAssertNotNil(pane.currentFindMatchRect())
        XCTAssertEqual(pane.findHighlighter.searchCount, 0)
    }

    func testOffscreenRendersMatchTheMountedRows() throws {
        let items: [AgentChatItem] = [
            .init(id: "u", kind: .user, text: "First line\nsecond <b>line</b> with `code`"),
            .init(id: "a", kind: .assistant, text: "Intro <b>bold</b>\n\n| A | B |\n| --- | --- |\n| one | two |\n\n- item"),
            .init(id: "p", kind: .tool, text: "Proposed plan", detail: "## Steps\n\n1. Move\n2. Verify",
                  workContext: .init(itemType: "proposed_plan", sourceStatus: "completed", planStatus: "active")),
        ]
        let pane = makePane(items)
        let cache = AgentConversationFindTextCache()
        for item in items {
            let row = try XCTUnwrap(pane.transcript.mountedRow(showing: item))
            XCTAssertEqual(cache.text(for: item, theme: pane.theme), row.findText.plainText, item.id)
        }
    }

    func testTheOffscreenCacheRendersOnceAndStaysBounded() {
        _ = NSApplication.shared
        let theme = AppTheme(systemIsDark: false)
        let cache = AgentConversationFindTextCache(capacity: 2)
        let items = (0..<3).map { AgentChatItem(id: "\($0)", kind: .assistant, text: "Item **\($0)**") }
        XCTAssertEqual(cache.text(for: items[0], theme: theme), "Item 0")
        XCTAssertEqual(cache.text(for: items[0], theme: theme), "Item 0")
        XCTAssertEqual(cache.renderCount, 1)
        _ = cache.text(for: items[1], theme: theme)
        _ = cache.text(for: items[2], theme: theme)
        XCTAssertEqual(cache.renderCount, 3)
        _ = cache.text(for: items[2], theme: theme)
        XCTAssertEqual(cache.renderCount, 3)
        _ = cache.text(for: items[0], theme: theme)
        XCTAssertEqual(cache.renderCount, 4, "The oldest render was dropped")
        var changed = items[2]
        changed.text = "Item changed"
        XCTAssertEqual(cache.text(for: changed, theme: theme), "Item changed")
        XCTAssertNil(cache.text(for: .init(id: "n", kind: .notice, text: "Notice"), theme: theme))
    }

    // MARK: Folded content

    func testAMatchInsideFoldedDetailsIsCountedAndOpensWhenSelected() throws {
        let pane = makePane([.init(id: "a", kind: .assistant, text: """
            Intro needle.

            <details>
            <summary>More</summary>

            The hidden needle.

            </details>
            """)])
        func details() -> AgentResponseContainer? {
            func find(_ view: NSView) -> AgentResponseContainer? {
                for child in view.subviews {
                    if let container = child as? AgentResponseContainer, !container.disclosure.isHidden { return container }
                    if let found = find(child) { return found }
                }
                return nil
            }
            return find(pane.transcript)
        }
        XCTAssertEqual(details()?.isCollapsed, true)
        pane.performFind(.open)
        type("needle", in: pane)
        XCTAssertEqual(pane.findBar?.counter, "1 of 2")
        XCTAssertEqual(details()?.isCollapsed, true, "A match outside the block leaves it folded")
        pane.performFind(.next)
        XCTAssertEqual(details()?.isCollapsed, false)
        let rect = try XCTUnwrap(pane.currentFindMatchRect())
        XCTAssertTrue(pane.findVisibleRect.contains(rect))
        XCTAssertEqual(painted(pane).flatMap(\.texts), ["needle", "needle"])
    }

    func testAMatchBelowTheFoldOfALongUserMessageExpandsIt() throws {
        let long = (1...14).map { "Line \($0) of a long prompt" }.joined(separator: "\n") + "\nThe needle is at the end"
        let pane = makePane([.init(id: "u", kind: .user, text: long), .init(id: "a", kind: .assistant, text: "Answer")])
        let row = try XCTUnwrap(pane.transcript.messageRow(for: "u"))
        XCTAssertFalse(row.captureState().expanded)
        pane.performFind(.open)
        type("line 1 of", in: pane)
        XCTAssertFalse(row.captureState().expanded, "A match above the fold leaves the message collapsed")
        type("needle", in: pane)
        XCTAssertEqual(pane.findBar?.counter, "1 of 1")
        XCTAssertTrue(row.captureState().expanded)
        let rect = try XCTUnwrap(pane.currentFindMatchRect())
        XCTAssertTrue(pane.findVisibleRect.contains(rect), "\(rect) in \(pane.findVisibleRect)")
    }

    // MARK: Scrolling cost

    func testScrollingWithoutNewRowsSearchesAndPaintsNothing() throws {
        var items = filler(40)
        items[38].text = "A needle near the end."
        let pane = makePane(items)
        var searches = 0
        pane.findHighlighter.search = { query, text in
            searches += 1
            return AgentConversationFindModel.ranges(of: query, in: text)
        }
        pane.performFind(.open)
        type("needle", in: pane)
        let paints = pane.findHighlighter.rowPaintCount
        XCTAssertGreaterThan(paints, 0)
        let paint = try XCTUnwrap(pane.transcript.onViewportSettled)
        var settled = 0
        pane.transcript.onViewportSettled = { settled += 1; paint() }
        let clip = pane.transcriptScroll.contentView
        for step in 1...4 {
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY - CGFloat(step)))
            pane.transcriptScroll.reflectScrolledClipView(clip)
        }
        XCTAssertGreaterThanOrEqual(settled, 4, "Each scroll settles the viewport and asks Find to paint")
        XCTAssertEqual(searches, 0)
        XCTAssertEqual(pane.findHighlighter.rowPaintCount, paints, "Rows already painted are not painted again")
        XCTAssertEqual(painted(pane).flatMap(\.texts), ["needle"])
    }

    func testRowFindTextIsCachedUntilTheRowChanges() throws {
        var items: [AgentChatItem] = [.init(id: "a", kind: .assistant, text: "Streaming", isComplete: false)]
        let pane = makePane(items)
        let row = try XCTUnwrap(pane.transcript.messageRow(for: "a"))
        let generation = row.findTextGeneration
        XCTAssertEqual(row.findText.plainText, "Streaming")
        let clip = pane.transcriptScroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY))
        pane.transcriptScroll.reflectScrolledClipView(clip)
        XCTAssertEqual(row.findTextGeneration, generation)
        items[0].text = "Streaming more"
        var next = makeSnapshot(items)
        next.revision = 2
        pane.render(next)
        XCTAssertNotEqual(row.findTextGeneration, generation)
        XCTAssertEqual(row.findText.plainText, "Streaming more")
    }

    func testFindDoesNoWorkWhileClosed() throws {
        let pane = makePane(filler(30))
        XCTAssertNil(pane.transcript.onViewportSettled)
        pane.scrollToEnd()
        XCTAssertEqual(pane.findTexts.renderCount, 0)
        XCTAssertEqual(pane.findHighlighter.rowPaintCount, 0)
        pane.performFind(.open)
        XCTAssertEqual(pane.findTexts.renderCount, 0, "An empty query renders nothing")
    }

    // MARK: Escape

    func testEscapeInTheTranscriptClosesTheBarAndFocusesTheComposer() throws {
        let pane = makePane([.init(id: "a", kind: .assistant, text: "A needle")])
        pane.performFind(.open)
        type("needle", in: pane)
        let text = try XCTUnwrap(pane.transcript.messageRow(for: "a")?.findText.segments.first?.view)
        pane.window?.makeFirstResponder(text)
        text.keyDown(with: try escape(pane.window))
        XCTAssertFalse(pane.isFindOpen)
        XCTAssertTrue(pane.findBar?.isHidden ?? false)
        XCTAssertTrue(pane.window?.firstResponder === pane.composer)
        XCTAssertTrue(painted(pane).isEmpty)
    }

    func testEscapeHidesTheSelectionToolbarBeforeClosingTheBar() throws {
        let pane = makePane([.init(id: "a", kind: .assistant, text: "A needle and some words")])
        pane.performFind(.open)
        type("needle", in: pane)
        let text = try XCTUnwrap(pane.transcript.messageRow(for: "a")?.findText.segments.first?.view)
        pane.window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 2, length: 6))
        pane.textSelectionDidEnd(in: text)
        XCTAssertFalse(pane.selectionToolbar.isHidden)
        text.keyDown(with: try escape(pane.window))
        XCTAssertTrue(pane.selectionToolbar.isHidden)
        XCTAssertTrue(pane.isFindOpen, "The first Escape only hides the toolbar")
        text.keyDown(with: try escape(pane.window))
        XCTAssertFalse(pane.isFindOpen)
    }

    func testEscapeOutsideATextViewClosesTheBar() throws {
        let pane = makePane([.init(id: "a", kind: .assistant, text: "A needle")])
        pane.performFind(.open)
        pane.window?.makeFirstResponder(pane.transcript)
        pane.transcript.keyDown(with: try escape(pane.window))
        XCTAssertFalse(pane.isFindOpen)
        XCTAssertTrue(pane.window?.firstResponder === pane.composer)
    }
}
