import AppKit
import XCTest
@testable import TabApp

final class AgentPieDiagramTests: XCTestCase {
    private let style = AgentDiagramStyle()

    func testParsesSlicesAndTitleLine() throws {
        let diagram = try AgentPieDiagram(source: """
            pie
                title Pets adopted
                "Dogs" : 386
                "Cats" : 85.5
                "Rats" : 15
            """)
        XCTAssertEqual(diagram.title, "Pets adopted")
        XCTAssertFalse(diagram.showData)
        XCTAssertEqual(diagram.slices.map(\.label), ["Dogs", "Cats", "Rats"])
        XCTAssertEqual(diagram.slices.map(\.value), [386, 85.5, 15])
    }

    func testShowDataAndTitleOnTheHeader() throws {
        let diagram = try AgentPieDiagram(source: "pie showData title Key elements\n\"Calcium\" : 42.96\n\"Iron\" : 5")
        XCTAssertTrue(diagram.showData)
        XCTAssertEqual(diagram.title, "Key elements")
        XCTAssertTrue(diagram.legendText(diagram.slices[0]).contains("42.96"))
        XCTAssertFalse(try AgentPieDiagram(source: "pie\n\"A\": 3").legendText(AgentPieDiagram.Slice(label: "A", value: 3)).contains("3 ·"))
    }

    func testSlicesSumTo360Degrees() throws {
        let diagram = try AgentPieDiagram(source: "pie\n\"A\": 1\n\"B\": 2\n\"C\": 3.5\n\"D\": 0")
        let angles = diagram.sliceAngles
        XCTAssertEqual(angles.first?.start, 0)
        XCTAssertEqual(angles.last?.end ?? 0, 360, accuracy: 1e-9)
        for (previous, next) in zip(angles, angles.dropFirst()) {
            XCTAssertEqual(previous.end, next.start, accuracy: 1e-9)
        }
        XCTAssertEqual(angles[3].end - angles[3].start, 0)
        XCTAssertEqual(diagram.slices.map { diagram.percentage(of: $0) }.reduce(0, +), 100, accuracy: 1e-9)
    }

    func testCommentsAndAccessibilityLinesAreSkipped() throws {
        let diagram = try AgentPieDiagram(source: "%% comment\npie\naccTitle: x\n%% another\n\"Only\" : 1")
        XCTAssertEqual(diagram.slices.count, 1)
    }

    func testNegativeValueReportsItsLine() {
        XCTAssertThrowsError(try AgentPieDiagram(source: "pie\n\"A\" : 1\n\"B\" : -2")) { error in
            XCTAssertEqual((error as? AgentDiagramError)?.line, 3)
        }
    }

    func testNonNumericValueReportsItsLine() {
        XCTAssertThrowsError(try AgentPieDiagram(source: "pie\n\"A\" : many")) { error in
            XCTAssertEqual((error as? AgentDiagramError)?.line, 2)
        }
        XCTAssertThrowsError(try AgentPieDiagram(source: "pie\njust words")) { error in
            XCTAssertEqual((error as? AgentDiagramError)?.line, 2)
        }
    }

    func testEmptyOrZeroPiesAreErrors() {
        XCTAssertThrowsError(try AgentPieDiagram(source: "pie title Nothing"))
        XCTAssertThrowsError(try AgentPieDiagram(source: "pie\n\"A\" : 0"))
        XCTAssertThrowsError(try AgentPieDiagram(source: "pier\n\"A\" : 1"))
    }

    func testLegendRowsDoNotOverlapThePie() throws {
        let diagram = try AgentPieDiagram(source: "pie title T\n" + (0..<12).map { "\"Slice \($0)\" : \($0 + 1)" }.joined(separator: "\n"))
        let geometry = diagram.geometry(style: style)
        XCTAssertEqual(geometry.legendRows.count, 12)
        for row in geometry.legendRows {
            XCTAssertGreaterThan(row.minX, geometry.center.x + geometry.radius)
            XCTAssertLessThanOrEqual(row.maxY, geometry.size.height)
        }
        for (upper, lower) in zip(geometry.legendRows, geometry.legendRows.dropFirst()) {
            XCTAssertLessThanOrEqual(upper.maxY, lower.minY)
        }
    }

    func testRenderingPaintsPixels() throws {
        let diagram = try AgentPieDiagram(source: "pie showData title Share\n\"A<br/>two lines\" : 3\n\"B\" : 2\n\"C\" : 1")
        let painted = try AgentDiagramTextRendering.paintedPixels(diagram.layout(maxWidth: 500, style: style))
        XCTAssertGreaterThan(painted, 10_000)
    }
}
