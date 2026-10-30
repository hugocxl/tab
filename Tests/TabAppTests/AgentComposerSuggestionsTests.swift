import AppKit
import XCTest
@testable import TabApp

final class AgentComposerTriggerTests: XCTestCase {
    private func parse(_ text: String, caret: Int? = nil) -> AgentComposerTrigger? {
        AgentComposerTrigger.parse(text: text, selection: NSRange(location: caret ?? (text as NSString).length, length: 0))
    }

    func testMentionsUseCaretAndReplaceWholeTokenInUTF16() throws {
        let text = "😀 inspect @Sources/Agent.swift next"
        let token = (text as NSString).range(of: "@Sources/Agent.swift")
        let trigger = try XCTUnwrap(parse(text, caret: token.location + 8))
        XCTAssertEqual(trigger.kind, .mention)
        XCTAssertEqual(trigger.query, "Sources")
        XCTAssertEqual(trigger.range, token)
        XCTAssertEqual((text as NSString).replacingCharacters(in: trigger.range, with: "@Other.swift"),
                       "😀 inspect @Other.swift next")
    }

    func testEmptyQueriesAndPromptLeadingCommands() {
        XCTAssertEqual(parse("@")?.query, "")
        XCTAssertEqual(parse("/")?.kind, .command)
        XCTAssertEqual(parse(" \n /eff")?.query, "eff")
        XCTAssertNil(parse("please /model"))
        XCTAssertNil(parse("/usr/bin"))
        XCTAssertNil(parse("/model argument"))
        XCTAssertEqual(parse("/model argument", caret: 4)?.range, NSRange(location: 0, length: 6))
    }

    func testDoesNotTriggerForEmailsURLsOrCode() {
        for text in ["me@example.com", "https://host/@file", "git@github.com:repo", "`@file", "`code @file",
                     "```swift\n@file", "~~~text\n@file", "`code /model", "@https://host", "@@file"] {
            XCTAssertNil(parse(text), text)
        }
        XCTAssertNotNil(parse("`code` @file"))
        XCTAssertNotNil(parse("```swift\nlet x = 1\n```\n@file"))
        XCTAssertNotNil(parse("~~~\ncode\n~~~\n@file"))
        XCTAssertNotNil(parse("``code ` nested`` @file"))
    }

    func testNamespacedSkillCommand() throws {
        let text = "/skill:Documents"
        let trigger = try XCTUnwrap(parse(text))
        XCTAssertEqual(trigger.kind, .command)
        XCTAssertEqual(trigger.query, "skill:Documents")
        XCTAssertEqual(trigger.range, NSRange(location: 0, length: (text as NSString).length))
        XCTAssertNil(parse("/skill:https://host"))
    }

    func testSelectedTextAndInvalidUTF16OffsetsAreNotReplaced() {
        XCTAssertNil(AgentComposerTrigger.parse(text: "@file", selection: NSRange(location: 1, length: 2)))
        XCTAssertNil(parse("@file", caret: 100))
        XCTAssertNil(parse("@file", caret: -1))
        XCTAssertNil(parse("😀 @file", caret: 1))
        XCTAssertNil(parse("@e\u{301}", caret: 2), "Do not split a combining sequence")
        XCTAssertNil(parse("@👩‍💻", caret: 3), "Do not split a joined emoji")
        XCTAssertNil(AgentComposerTrigger.parse(text: "@file", selection: NSRange(location: NSNotFound, length: 0)))
    }

    func testEscapeStaysDismissedUntilLeavingTrigger() throws {
        var state = AgentComposerTriggerState()
        let initial = try XCTUnwrap(parse("@a"))
        XCTAssertEqual(state.resolve(initial), initial)
        state.dismiss(initial)
        XCTAssertNil(state.resolve(parse("@agent")))
        XCTAssertNil(state.resolve(nil))
        XCTAssertNotNil(state.resolve(parse("@agent")))
        state.dismiss(initial)
        state.reset()
        XCTAssertNotNil(state.resolve(initial))
    }
}

@MainActor
final class AgentComposerSuggestionsViewTests: XCTestCase {
    func testDefaultInitializer() {
        let view = AgentComposerSuggestionsView()
        XCTAssertEqual(view.frame, .zero)
        XCTAssertTrue(view.isHidden)
    }

