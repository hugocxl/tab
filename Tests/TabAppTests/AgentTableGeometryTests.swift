import AppKit
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentTableGeometryTests: XCTestCase {
    func testFractionalCellPaddingDoesNotAccumulateWholePointRounding() throws {
        _ = NSApplication.shared
        let table = AgentResponseTable()
        table.apply(.table(["A", "B"], [["one", "two"], ["three", "four"], ["five", "six"]], [.left, .right]),
                    theme: AppTheme(systemIsDark: false), delegate: Delegate())
        let height = table.height(for: 200)
        let manager = try XCTUnwrap(table.text.layoutManager)
        var positions: [CGFloat] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, _, _, _, _ in
            positions.append(rect.minY)
        }
        XCTAssertEqual(positions.count, 8)
        let expected: [CGFloat] = [8.796875, 48.53125, 86.65625, 124.78125]
        for (index, value) in positions.enumerated() {
            XCTAssertEqual(value, expected[index / 2], accuracy: 0.001)
        }
        XCTAssertEqual(height, 181.71875, accuracy: 0.001)
    }

    func testUnequalWrappedCellsShareRowTopAndKeepSelectionOnResize() throws {
        _ = NSApplication.shared
        let table = AgentResponseTable()
        table.apply(.table(["A", "B"], [["one two three four five six seven eight nine ten", "short"], ["last", "last"]], [.center, .right]),
                    theme: AppTheme(systemIsDark: false), delegate: Delegate())
        _ = table.height(for: 200)
        let storage = try XCTUnwrap(table.text.textStorage)
        let manager = try XCTUnwrap(table.text.layoutManager)
        let source = storage.string as NSString
        let first = source.range(of: "one")
        let second = source.range(of: "short")
        func y(_ range: NSRange) -> CGFloat {
            manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: range.location), effectiveRange: nil).minY
        }
        XCTAssertEqual(y(first), y(second), accuracy: 0.001)
        XCTAssertEqual(y(first), 48.53125, accuracy: 0.001)
        table.text.setSelectedRange(NSRange(location: first.location, length: second.location + second.length - first.location))
        let selected = table.text.selectedRange()
        let narrowHeight = table.height(for: 140)
        XCTAssertEqual(table.text.selectedRange(), selected)
        XCTAssertGreaterThan(narrowHeight, table.height(for: 500))
        XCTAssertEqual(table.text.selectedRange(), selected)
    }

    func testExtremeColumnCapIncludesPaddingAndCopyExtendsIntoLaneGutter() throws {
        _ = NSApplication.shared
        let table = AgentResponseTable()
        table.apply(.table(["A", "B"], [[String(repeating: "x", count: 180), "two"]], [.left, .left]),
                    theme: AppTheme(systemIsDark: false), delegate: Delegate())
        let height = table.height(for: 140)
        table.frame = NSRect(x: 0, y: 0, width: 140, height: height)
        table.layoutSection(width: 140)
        let storage = try XCTUnwrap(table.text.textStorage)
        let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let block = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(block.value(for: .width), 384, accuracy: 0.001)
        XCTAssertGreaterThan(table.text.frame.width, 140)
        XCTAssertEqual(table.copy.frame, NSRect(x: 120, y: height - 24, width: 24, height: 24))
    }

    private final class Delegate: NSObject, NSTextViewDelegate {}
}
