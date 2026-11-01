import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentThreadLinkTests: XCTestCase {
    private let theme = AppTheme(systemIsDark: false)
    private let session = SessionId()
    private let project = ProjectId()

    private func chips(in text: NSAttributedString) -> [(range: NSRange, session: String)] {
        var result: [(NSRange, String)] = []
        text.enumerateAttribute(.agentThreadLink, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let session = value as? String { result.append((range, session)) }
        }
        return result
    }

    // MARK: Format

    func testParsesProjectScopedAndSameProjectForms() throws {
        let scoped = try XCTUnwrap(AgentThreadLink("tab-thread://\(project)/\(session)"))
        XCTAssertEqual(scoped, AgentThreadLink(session: session, project: project))
        let same = try XCTUnwrap(AgentThreadLink(" tab-thread://\(session.description.uppercased()) "))
        XCTAssertEqual(same, AgentThreadLink(session: session))
        XCTAssertEqual(AgentThreadLink(scoped.href), scoped)
        XCTAssertEqual(scoped.href, "tab-thread://\(project)/\(session)")
    }

    func testRejectsOtherShapes() {
        for raw in ["tab-thread://not-a-uuid", "tab-thread://\(project)/\(session)/extra", "tab-thread://\(session)?x=1",
                    "tab-thread://\(session)#frag", "https://\(session)", "tab-thread://", "tab-thread://\(project)/nope"] {
            XCTAssertNil(AgentThreadLink(raw), raw)
        }
    }

    func testMarkdownEscapesTheTitleAndChipTitlesFallBack() {
        let link = AgentThreadLink(session: session, project: project)
        XCTAssertEqual(link.markdown(title: "Fix [parser]\n  *now*"), "[@Fix [parser] \\*now\\*](\(link.href))")
        XCTAssertEqual(link.markdown(title: "a] b["), "[@a) b(](\(link.href))")
        XCTAssertEqual(link.chipTitle(label: "@Reader review", knownTitle: nil), "Reader review")
        XCTAssertEqual(link.chipTitle(label: "@Reader review", knownTitle: "Renamed"), "Renamed")
        XCTAssertEqual(link.chipTitle(label: link.href, knownTitle: nil), "Conversation " + link.shortID)
        XCTAssertEqual(link.chipTitle(label: "", knownTitle: ""), "Conversation " + String(session.description.prefix(8)))
    }

    // MARK: Rendering

    func testThreadLinksRenderAsOneLinkedChipWithIcon() throws {
        let link = AgentThreadLink(session: session, project: project)
        let rendered = AgentMarkdown.render(AgentResponseParser.parse("See [@Fix **the** parser](\(link.href)) next."), theme: theme, fileLinks: true)
        let found = chips(in: rendered)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.session, session.description)
        let range = try XCTUnwrap(found.first?.range)
        let chip = (rendered.string as NSString).substring(with: range)
        XCTAssertTrue(chip.hasPrefix("\u{FFFC}"), "The chip starts with the conversation icon")
        XCTAssertTrue(chip.hasSuffix("Fix the parser"), rendered.string.debugDescription)
        XCTAssertEqual((rendered.attribute(.link, at: range.location, effectiveRange: nil) as? URL)?.absoluteString, link.href)
        XCTAssertNotNil(rendered.attribute(.agentInlineCodeBackground, at: range.location, effectiveRange: nil), "The chip is drawn as a pill")
    }

    func testKnownTitlesReplaceTheRenderedLabel() throws {
        let link = AgentThreadLink(session: session)
        let rendered = NSMutableAttributedString(attributedString: AgentMarkdown.render(AgentResponseParser.parse("Ask [@old](\(link.href))"), theme: theme))
        AgentThreadLink.applyKnownTitles(rendered, titles: [session.description: "Release checklist"])
        XCTAssertTrue(rendered.string.hasSuffix("\u{2009}Release checklist"))
        XCTAssertEqual(chips(in: rendered).first?.session, session.description)
    }

    func testAssistantProseUsesTheConversationsKnownTitles() throws {
        let services = AgentConversationLinkServices()
        services.threadTitles = [session.description: "Known title"]
        let view = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        view.linkServices = services
        view.setContent("See <tab-thread://\(session)>", theme: theme)
        let text = try XCTUnwrap((view.sectionViews.first as? AgentResponseProse)?.text)
        XCTAssertTrue(text.string.hasSuffix("Known title"))
    }

    // MARK: Round trip

    func testComposerMentionSendsALinkThatRendersAChipAndOpensTheThread() async throws {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        surface.render(.init(session: SessionId(), project: project, provider: .codex, status: .idle, revision: 1, items: []))
        let coordinator = AgentComposerCoordinator(surface: surface)
        coordinator.loadFiles = { [] }
        let target = session
        coordinator.loadThreads = { [.init(id: target.description, title: "Reader [review]", context: "Assistant: earlier")] }
        surface.composer.string = "Compare @rea with this"
        surface.composer.setSelectedRange(NSRange(location: 12, length: 0))
        coordinator.changed()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(surface.suggestions.items.first?.kind, .thread)
        surface.suggestions.moveSelection(-surface.suggestions.selectedIndex)
        XCTAssertTrue(coordinator.handle(#selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(surface.composer.string, "Compare @Reader [review] with this")

        let sent = AgentComposerCitation.prompt(from: surface.composer.attributedString())
        let link = AgentThreadLink(session: session, project: project)
        XCTAssertEqual(sent, "Compare [@Reader [review]](\(link.href)) with this")

        let response = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        response.lineBreaks = true
        response.setContent(sent, theme: theme)
        let text = try XCTUnwrap((response.sectionViews.first as? AgentResponseProse)?.text)
        let chip = try XCTUnwrap(chips(in: text.attributedString()).first)
        XCTAssertTrue((text.string as NSString).substring(with: chip.range).hasSuffix("Reader [review]"), text.string.debugDescription)
        var opened: AgentThreadLink?
        response.onOpenThread = { opened = $0 }
        let url = try XCTUnwrap(text.textStorage?.attribute(.link, at: chip.range.location, effectiveRange: nil))
        XCTAssertTrue(response.textView(text, clickedOnLink: url, at: chip.range.location))
        XCTAssertEqual(opened, link)
    }

    func testEditingAMentionTurnsItIntoPlainText() {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        surface.composer.string = "@x"
        XCTAssertTrue(surface.insertThreadMention(AgentThreadLink(session: session), title: "Plan", replacing: NSRange(location: 0, length: 2)))
        XCTAssertEqual(surface.composer.string, "@Plan ")
        XCTAssertTrue(AgentComposerCitation.prompt(from: surface.composer.attributedString()).hasPrefix("[@Plan](tab-thread://"))
        let interior = NSRange(location: 2, length: 0)
        XCTAssertTrue(surface.composer.shouldChangeText(in: interior, replacementString: "X"))
        surface.composer.textStorage?.replaceCharacters(in: interior, with: "X")
        XCTAssertEqual(AgentComposerCitation.prompt(from: surface.composer.attributedString()), "@PXlan ")
    }

    func testOpeningAThreadWithoutItsProjectReportsTheFailure() async throws {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        var errors: [String] = []
        surface.onActionError = { errors.append($0) }
        surface.openThread(AgentThreadLink(session: session, project: project))
        let deadline = Date().addingTimeInterval(2)
        while errors.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(errors, ["The project server is offline."])
    }
}