    func testZeroAndTinyLayoutNeverCreatesInvalidNativeGeometry() {
        let view = AgentComposerSuggestionsView()
        view.update(suggestions(20), theme: .shared)
        for size in [NSSize.zero, NSSize(width: 4, height: 8), NSSize(width: 12, height: 12),
                     NSSize(width: 440, height: 276), .zero] {
            view.frame.size = size
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            for child in view.subviews + [view.tableView] {
                XCTAssertTrue(child.frame.width.isFinite)
                XCTAssertTrue(child.frame.height.isFinite)
                XCTAssertGreaterThanOrEqual(child.frame.width, 0)
                XCTAssertGreaterThanOrEqual(child.frame.height, 0)
            }
        }
    }

    private func suggestions(_ count: Int) -> [AgentComposerSuggestion] {
        (0..<count).map { AgentComposerSuggestion(id: "file:\($0)", title: "File \($0)",
            subtitle: "Sources/\($0).swift", symbol: "doc", kind: .file) }
    }

    func testKeyboardWrapsPreservesIdentityAndAcceptsExactlyOnce() {
        let view = AgentComposerSuggestionsView(frame: NSRect(x: 0, y: 0, width: 440, height: 276))
        let items = suggestions(20)
        view.update(items, theme: .shared)
        XCTAssertEqual(view.selectedIndex, 0)
        XCTAssertLessThanOrEqual(view.preferredHeight, 300)
        view.moveSelection(-1)
        XCTAssertEqual(view.selectedIndex, 19)
        view.moveSelection(1)
        XCTAssertEqual(view.selectedIndex, 0)
        view.update(Array(items.reversed()), theme: .shared)
        XCTAssertEqual(view.selectedIndex, 19)
        XCTAssertEqual(view.tableView.selectedRow, 19)
        var accepted: [String] = []
        view.onSelect = { accepted.append($0.id) }
        XCTAssertTrue(view.acceptSelection())
        XCTAssertEqual(accepted, ["file:0"])
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertFalse(view.tableView.acceptsFirstResponder)
    }

    func testReloadSelectionNotificationsDoNotOverrideIdentityOrFallback() {
        let view = AgentComposerSuggestionsView(frame: NSRect(x: 0, y: 0, width: 440, height: 276))
        let items = suggestions(20)
        view.update(items, theme: .shared)
        view.moveSelection(12)
        view.update([items[19], items[12], items[0]], theme: .shared)
        XCTAssertEqual(view.selectedIndex, 1)
        XCTAssertEqual(view.tableView.selectedRow, 1)
        view.update([items[0], items[19]], theme: .shared)
        XCTAssertEqual(view.selectedIndex, 0, "Removed identity falls back to the first result")
        XCTAssertEqual(view.tableView.selectedRow, 0)
        view.update([], theme: .shared)
        XCTAssertEqual(view.selectedIndex, -1)
        view.update(items, theme: .shared)
        XCTAssertEqual(view.selectedIndex, 0)
        XCTAssertEqual(view.tableView.selectedRow, 0)
    }

    func testVisibleMenuConsumesReturnTabAndEscapeEvenWithoutMatches() {
        let view = AgentComposerSuggestionsView(frame: .zero)
        view.update([], theme: .shared)
        XCTAssertFalse(view.acceptSelection())
        XCTAssertFalse(view.moveSelection(1))
        view.isHidden = false
        XCTAssertTrue(view.handleCommand(NSSelectorFromString("insertNewline:")))
        XCTAssertTrue(view.handleCommand(NSSelectorFromString("insertTab:")))
        XCTAssertFalse(view.handleCommand(NSSelectorFromString("deleteBackward:")))
        var dismissed = false
        view.onDismiss = { dismissed = true }
        XCTAssertTrue(view.handleCommand(NSSelectorFromString("cancelOperation:")))
        XCTAssertTrue(dismissed)
        XCTAssertTrue(view.isHidden)
        XCTAssertFalse(view.handleCommand(NSSelectorFromString("insertNewline:")))
    }

    func testNativeTableKeepsAllResultsScrollableWithoutIncreasingPopupHeight() {
        let view = AgentComposerSuggestionsView(frame: NSRect(x: 0, y: 0, width: 440, height: 276))
        view.update(suggestions(1000), theme: .shared)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.tableView.numberOfRows, 1000)
        XCTAssertEqual(view.preferredHeight, 276)
        XCTAssertGreaterThan(view.tableView.frame.height, view.bounds.height)
        view.moveSelection(-1)
        XCTAssertEqual(view.selectedIndex, 999)
        view.update([], theme: .shared)
        XCTAssertEqual(view.selectedIndex, -1)
        XCTAssertGreaterThan(view.preferredHeight, 0)
    }
}
