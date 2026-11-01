import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentCitationTests: XCTestCase {
    private let mixed = "Intro with **bold** words.\n\n```swift\nlet answer = 42\n```\n\n| Name | Value |\n| --- | ---: |\n| **Alpha** | 12 |\n| Beta | 34 |\n\nClosing [docs](https://example.com/docs) line."

    private struct NotRendered: Error {
        let text: String
        let message: String
    }

    @MainActor
    private struct Fixture {
        let pane: AgentPaneView
        let window: NSWindow
        let project: ProjectId
        let session: SessionId
        let board: NSPasteboard

        func row(_ id: String) throws -> AgentMessageRow { try XCTUnwrap(pane.transcript.messageRow(for: id)) }

        func select(_ text: String, in id: String, occurrence: Int = 0) throws -> (view: AgentRichTextView, range: NSRange) {
            for segment in try row(id).textMap.segments {
                let string = segment.view.string as NSString
                var offset = 0, seen = 0
                while true {
                    let found = string.range(of: text, options: [], range: NSRange(location: offset, length: string.length - offset))
                    if found.location == NSNotFound { break }
                    if seen == occurrence {
                        segment.view.setSelectedRange(found)
                        return (segment.view, found)
                    }
                    seen += 1
                    offset = found.location + 1
                }
            }
            throw NotRendered(text: text, message: id)
        }

        func close() {
            board.releaseGlobally()
            window.close()
        }
    }

    private func makePane(_ items: [AgentChatItem]) -> Fixture {
        _ = NSApplication.shared
        let project = ProjectId(), session = SessionId()
        let pane = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 680, height: 700))
        pane.citationEnvironmentId = project.description
        pane.citationThreadId = session.description
        let board = NSPasteboard.withUniqueName()
        pane.actions.pasteboard = board
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        pane.frame = NSRect(x: 0, y: 0, width: 680, height: 700)
        pane.render(AgentChatSnapshot(session: session, project: project, provider: .codex, status: .idle, items: items))
        pane.layoutSubtreeIfNeeded()
        return Fixture(pane: pane, window: window, project: project, session: session, board: board)
    }

    private func answer(_ id: String, _ text: String) -> AgentChatItem {
        AgentChatItem(id: id, kind: .assistant, text: text, isComplete: true)
    }

    private func response(_ markdown: String) -> AgentResponseView {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        response.parseRawHTML = true
        response.setContent(markdown, theme: AppTheme(systemIsDark: false))
        _ = response.height(for: 600)
        return response
    }

    private func composerCitation(_ pane: AgentPaneView) throws -> AgentAssistantCitation {
        let storage = try XCTUnwrap(pane.composer.textStorage)
        var href: String?
        storage.enumerateAttribute(.agentAssistantCitation, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if let value = value as? String { href = value; stop.pointee = true }
        }
        return try XCTUnwrap(AgentAssistantCitation.parse(try XCTUnwrap(href)))
    }

    // MARK: Selection to plain-text offsets

    func testProseSelectionMapsToPlainTextOffsets() throws {
        let map = AgentMessageTextMap(views: response(mixed).textViews)
        let prose = try XCTUnwrap(map.segments.first)
        let range = (prose.view.string as NSString).range(of: "bold words")
        let plain = try XCTUnwrap(map.plainRange(of: range, in: prose.view))
        XCTAssertEqual(prose.offset, 0)
        XCTAssertEqual((map.plainText as NSString).substring(with: plain), "bold words")
        XCTAssertTrue(map.plainText.hasPrefix("Intro with bold words."))
    }

    func testCodeSectionFollowsProseAfterABlankLine() throws {
        let map = AgentMessageTextMap(views: response(mixed).textViews)
        XCTAssertEqual(map.segments.count, 4, "prose, code, table and closing prose")
        let code = map.segments[1]
        XCTAssertTrue(code.view.string.hasPrefix("let answer = 42"))
        XCTAssertEqual(code.offset, map.segments[0].length + 2)
        let range = (code.view.string as NSString).range(of: "answer = 42")
        let plain = try XCTUnwrap(map.plainRange(of: range, in: code.view))
        XCTAssertEqual((map.plainText as NSString).substring(with: plain), "answer = 42")
        XCTAssertEqual((map.plainText as NSString).substring(with: NSRange(location: code.offset - 2, length: 2)), "\n\n")
    }

    func testTableSelectionMapsCellsInReadingOrder() throws {
        let map = AgentMessageTextMap(views: response(mixed).textViews)
        let table = map.segments[2]
        let text = table.view.string as NSString
        let start = text.range(of: "Alpha").location
        let range = NSRange(location: start, length: NSMaxRange(text.range(of: "34")) - start)
        let plain = try XCTUnwrap(map.plainRange(of: range, in: table.view))
        XCTAssertEqual((map.plainText as NSString).substring(with: plain), "Alpha\n12\nBeta\n34")
        XCTAssertNil(map.plainRange(of: NSRange(location: 0, length: text.length + 1), in: table.view))
        XCTAssertNil(map.plainRange(of: range, in: AgentRichTextView(frame: .zero)), "A view of another message has no offsets here")
    }

    func testPlainRangeSplitsAcrossSections() throws {
        let map = AgentMessageTextMap(views: response(mixed).textViews)
        let text = map.plainText as NSString
        let start = text.range(of: "words.").location
        let range = NSRange(location: start, length: NSMaxRange(text.range(of: "let answer")) - start)
        let parts = map.viewRanges(for: range)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].view === map.segments[0].view)
        XCTAssertEqual((parts[0].view.string as NSString).substring(with: parts[0].range), "words.")
        XCTAssertTrue(parts[1].view === map.segments[1].view)
        XCTAssertEqual((parts[1].view.string as NSString).substring(with: parts[1].range), "let answer")
    }

    func testSelectorRangesMapBackToThePlainTextAcrossBlankLines() throws {
        let source = "First block.\n\n  Second   block\n\nThird"
        let range = (source as NSString).range(of: "block.\n\n  Second")
        let citation = try XCTUnwrap(AgentConversationSelectionSelector.citation(in: source, range: range, environmentId: "e", threadId: "t", messageId: "m"))
        XCTAssertEqual(citation.start, 6, "Citations keep the browser's normalized offsets")
        XCTAssertEqual(AgentConversationSelectionSelector.findInSource(citation, in: source), range)
        let later = (source as NSString).range(of: "Third")
        let third = try XCTUnwrap(AgentConversationSelectionSelector.citation(in: source, range: later, environmentId: "e", threadId: "t", messageId: "m"))
        XCTAssertEqual(AgentConversationSelectionSelector.findInSource(third, in: source), later)
    }

    func testNestedContainersKeepReadingOrder() throws {
        let map = AgentMessageTextMap(views: response("Before\n\n> Quoted *line*\n\n- first item\n- second item\n\nAfter").textViews)
        let text = map.plainText as NSString
        let positions = ["Before", "Quoted line", "first item", "second item", "After"].map { text.range(of: $0).location }
        XCTAssertFalse(positions.contains(NSNotFound), map.plainText)
        XCTAssertEqual(positions, positions.sorted())
    }

    func testOffscreenRenderMatchesTheMountedRow() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        XCTAssertEqual(try fixture.row("a1").textMap.plainText, AgentMessageTextMap.render(mixed, theme: fixture.pane.theme).plainText)
    }

    // MARK: Cite

    func testCiteInsertsAChipWhoseHrefRoundTrips() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        _ = try fixture.select("bold words", in: "a1")
        XCTAssertTrue(fixture.pane.citeSelection())
        let citation = try composerCitation(fixture.pane)
        XCTAssertEqual(citation.environmentId, fixture.project.description)
        XCTAssertEqual(citation.threadId, fixture.session.description)
        XCTAssertEqual(citation.messageId, "a1")
        XCTAssertEqual(citation.text, "bold words")
        XCTAssertEqual(AgentAssistantCitation.parse(citation.href), citation)
        let plain = try fixture.row("a1").textMap.plainText as NSString
        XCTAssertEqual(AgentConversationSelectionSelector.find(citation, in: plain as String).map { plain.substring(with: $0) }, "bold words")
        XCTAssertTrue(AgentComposerCitation.prompt(from: fixture.pane.composer.attributedString()).contains(citation.markdown))
    }

    func testCiteAcrossSectionsOfOneMessageCitesTheSpan() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        _ = try fixture.select("words.", in: "a1")
        _ = try fixture.select("let answer", in: "a1")
        let selection = AgentTranscriptSelection.collect(in: fixture.pane.transcript)
        XCTAssertNotNil(selection.citable)
        XCTAssertTrue(fixture.pane.citeSelection())
        XCTAssertEqual(try composerCitation(fixture.pane).text, "words.\n\nlet answer")
    }

    func testCiteIsDisabledAcrossMessages() throws {
        let fixture = makePane([answer("a1", "First answer text."), answer("a2", "Second answer text.")])
        defer { fixture.close() }
        let first = try fixture.select("First", in: "a1")
        _ = try fixture.select("Second", in: "a2")
        let selection = AgentTranscriptSelection.collect(in: fixture.pane.transcript)
        XCTAssertEqual(selection.messages.map(\.item.id), ["a1", "a2"])
        XCTAssertNil(selection.citable)
        XCTAssertFalse(fixture.pane.citeSelection())
        XCTAssertEqual(fixture.pane.composer.string, "")
        let items = fixture.pane.textSelectionMenuItems(for: first.view)
        XCTAssertEqual(items.map(\.title), ["Cite", "Copy", "Copy as Markdown"])
        XCTAssertEqual(items.first?.isEnabled, false)
        fixture.pane.showSelectionToolbar(for: first.view)
        XCTAssertFalse(fixture.pane.selectionToolbar.isHidden)
        XCTAssertFalse(fixture.pane.selectionToolbar.cite.isEnabled)
    }

    func testUserMessagesOfferNoSelectionActions() throws {
        let fixture = makePane([AgentChatItem(id: "u1", kind: .user, text: "My question here", isComplete: true), answer("a1", "Reply.")])
        defer { fixture.close() }
        let row = try XCTUnwrap(fixture.pane.transcript.messageRow(for: "u1"))
        let text = try XCTUnwrap(AgentTranscriptSelection.textViews(in: row).first { $0.string.contains("My question") })
        text.setSelectedRange(NSRange(location: 0, length: 2))
        XCTAssertTrue(fixture.pane.textSelectionMenuItems(for: text).isEmpty)
        XCTAssertFalse(fixture.pane.copyTextSelection(from: text))
        fixture.pane.textSelectionDidEnd(in: text)
        XCTAssertTrue(fixture.pane.selectionToolbar.isHidden)
    }

    func testContextMenuOffersCiteCopyAndMarkdownOnce() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        let (view, range) = try fixture.select("bold words", in: "a1")
        let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        let glyphs = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        let point = view.convert(NSPoint(x: glyphs.midX + view.textContainerOrigin.x, y: glyphs.midY + view.textContainerOrigin.y), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                     windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(view.menu(for: event))
        XCTAssertEqual(Array(menu.items.prefix(3).map(\.title)), ["Cite", "Copy", "Copy as Markdown"])
        XCTAssertEqual(menu.items.filter { $0.title == "Copy" }.count, 1)
        XCTAssertEqual(view.selectedRange(), range)
    }

    // MARK: Copy

    func testCopyWritesPlainHTMLAndContextFragment() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        _ = try fixture.select("bold words", in: "a1")
        XCTAssertTrue(fixture.pane.copySelection())
        XCTAssertEqual(fixture.board.pasteboardItems?.count, 1)
        XCTAssertEqual(fixture.board.string(forType: .string), "bold words")
        let html = try XCTUnwrap(fixture.board.string(forType: .html))
        XCTAssertTrue(html.contains("bold"), html)
        XCTAssertTrue(html.lowercased().contains("<html") || html.lowercased().contains("<span"), html)
        let fragment = try XCTUnwrap(AgentContextFragment.read(from: fixture.board))
        XCTAssertEqual(fragment, AgentContextFragment(environmentId: fixture.project.description, threadId: fixture.session.description,
                                                      messageId: "a1", text: "bold words"))
        XCTAssertEqual(fragment.version, 1)
    }

    func testCommandCopyFromATranscriptViewUsesTheTranscriptFlavors() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        let restore = preserveAgentTestClipboard()
        defer { restore() }
        let (view, _) = try fixture.select("answer = 42", in: "a1")
        view.copy(nil)
        XCTAssertEqual(fixture.board.string(forType: .string), "answer = 42")
        XCTAssertNotNil(AgentContextFragment.read(from: fixture.board))
    }

    func testCopyAcrossMessagesOmitsTheContextFragment() throws {
        let fixture = makePane([answer("a1", "First answer text."), answer("a2", "Second answer text.")])
        defer { fixture.close() }
        _ = try fixture.select("First", in: "a1")
        _ = try fixture.select("Second", in: "a2")
        XCTAssertTrue(fixture.pane.copySelection())
        XCTAssertEqual(fixture.board.string(forType: .string), "First\n\nSecond")
        XCTAssertNil(AgentContextFragment.read(from: fixture.board))
    }

    func testCopyAsMarkdownKeepsBoldAndLinks() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        _ = try fixture.select("bold words", in: "a1")
        XCTAssertTrue(fixture.pane.copySelectionAsMarkdown())
        XCTAssertEqual(fixture.board.string(forType: .string), "**bold** words")
        XCTAssertEqual(fixture.board.string(forType: try AgentConversationClipboard.pasteboardType(forMIME: "web text/markdown")), "**bold** words")
        _ = try fixture.select("Closing docs", in: "a1")
        let map = try fixture.row("a1").textMap
        let range = (map.plainText as NSString).range(of: "Closing docs")
        XCTAssertEqual(AgentMarkdownSelectionSlice.slice(markdown: mixed, plainText: map.plainText, range: range),
                       "Closing [docs](https://example.com/docs)")
        let docs = (map.plainText as NSString).range(of: "docs")
        XCTAssertEqual(AgentMarkdownSelectionSlice.slice(markdown: mixed, plainText: map.plainText, range: docs), "[docs](https://example.com/docs)")
    }

    func testMarkdownSliceOfAHugeMessageWithUnmatchedDestinationsIsLinear() {
        let markdown = String(repeating: "x ](y ", count: 33_000)
        let plain = String(repeating: "x y ", count: 33_000)
        let started = Date()
        _ = AgentMarkdownSelectionSlice.slice(markdown: markdown, plainText: plain, range: NSRange(location: 60_000, length: 3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Unmatched destinations must not rescan the message per occurrence")
    }

    func testMarkdownSliceOfCodeAndTableCells() throws {
        let map = AgentMessageTextMap(views: response(mixed).textViews)
        let text = map.plainText as NSString
        XCTAssertEqual(AgentMarkdownSelectionSlice.slice(markdown: mixed, plainText: map.plainText, range: text.range(of: "answer = 42")), "answer = 42")
        let start = text.range(of: "Alpha").location
        let cells = NSRange(location: start, length: NSMaxRange(text.range(of: "12")) - start)
        XCTAssertEqual(AgentMarkdownSelectionSlice.slice(markdown: mixed, plainText: map.plainText, range: cells), "**Alpha** | 12")
    }

    func testMarkdownSliceChoosesTheSelectedOccurrence() throws {
        let markdown = "one **two** three\n\none two three"
        let map = AgentMessageTextMap(views: response(markdown).textViews)
        let text = map.plainText as NSString
        let first = text.range(of: "two")
        let second = text.range(of: "two", options: .backwards)
        XCTAssertNotEqual(first.location, second.location)
        XCTAssertEqual(AgentMarkdownSelectionSlice.slice(markdown: markdown, plainText: map.plainText, range: first), "**two**")
        XCTAssertEqual(AgentMarkdownSelectionSlice.slice(markdown: markdown, plainText: map.plainText, range: second), "two")
        XCTAssertEqual(AgentMarkdownSelectionSlice.slice(markdown: markdown, plainText: map.plainText, range: NSRange(location: 0, length: text.length)), markdown)
    }

    func testPastingACopiedFragmentInsertsAQuotation() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        _ = try fixture.select("bold words", in: "a1")
        XCTAssertTrue(fixture.pane.copySelection())
        XCTAssertTrue(fixture.pane.pasteContextFragment(from: fixture.board))
        XCTAssertEqual(try composerCitation(fixture.pane).text, "bold words")
        fixture.board.clearContents()
        fixture.board.setString("bold words", forType: .string)
        XCTAssertFalse(fixture.pane.pasteContextFragment(from: fixture.board), "Plain text is pasted as text")
    }

    // MARK: Following a citation

    func testRevealCitationHighlightsTheQuotedRangeAndClearsIt() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        let (view, range) = try fixture.select("bold words", in: "a1")
        let citation = try XCTUnwrap(fixture.pane.citation(for: AgentTranscriptSelection.collect(in: fixture.pane.transcript)))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(fixture.pane.revealCitation(citation))
        XCTAssertEqual(fixture.pane.citationHighlight.count, 1)
        XCTAssertTrue(fixture.pane.citationHighlight.first?.view === view)
        XCTAssertEqual(fixture.pane.citationHighlight.first?.range, range)
        let layout = try XCTUnwrap(view.layoutManager)
        XCTAssertNotNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))
        XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: NSMaxRange(range), effectiveRange: nil))
        fixture.pane.clearCitationHighlight()
        XCTAssertTrue(fixture.pane.citationHighlight.isEmpty)
        XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))
    }

    func testRevealHighlightsEverySectionOfASpanningQuote() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        _ = try fixture.select("words.", in: "a1")
        _ = try fixture.select("let answer", in: "a1")
        let citation = try XCTUnwrap(fixture.pane.citation(for: AgentTranscriptSelection.collect(in: fixture.pane.transcript)))
        XCTAssertTrue(fixture.pane.revealCitation(citation))
        XCTAssertEqual(fixture.pane.citationHighlight.map { ($0.view.string as NSString).substring(with: $0.range) }, ["words.", "let answer"])
        fixture.pane.clearCitationHighlight()
    }

    func testHighlightFadesAwayOnItsOwn() async throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        _ = try fixture.select("bold words", in: "a1")
        let citation = try XCTUnwrap(fixture.pane.citation(for: AgentTranscriptSelection.collect(in: fixture.pane.transcript)))
        XCTAssertTrue(fixture.pane.revealCitation(citation))
        XCTAssertFalse(fixture.pane.citationHighlight.isEmpty)
        try await Task.sleep(for: .seconds(AgentPaneView.citationHighlightDuration + 0.3))
        XCTAssertTrue(fixture.pane.citationHighlight.isEmpty)
    }

    func testANewHighlightReplacesThePreviousOne() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        let first = try fixture.select("bold words", in: "a1")
        let firstCitation = try XCTUnwrap(fixture.pane.citation(for: AgentTranscriptSelection.collect(in: fixture.pane.transcript)))
        first.view.setSelectedRange(NSRange(location: 0, length: 0))
        _ = try fixture.select("answer = 42", in: "a1")
        let secondCitation = try XCTUnwrap(fixture.pane.citation(for: AgentTranscriptSelection.collect(in: fixture.pane.transcript)))
        XCTAssertTrue(fixture.pane.revealCitation(firstCitation))
        let generation = fixture.pane.citationHighlightGeneration
        XCTAssertTrue(fixture.pane.revealCitation(secondCitation))
        XCTAssertNotEqual(fixture.pane.citationHighlightGeneration, generation, "The first highlight's pending fade is cancelled")
        XCTAssertEqual(fixture.pane.citationHighlight.map { ($0.view.string as NSString).substring(with: $0.range) }, ["answer = 42"])
        XCTAssertNil(first.view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: first.range.location, effectiveRange: nil))
        fixture.pane.clearCitationHighlight()
    }

    func testUnfoundQuoteScrollsWithoutHighlightAndUnretainedMessageIsUnavailable() throws {
        let filler = (0..<30).map { answer("filler-\($0)", "Filler answer \($0)\n\nwith a second paragraph.") }
        let fixture = makePane([answer("a1", mixed)] + filler)
        defer { fixture.close() }
        let clip = fixture.pane.transcriptScroll.contentView
        XCTAssertGreaterThan(clip.bounds.minY, 0)
        let missing = AgentAssistantCitation(environmentId: fixture.project.description, threadId: fixture.session.description,
                                             messageId: "a1", text: "Not in this message", start: 0, end: 19, prefix: "", suffix: "")
        XCTAssertFalse(fixture.pane.revealCitation(missing))
        XCTAssertLessThan(clip.bounds.minY, 40, "The cited message is shown even when its quote changed")
        XCTAssertTrue(fixture.pane.citationHighlight.isEmpty)
        var gone = missing
        gone.messageId = "gone"
        XCTAssertFalse(fixture.pane.revealCitation(gone))
        var errors: [String] = []
        fixture.pane.onActionError = { errors.append($0) }
        fixture.pane.openCitation(missing)
        XCTAssertEqual(errors, ["The quoted text could not be located in this conversation."])
    }

    func testCitationLinksInMessagesAskToOpenTheCitation() throws {
        let citation = AgentAssistantCitation(environmentId: "project", threadId: "thread", messageId: "answer", text: "Quoted", start: 0, end: 6, prefix: "", suffix: "")
        let view = response("See " + citation.markdown)
        var opened: [AgentAssistantCitation] = []
        view.onOpenCitation = { opened.append($0) }
        XCTAssertTrue(view.textView(AgentRichTextView(frame: .zero), clickedOnLink: citation.href, at: 0))
        XCTAssertEqual(opened, [citation])
    }

    // MARK: Toolbar

    func testToolbarShowsAboveTheSelectionAndHidesOnEscape() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        let (view, range) = try fixture.select("bold words", in: "a1")
        fixture.pane.textSelectionDidEnd(in: view)
        let toolbar = fixture.pane.selectionToolbar
        XCTAssertFalse(toolbar.isHidden)
        XCTAssertTrue(toolbar.cite.isEnabled)
        XCTAssertTrue(toolbar.source === view)
        let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        let selected = fixture.pane.convert(manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container), from: view)
        XCTAssertTrue(toolbar.frame.maxY <= selected.minY || toolbar.frame.minY >= selected.maxY, "The toolbar does not cover the selection")
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber,
                                                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        XCTAssertTrue(toolbar.isHidden)
        XCTAssertEqual(view.selectedRange(), range, "Escape dismisses the toolbar, not the selection")
    }

    func testToolbarHidesOnScrollAndWhenTheSelectionCollapses() throws {
        let filler = (0..<20).map { answer("filler-\($0)", "Filler answer \($0)\n\nwith a second paragraph.") }
        let fixture = makePane(filler + [answer("a1", mixed)])
        defer { fixture.close() }
        let (view, _) = try fixture.select("bold words", in: "a1")
        fixture.pane.textSelectionDidEnd(in: view)
        XCTAssertFalse(fixture.pane.selectionToolbar.isHidden)
        let clip = fixture.pane.transcriptScroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.minY - 30)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(fixture.pane.selectionToolbar.isHidden)

        fixture.pane.textSelectionDidEnd(in: view)
        XCTAssertFalse(fixture.pane.selectionToolbar.isHidden)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(fixture.pane.selectionToolbar.isHidden)
    }

    func testStartingANewSelectionClearsOtherSelections() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        let prose = try fixture.select("bold words", in: "a1")
        let code = try fixture.select("answer", in: "a1")
        fixture.pane.textSelectionWillBegin(in: code.view, extending: true)
        XCTAssertEqual(prose.view.selectedRange().length, prose.range.length, "Shift or Command keeps the other section")
        fixture.pane.textSelectionWillBegin(in: code.view, extending: false)
        XCTAssertEqual(prose.view.selectedRange().length, 0)
        XCTAssertEqual(code.view.selectedRange(), code.range)
    }

    // MARK: Citations beside Find

    private func findQuery(_ query: String, in pane: AgentPaneView) throws {
        pane.performFind(.open)
        let bar = try XCTUnwrap(pane.findBar)
        bar.query = query
        bar.findBar(bar.bar, didChangeQuery: query)
    }

    func testACitationHighlightSurvivesFindPaintingAndClosing() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        let (view, range) = try fixture.select("bold words", in: "a1")
        let citation = try XCTUnwrap(fixture.pane.citation(for: AgentTranscriptSelection.collect(in: fixture.pane.transcript)))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(fixture.pane.revealCitation(citation))
        let layout = try XCTUnwrap(view.layoutManager)
        try findQuery("bold", in: fixture.pane)
        XCTAssertNotNil(layout.temporaryAttribute(.agentFindHighlight, atCharacterIndex: range.location, effectiveRange: nil))
        XCTAssertNotNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil),
                        "Painting Find keeps the citation")
        try findQuery("words", in: fixture.pane)
        XCTAssertNotNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil),
                        "Erasing Find's previous matches keeps the citation")
        fixture.pane.performFind(.close)
        XCTAssertNil(layout.temporaryAttribute(.agentFindHighlight, atCharacterIndex: range.location + 5, effectiveRange: nil))
        XCTAssertNotNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil),
                        "Closing Find keeps the citation")
        fixture.pane.clearCitationHighlight()
    }

    func testFindHighlightsSurviveACitationHighlightAndItsClearing() throws {
        let fixture = makePane([answer("a1", mixed)])
        defer { fixture.close() }
        try findQuery("bold", in: fixture.pane)
        let (view, range) = try fixture.select("bold words", in: "a1")
        let citation = try XCTUnwrap(fixture.pane.citation(for: AgentTranscriptSelection.collect(in: fixture.pane.transcript)))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let layout = try XCTUnwrap(view.layoutManager)
        XCTAssertNotNil(layout.temporaryAttribute(.agentFindHighlight, atCharacterIndex: range.location, effectiveRange: nil))
        XCTAssertTrue(fixture.pane.revealCitation(citation))
        XCTAssertNotNil(layout.temporaryAttribute(.agentFindHighlight, atCharacterIndex: range.location, effectiveRange: nil),
                        "The citation does not erase Find's match")
        fixture.pane.clearCitationHighlight()
        XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil))
        XCTAssertNotNil(layout.temporaryAttribute(.agentFindHighlight, atCharacterIndex: range.location, effectiveRange: nil),
                        "Clearing the citation keeps Find's match")
        fixture.pane.performFind(.close)
    }

    // MARK: Citation links in cards

    private func citationLink(in row: NSView, opens citation: AgentAssistantCitation) throws -> Bool {
        func response(in view: NSView) -> AgentResponseView? {
            for child in view.subviews {
                if let response = child as? AgentResponseView, !response.isHidden { return response }
                if let found = response(in: child) { return found }
            }
            return nil
        }
        let body = try XCTUnwrap(response(in: row))
        return body.textView(AgentRichTextView(frame: .zero), clickedOnLink: citation.href, at: 0)
    }

    func testCitationLinksInAPlanCardOpenTheCitation() throws {
        _ = NSApplication.shared
        let citation = AgentAssistantCitation(environmentId: "project", threadId: "thread", messageId: "answer", text: "Quoted", start: 0, end: 6, prefix: "", suffix: "")
        let row = AgentPlanCardRow()
        row.theme = AppTheme(systemIsDark: false)
        row.update([AgentChatItem(id: "plan", kind: .tool, text: "Proposed plan", detail: "Follow " + citation.markdown,
                                  workContext: .init(itemType: "proposed_plan", sourceStatus: "completed", planStatus: "active"))])
        var opened: [AgentAssistantCitation] = []
        row.onOpenCitation = { opened.append($0) }
        XCTAssertTrue(try citationLink(in: row, opens: citation))
        XCTAssertEqual(opened, [citation])
    }

    func testCitationLinksInACompactionSummaryOpenTheCitation() throws {
        _ = NSApplication.shared
        let citation = AgentAssistantCitation(environmentId: "project", threadId: "thread", messageId: "answer", text: "Quoted", start: 0, end: 6, prefix: "", suffix: "")
        let row = AgentCompactionRow()
        row.theme = AppTheme(systemIsDark: false)
        row.update([AgentChatItem(id: "compact", kind: .tool, text: "Compacted", detail: "Summary " + citation.markdown,
                                  workContext: .init(itemType: "context_compaction", sourceStatus: "completed"))])
        row.restoreState(AgentTimelineRowState(expanded: true))
        var opened: [AgentAssistantCitation] = []
        row.onOpenCitation = { opened.append($0) }
        XCTAssertTrue(try citationLink(in: row, opens: citation))
        XCTAssertEqual(opened, [citation])
    }
}
