import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentTemplateCardTests: XCTestCase {
    private let theme = AppTheme(systemIsDark: false)
    private let directive = #"::artifact-template{artifact_kind="presentation" display_name="Quarterly review" skill_directory="/Users/me/.codex/skills/slides" skill_name="artifact-template-slides"}"#

    func testDirectiveParsesAndBuildsTheUsePrompt() throws {
        let template = try XCTUnwrap(AgentArtifactTemplate.parse(directive))
        XCTAssertEqual(template.kind, .presentation)
        XCTAssertEqual(template.displayName, "Quarterly review")
        XCTAssertEqual(template.kind.label, "Presentation template")
        XCTAssertEqual(template.prompt, "Create a presentation using the $artifact-template-slides template about…")
        let email = try XCTUnwrap(AgentArtifactTemplate.parse(#"::artifact-template{artifact_kind='email' display_name="Launch \"note\"" skill_directory=C:\skills\mail skill_name=artifact-template-mail gallery_kind="imagegen"}"#))
        XCTAssertEqual(email.displayName, #"Launch "note""#)
        XCTAssertEqual(email.galleryKind, "imagegen")
        XCTAssertEqual(email.prompt, "Draft an email using this $artifact-template-mail about…")
    }

    func testInvalidDirectivesStayText() {
        let invalid = [
            directive.replacingOccurrences(of: "presentation", with: "video"),
            directive.replacingOccurrences(of: "/Users/me", with: "relative"),
            directive.replacingOccurrences(of: "skill_name=\"artifact-template-slides\"", with: "skill_name=\"slides\""),
            directive.replacingOccurrences(of: "display_name=\"Quarterly review\"", with: "display_name=\"  \""),
            directive.replacingOccurrences(of: "}", with: " gallery_kind=\"other\"}"),
            directive.replacingOccurrences(of: "}", with: " ???}"),
            "Text before " + directive,
            "    " + directive,
        ]
        for line in invalid { XCTAssertNil(AgentArtifactTemplate.parse(line), line) }
        let parts = AgentResponsePart.partition(AgentResponseParser.parse(invalid[0]), templates: true)
        XCTAssertEqual(parts.map(\.kind), [0])
    }

    func testAppendingDeduplicatesAnExistingPrompt() throws {
        let template = try XCTUnwrap(AgentArtifactTemplate.parse(directive))
        let prompt = template.prompt
        XCTAssertEqual(template.appending(to: ""), prompt)
        XCTAssertEqual(template.appending(to: "Hello"), "Hello " + prompt)
        XCTAssertEqual(template.appending(to: "Hello\n"), "Hello\n" + prompt)
        XCTAssertEqual(template.appending(to: "Hello " + prompt + "  "), "Hello " + prompt + "  ")
        XCTAssertEqual(template.appending(to: "x" + prompt), "x" + prompt + " " + prompt, "Only a whole-word suffix counts as present")
    }

    func testDirectiveLinesBecomeTemplateSectionsBetweenProse() throws {
        let source = "Pick one:\n" + directive + "\nOr describe it.\n\n```\n" + directive + "\n```"
        let parts = AgentResponsePart.partition(AgentResponseParser.parse(source), templates: true)
        XCTAssertEqual(parts.map(\.kind), [0, 9, 0, 1])
        XCTAssertEqual(AgentResponsePart.partition(AgentResponseParser.parse(source)).map(\.kind), [0, 1], "User messages keep directives as text")
    }

    func testTemplateCardUsesTheTemplateWithoutSending() throws {
        let services = AgentConversationLinkServices()
        var used: [AgentArtifactTemplate] = []
        services.useTemplate = { used.append($0) }
        let view = AgentResponseView(frame: .zero)
        view.linkServices = services
        view.setContent(directive, theme: theme)
        let card = try XCTUnwrap(view.sectionViews.first as? AgentResponseTemplate)
        XCTAssertEqual(view.height(for: 500), AgentResponseTemplate.height)
        XCTAssertEqual(card.accessibilityLabel(), "Quarterly review template")
        card.use.onPress?()
        XCTAssertEqual(used.map(\.skillName), ["artifact-template-slides"])
    }

    func testPaneAppendsThePromptToTheComposerDraft() throws {
        let surface = AgentPaneView()
        surface.composer.string = "Draft"
        let template = try XCTUnwrap(AgentArtifactTemplate.parse(directive))
        surface.linkServices.useTemplate?(template)
        XCTAssertEqual(surface.composer.string, "Draft " + template.prompt)
        surface.linkServices.useTemplate?(template)
        XCTAssertEqual(surface.composer.string, "Draft " + template.prompt, "Using it twice does not duplicate the prompt")
    }
}
