import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentRenderingTests: XCTestCase {
    func testInlineMemberNamesAreNotMistakenForFiles() {
        let text = AgentMarkdown.inline("`NSColor.labelColor` and `NSLayoutConstraint.activate` beside `Example.swift:4` and [custom](data.custom)",
                                        theme: AppTheme(systemIsDark: true), fileLinks: true)
        let source = text.string as NSString
        for symbol in ["NSColor.labelColor", "NSLayoutConstraint.activate"] {
            XCTAssertNil(text.attribute(.link, at: source.range(of: symbol).location, effectiveRange: nil))
        }
        for file in ["Example.swift:4", "custom"] {
            XCTAssertNotNil(text.attribute(.link, at: source.range(of: file).location, effectiveRange: nil))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    func testMarkdownPreservesReadableStructureAndNativeInlineAttributes() throws {
        _ = NSApplication.shared
        let theme = AppTheme(systemIsDark: true)
        let rendered = AgentMarkdown.render("""
        # A native conversation

        Use **AppKit**, *carefully*, with `TextKit` and [documentation](https://developer.apple.com).

        - Keep the composer fixed
        - Preserve the draft

        1. Read the source
        2. Run the tests

        ```swift
        let ready = true
        ```
        """, theme: theme)
        let string = rendered.string as NSString
        XCTAssertFalse(rendered.string.contains("**"))
        XCTAssertFalse(rendered.string.contains("```"))
        XCTAssertTrue(rendered.string.contains("•\tKeep the composer fixed"))
        XCTAssertTrue(rendered.string.contains("1.\tRead the source"))
        let strong = try XCTUnwrap(rendered.attribute(.font, at: string.range(of: "AppKit").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: strong).contains(.boldFontMask))
        let heading = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(heading.pointSize, 14)
        XCTAssertEqual(rendered.attribute(.link, at: string.range(of: "documentation").location, effectiveRange: nil) as? URL,
                       URL(string: "https://developer.apple.com"))
        let code = try XCTUnwrap(rendered.attribute(.font, at: string.range(of: "let ready").location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(code, AppFont.mono(12))
    }

    func testMarkdownStreamingFenceAndUnsafeLinksRemainNonExecutable() {
        XCTAssertEqual(AgentMarkdown.blocks("Intro\n\n```swift\nlet value = 1"), [
            .paragraph("Intro"), .code("swift", "let value = 1\n", closed: false),
        ])
        let rendered = AgentMarkdown.render("[Not a command](javascript:alert) and [Not a file opener](file:///etc/hosts)",
                                            theme: AppTheme(systemIsDark: false))
        var links = 0
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if value != nil { links += 1 }
        }
        XCTAssertEqual(links, 0)
    }

    private func surface(width: CGFloat = 1000, height: CGFloat = 800) -> AgentPaneView {
        _ = NSApplication.shared
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        surface.model.addItems(withTitles: ["Claude Sonnet", "Codex"])
        surface.effort.addItems(withTitles: ["High", "Medium", "Low"])
        surface.retry.isHidden = true
        surface.layoutSubtreeIfNeeded()
        return surface
    }

    func testCenteredColumnsAndResponsiveUserBubbleWithoutRoleCards() throws {
        let surface = surface()
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, items: [
            AgentChatItem(id: "user", kind: .user, text: "Please preserve the composer draft."),
            AgentChatItem(id: "assistant", kind: .assistant, text: "## Plan\n\nUse **native** text and preserve the current scroll position."),
            AgentChatItem(id: "tool-one", kind: .tool, text: "Read Metrics.swift"),
            AgentChatItem(id: "tool-two", kind: .tool, text: "Read AppTheme.swift"),
        ])
        surface.render(snapshot)
        let document = try XCTUnwrap(surface.transcriptScroll.documentView)
        let rows = document.subviews.compactMap { $0 as? AgentTimelineRow }
        XCTAssertEqual(rows.count, 4, "Each tool call is a separately virtualized timeline row")
        for row in rows {
            XCTAssertLessThanOrEqual(row.frame.width, AgentPaneView.readableWidth)
            XCTAssertEqual(row.frame.minX, rows[0].frame.minX, accuracy: 1)
            if row !== rows[0] {
                XCTAssertEqual(row.frame.width, AgentMessageRow.responseWidth(rows[0].frame.width))
            }
        }
        XCTAssertEqual(rows[0].frame.midX, document.bounds.midX, accuracy: 1)
        let user = try XCTUnwrap(rows.first)
        let userResponse = try XCTUnwrap(user.subviews.compactMap { $0 as? AgentResponseView }.first)
        let userText = try XCTUnwrap(descendants(userResponse).compactMap { $0 as? AgentRichTextView }.first)
        XCTAssertEqual(userText.string, "Please preserve the composer draft.")
        XCTAssertGreaterThan(userText.frame.height, 14, "Rendered text needs a real TextKit storage and layout stack")
        let answer = try XCTUnwrap(rows[1].subviews.compactMap { $0 as? AgentResponseView }.first)
        let answerText = descendants(answer).compactMap { $0 as? AgentRichTextView }.map(\.string).joined(separator: "\n")
        XCTAssertTrue(answerText.contains("Use native text"))
        XCTAssertGreaterThan(answer.frame.height, 40)
        let bubble = try XCTUnwrap(user.subviews.first { $0 is ThemedBackground })
        XCTAssertLessThanOrEqual(bubble.frame.width, user.bounds.width * 0.85 + 1)
        XCTAssertEqual(bubble.frame.maxX, user.bounds.maxX, accuracy: 1)
        let composerParent = try XCTUnwrap(surface.composerScroll.superview)
        XCTAssertLessThanOrEqual(composerParent.frame.width, AgentPaneView.readableWidth)
        XCTAssertEqual(composerParent.frame.midX, surface.bounds.midX, accuracy: 1)

        surface.contextIndicator.update(usedTokens: 120_000, contextWindow: 200_000)
        surface.setActivity(status: .working, submitting: false)
        surface.frame.size.width = 360
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        XCTAssertFalse(surface.stop.isHidden)
        XCTAssertTrue(surface.send.isHidden, "Send and Stop share one slot")
        XCTAssertEqual(surface.send.frame, surface.stop.frame)
        XCTAssertFalse(surface.contextIndicator.isHidden)
        XCTAssertFalse(surface.contextIndicator.frame.intersects(surface.stop.frame))
        XCTAssertFalse(surface.modelPicker.frame.intersects(surface.stop.frame))
        XCTAssertLessThanOrEqual(surface.send.frame.maxX, composerParent.bounds.maxX)
    }

    func testStreamingRetainsRowsAndDoesNotScrollAwayFromReadingPosition() throws {
        let surface = surface(width: 680)
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, items: (0..<60).map {
            AgentChatItem(id: "message-\($0)", kind: .assistant,
                          text: "Message \($0)\n\nA second paragraph with **native formatting**.")
        })
        surface.render(snapshot)
        let document = try XCTUnwrap(surface.transcriptScroll.documentView)
        surface.transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        surface.transcriptScroll.reflectScrolledClipView(surface.transcriptScroll.contentView)
        // Identity is retained for the viewport being read; distant rows are
        // deliberately unmounted and eventually evicted by virtualization.
        let firstRow = try XCTUnwrap(document.subviews.first { $0 is AgentTimelineRow })
        let readingPosition = surface.transcriptScroll.contentView.bounds.origin.y
        snapshot.items[snapshot.items.count - 1].text += " More streaming output."
        surface.render(snapshot)
        XCTAssertTrue(firstRow === document.subviews.first { $0 is AgentTimelineRow })
        XCTAssertEqual(surface.transcriptScroll.contentView.bounds.origin.y, readingPosition, accuracy: 1)
        XCTAssertFalse(surface.isAtBottom)
        let endButton = try XCTUnwrap(surface.subviews.first { $0 is AgentEndButton })
        XCTAssertFalse(endButton.isHidden)
    }

    func testNestedListsTaskListsQuotesAndMultilineItemsAreStructured() {
        let parsed = AgentMarkdown.blocks("""
        - outer
          - nested
            3. deep
              continuation

        - [x] done

        > quoted text
        > - quoted child

        Setext title
        ---
        """)
        XCTAssertTrue(parsed.contains { if case .list("•", "outer", 0, _) = $0 { return true }; return false })
        XCTAssertTrue(parsed.contains { if case .list("◦", "nested\n3. deep\ncontinuation", 1, _) = $0 { return true }; return false })
        XCTAssertTrue(parsed.contains { if case .list("☑", "done", 0, _) = $0 { return true }; return false })
        XCTAssertTrue(parsed.contains(.quote("quoted text\n- quoted child")))
        XCTAssertTrue(parsed.contains(.heading(2, "Setext title")))
    }

    func testTablesKeepEscapedAndCodePipesAndOfferLosslessCSV() throws {
        let parsed = AgentMarkdown.blocks("""
        | Name | Value |
        | :--- | ---: |
        | `a\\|b` | [source](Sources/App.swift:19) |
        | escaped\\|pipe | **bold** |
        """)
        guard case .table(let headers, let rows, let alignments) = try XCTUnwrap(parsed.first) else {
            return XCTFail("Expected a structured table")
        }
        XCTAssertEqual(headers, ["Name", "Value"])
        XCTAssertEqual(rows[0][0], "`a|b`")
        XCTAssertEqual(rows[1][0], "escaped|pipe")
        XCTAssertEqual(alignments, [.left, .right])
        let response = AgentResponseView(frame: .zero)
        response.setContent("| Name | Value |\n| --- | --- |\n| text | \"quoted\" |", theme: AppTheme(systemIsDark: false))
        _ = response.height(for: 180)
        let table = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseTable }.first)
        XCTAssertEqual(table.copyText(.csv), "Name,Value\ntext,\"\"\"quoted\"\"\"")
        XCTAssertTrue(table.copyText(.markdown).contains("| Name | Value |"))
        XCTAssertTrue(table.scroll.hasHorizontalScroller)
        // Short columns fit the lane, with no arbitrary per-column minimum.
        XCTAssertEqual(try XCTUnwrap(table.scroll.documentView).frame.width, table.scroll.bounds.width, accuracy: 1)
        _ = response.height(for: 40)
        // Below the longest words plus cell padding, the table scrolls.
        XCTAssertGreaterThan(try XCTUnwrap(table.scroll.documentView).frame.width, table.scroll.bounds.width)
    }

    /// Inline code with a slash used to be styled as a file link and then struck through as missing.
    func testSlashedInlineCodeIsAFileOnlyWithAnExtensionOrAnAnchoredPath() {
        for text in ["origin/main", "application/json", "@types/node", "feature/agent-pane", "Sources/TabApp"] {
            XCTAssertNil(AgentResponseLink.inferredFile(text), text)
        }
        XCTAssertEqual(AgentResponseLink.inferredFile("Sources/App.swift:12"), .file("Sources/App.swift", 12))
        XCTAssertEqual(AgentResponseLink.inferredFile("./scripts/run"), .file("./scripts/run", nil))
        XCTAssertEqual(AgentResponseLink.inferredFile("~/notes/todo"), .file("~/notes/todo", nil))
        XCTAssertEqual(AgentResponseLink.inferredFile("Makefile"), .file("Makefile", nil))
    }

    func testFileLinksAreRoutedWithLineWhileUnsafeSchemesAreNeverOpened() throws {
        XCTAssertEqual(AgentResponseLink.parse("Sources/App.swift:12:3"), .file("Sources/App.swift", 12))
        XCTAssertEqual(AgentResponseLink.parse("Sources/App.swift#L19C4"), .file("Sources/App.swift", 19))
        XCTAssertEqual(AgentResponseLink.parse("file:///Users/me/My%20File.swift#L9"), .file("/Users/me/My File.swift", 9))
        XCTAssertNil(AgentResponseLink.parse("javascript:alert(1)"))
        XCTAssertNil(AgentResponseLink.parse("data:text/html,unsafe"))
        let response = AgentResponseView(frame: .zero)
        var opened: (String, Int?)?
        response.onOpenFile = { opened = ($0, $1) }
        response.setContent("See [`App.swift`](Sources/App.swift:12) or `Sources/Other.swift:27`.", theme: AppTheme(systemIsDark: true))
        let text = try XCTUnwrap(descendants(response).compactMap { $0 as? AgentRichTextView }.first)
        let string = text.string as NSString
        let link = try XCTUnwrap(text.textStorage?.attribute(.link, at: string.range(of: "App.swift").location, effectiveRange: nil))
        XCTAssertTrue(response.textView(text, clickedOnLink: link, at: 0))
        XCTAssertEqual(opened?.0, "Sources/App.swift")
        XCTAssertEqual(opened?.1, 12)
        XCTAssertTrue(response.textView(text, clickedOnLink: "javascript:alert(1)", at: 0))
        XCTAssertFalse(response.textView(text, clickedOnLink: try XCTUnwrap(URL(string: "https://example.com")), at: 0))
        let inlineFile = try XCTUnwrap(text.textStorage?.attribute(.link, at: string.range(of: "Sources/Other.swift:27").location, effectiveRange: nil) as? URL)
        XCTAssertEqual(AgentResponseLink.parse(inlineFile.absoluteString), .file("Sources/Other.swift", 27))
    }

    func testCodeUsesEditorTokenizerAndKeepsSelectionAsOpenFenceStreams() throws {
        let restoreClipboard = preserveAgentTestClipboard()
        defer { restoreClipboard() }
        let theme = AppTheme(systemIsDark: true)
        let response = AgentResponseView(frame: .zero)
        response.setContent("Intro\n\n```swift title=\"Example.swift\"\nlet count = 42", theme: theme)
        _ = response.height(for: 320)
        let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        XCTAssertEqual(code.language, .swift)
        let keywordColor = try XCTUnwrap(code.text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(keywordColor, theme.syntaxColors.color(.keyword))
        code.text.setSelectedRange(NSRange(location: 0, length: 3))
        response.setContent("Intro\n\n```swift title=\"Example.swift\"\nlet count = 42\nlet next = true\n```", theme: theme)
        _ = response.height(for: 320)
        XCTAssertTrue(code === response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        XCTAssertEqual(code.text.selectedRange(), NSRange(location: 0, length: 3))
        XCTAssertEqual(code.code, "let count = 42\nlet next = true\n")
        code.copyCode()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), code.code)
        XCTAssertEqual(AgentCodeFenceInfo("swift title='Sources/Example.swift'").title, "Sources/Example.swift")
        XCTAssertEqual(AgentCodeFenceInfo("js filename=example.js").title, "example.js")
        XCTAssertNil(AgentCodeFenceInfo("swift linenos").title)
    }

    func testLongCodeOverflowsHorizontallyAndWrapRemeasuresThroughCallback() throws {
        let response = AgentResponseView(frame: .zero)
        response.setContent("```swift\nlet longLine = \"" + String(repeating: "long ", count: 40) + "\"\n```", theme: AppTheme(systemIsDark: true))
        let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        XCTAssertTrue(code.wrapped, "Conversation defaults code blocks to wrapped text")
        code.setWrapped(false)
        let unwrappedHeight = response.height(for: 280)
        XCTAssertGreaterThan(code.text.frame.width, code.scroll.frame.width)
        var invalidated = false
        response.onHeightChanged = { invalidated = true }
        code.wrap.perform()
        XCTAssertTrue(invalidated)
        let wrappedHeight = response.height(for: 280)
        XCTAssertGreaterThan(wrappedHeight, unwrappedHeight)
        XCTAssertLessThanOrEqual(code.text.frame.width, code.scroll.frame.width + 1)
    }

    func testRenderNativeResponseFormatting() throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TAB_SNAPSHOT_DIR to render native response formatting")
        }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let source = """
        ## Native response formatting

        Select **formatted text**, *emphasis*, and `inline code`. Open [documentation](https://developer.apple.com) or `Sources/TabApp/App.swift:42`.

        10. Keep ordered markers aligned
            - Nest a child item
              - [x] Preserve task state

        > A quote keeps its own paragraph and a quiet leading rule.

        | Surface | State | Count |
        | :--- | :---: | ---: |
        | **AppKit** | Ready | 12 |
        | Native text | Selectable | 3 |

        ```swift title="AgentPane.swift"
        // Existing editor tokenizer, shared theme
        let message = "Hello, native macOS"
        let count = 42
        ```
        """
        let root = ThemedView(frame: NSRect(x: 0, y: 0, width: 800, height: 900))
        let response = AgentResponseView(frame: .zero)
        root.addSubview(response)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        for dark in [true, false] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            root.layer?.backgroundColor = theme.bg.cgColor
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width in [800, 360] {
                window.setContentSize(NSSize(width: width, height: 900))
                response.setContent(source, theme: theme)
                let height = response.height(for: CGFloat(width) - 32)
                response.frame = NSRect(x: 16, y: 16, width: CGFloat(width) - 32, height: height)
                root.layoutSubtreeIfNeeded()
                root.displayIfNeeded()
                let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: rep)
                let name = "agent-response-\(dark ? "dark" : "light")-\(width).png"
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
                let metrics: [[String: Any]] = descendants(response).compactMap { view in
                    guard view is AgentResponseSection || view is NSTextView else { return nil }
                    let frame = view.convert(view.bounds, to: root)
                    return ["type": String(describing: type(of: view)), "x": frame.minX, "y": frame.minY,
                            "width": frame.width, "height": frame.height,
                            "text": (view as? NSTextView)?.string ?? ""]
                }
                try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".json"))
            }
        }
    }

    func testRenderPolishedConversationWideAndNarrow() throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TAB_SNAPSHOT_DIR to render polished agent conversation snapshots")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let surface = surface(width: 1000, height: 900)
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, status: .waiting, items: [
            AgentChatItem(id: "user", kind: .user, text: "Make the agent conversation feel like a focused writing surface, not a dashboard."),
            AgentChatItem(id: "tools-1", kind: .tool, text: "Read · Theme/Metrics.swift", detail: "Native spacing and typography tokens"),
            AgentChatItem(id: "tools-2", kind: .tool, text: "Read · Components/Buttons.swift"),
            AgentChatItem(id: "assistant", kind: .assistant, text: """
            ## A quieter conversation

            The transcript now puts **your work first**. Assistant responses stay on the canvas, while your messages sit in a muted bubble.

            - A readable column with generous breathing room
            - Native, selectable text and working [links](https://developer.apple.com/documentation/appkit)
            - A fixed composer that keeps your draft safe

            ```swift
            let interface = "AppKit"
            let dependencies = 0
            ```
            """),
            AgentChatItem(id: "approval", kind: .approval, text: "Run the focused rendering tests?",
                          detail: "swift test --filter AgentRenderingTests", isComplete: false),
        ])
        surface.render(snapshot)
        surface.composer.string = "Keep the model and effort controls within reach."
        surface.refreshComposer()
        surface.send.isHidden = true
        surface.stop.isHidden = false
        surface.feedback.stringValue = "Waiting for your approval"
        let window = NSWindow(contentRect: surface.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        for dark in [true, false] {
            surface.theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            surface.themeDidChange()
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width in [1000, 360] {
                window.setContentSize(NSSize(width: width, height: 900))
                surface.needsLayout = true
                surface.layoutSubtreeIfNeeded()
                surface.displayIfNeeded()
                let rep = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
                surface.cacheDisplay(in: surface.bounds, to: rep)
                let name = "agent-polished-\(dark ? "dark" : "light")-\(width).png"
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
            }
        }
    }
}
