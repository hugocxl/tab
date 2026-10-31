import AppKit
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentListStructureTests: XCTestCase {
    func testOrderedTaskCountersRetainListIdentityAndWidestGutter() throws {
        let blocks = AgentResponseParser.parse("9. [ ] Nine\n10. [x] Ten")
        let first = try XCTUnwrap(blocks[0].listStructure)
        let second = try XCTUnwrap(blocks[1].listStructure)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.start, 9)
        XCTAssertEqual(first.number, 9)
        XCTAssertEqual(second.number, 10)
        XCTAssertEqual(first.lastNumber, 10)
        XCTAssertFalse(first.isLoose)
        let indents = AgentListLayout.indents(blocks, font: AppFont.system(14))
        XCTAssertEqual(try XCTUnwrap(indents[0]), 35.265625, accuracy: 0.001)
        XCTAssertEqual(indents[0], indents[1])
        let rendered = AgentMarkdown.render(blocks, theme: AppTheme(systemIsDark: false))
        XCTAssertEqual(rendered.string, "☐\tNine\n☑\tTen")
        let paragraph = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.firstLineHeadIndent, 0, accuracy: 0.001)
        XCTAssertEqual(paragraph.headIndent, 35.265625, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(paragraph.tabStops.first).location, AgentTaskCheckbox.textInset(font: AppFont.system(14)), accuracy: 0.001)
    }

    func testAdjacentMarkerFamiliesRemainDistinctLists() throws {
        let blocks = AgentResponseParser.parse("- First\n+ Separate\n* Third\n9. Nine\n10. Ten\n1) Restart")
        let structures = blocks.compactMap(\.listStructure)
        XCTAssertEqual(structures.count, 6)
        XCTAssertNotEqual(structures[0].id, structures[1].id)
        XCTAssertNotEqual(structures[1].id, structures[2].id)
        XCTAssertEqual(structures[3].id, structures[4].id)
        XCTAssertNotEqual(structures[4].id, structures[5].id)
        let rendered = AgentMarkdown.render(blocks, theme: AppTheme(systemIsDark: false))
        let range = (rendered.string as NSString).range(of: "Separate")
        let paragraph = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.paragraphSpacingBefore, AgentMarkdownLayout.blockGap)
    }

    func testLooseSiblingParagraphMarginsAndOuterCollapseMatchBrowser() throws {
        let blocks = AgentResponseParser.parse("9. Nine\n\n10. Ten")
        XCTAssertTrue(blocks.allSatisfy { $0.listStructure?.isLoose == true })
        let view = AgentResponseView(frame: .zero)
        view.setContent("9. Nine\n\n10. Ten", theme: AppTheme(systemIsDark: false))
        // Browser padded-parent oracle: 55.890625 content + two collapsed 10.390625 margins.
        XCTAssertEqual(view.height(for: 500), 76.671875, accuracy: 0.001)
        let section = try XCTUnwrap(view.subviews.compactMap { $0 as? AgentResponseSection }.first)
        XCTAssertEqual(section.frame.minY, 10.390625, accuracy: 0.001)
        view.setContent("Before\n\n9. Nine\n\n10. Ten\n\nAfter", theme: AppTheme(systemIsDark: false))
        XCTAssertEqual(view.height(for: 500), 122.171875, accuracy: 0.001)
    }

    func testMultipleParagraphsRemainInsideTheirListItem() throws {
        let blocks = AgentResponseParser.parse("- First\n\n  Second paragraph\n\n- Next")
        guard case .listBlock("•", let source, 0, let structure) = blocks.first else { return XCTFail("Expected a rich list item") }
        XCTAssertEqual(source, "First\n\nSecond paragraph")
        XCTAssertEqual(AgentResponseParser.parse(source), [.paragraph("First"), .paragraph("Second paragraph")])
        XCTAssertEqual(structure?.id, blocks.last?.listStructure?.id)
        XCTAssertEqual(structure?.isLoose, true)
        let view = AgentResponseView(frame: .zero)
        view.setContent("- First\n\n  Second paragraph\n\n- Next", theme: AppTheme(systemIsDark: false))
        XCTAssertEqual(view.height(for: 500), 109.8125, accuracy: 0.001)
    }

    func testRichSiblingAndFootnotePreparationPreserveOrderedMetadata() throws {
        let source = "99. First[^a]\n\n    ```swift\n    let value = 1\n    ```\n\n100. Next\n\n[^a]: Note"
        let prepared = AgentMarkdownFootnotes.prepare(AgentResponseParser.parse(source), parseRawHTML: true)
        let first = try XCTUnwrap(prepared.first?.listStructure)
        XCTAssertEqual(first.start, 99)
        XCTAssertEqual(first.lastNumber, 100)
        XCTAssertTrue(first.isLoose)
        let parts = AgentResponsePart.partition(prepared)
        guard case .nested(.list(_, _, let indent, let structure), _) = parts.first else { return XCTFail("Expected prepared rich item") }
        XCTAssertEqual(structure, first)
        XCTAssertEqual(try XCTUnwrap(indent), 44.078125, accuracy: 0.001)
    }

    func testInternalCodeAndQuotedBlankLinesDoNotLoosenAnItem() throws {
        for source in ["- First\n  ```\n  a\n\n  b\n  ```", "- First\n  > quote\n  >\n  > more"] {
            let blocks = AgentResponseParser.parse(source)
            let structure = try XCTUnwrap(blocks.first?.listStructure)
            XCTAssertFalse(structure.isLoose, source)
            let part = try XCTUnwrap(AgentResponsePart.partition(blocks).first)
            XCTAssertEqual(part.outerMargin(first: true), 0, source)
            XCTAssertEqual(part.outerMargin(first: false), 0, source)
        }
        // An unmarked blank separates quote blocks and does loosen the containing item.
        XCTAssertEqual(AgentResponseParser.parse("- First\n  > quote\n\n  > more").first?.listStructure?.isLoose, true)
    }

    func testRichNestedOrderedMarkersUseMatchingAncestorStyles() throws {
        let blocks = AgentResponseParser.parse("1. Outer\n\n   27. Inner\n\n       ```text\n       code\n       ```\n\n   28. Next")
        let parts = AgentResponsePart.partition(blocks)
        guard case .nested(_, let children) = parts.first else { return XCTFail("Expected rich parent") }
        XCTAssertEqual(children.first, .paragraph("Outer"))
        XCTAssertEqual(children.count, 3)
        guard children.count > 1, case .listBlock(let marker, _, _, let structure) = children[1] else { return XCTFail("Expected nested rich list after the parent paragraph") }
        XCTAssertEqual(marker, "aa.")
        XCTAssertEqual(structure?.number, 27)
        XCTAssertEqual(structure?.lastNumber, 28)
    }
}
