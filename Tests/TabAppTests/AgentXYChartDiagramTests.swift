import AppKit
import XCTest
@testable import TabApp

final class AgentXYChartDiagramTests: XCTestCase {
    private let style = AgentDiagramStyle()

    func testParsesCategoriesRangeAndSeries() throws {
        let diagram = try AgentXYChartDiagram(source: """
            xychart-beta
                title "Sales Revenue"
                x-axis [jan, feb, mar, apr]
                y-axis "Revenue (in $)" 4000 --> 11000
                bar [5000, 6000, 7500, 8200]
                line [5000, 6000, 7500, 8200]
            """)
        XCTAssertEqual(diagram.title, "Sales Revenue")
        XCTAssertEqual(diagram.xCategories, ["jan", "feb", "mar", "apr"])
        XCTAssertEqual(diagram.yTitle, "Revenue (in $)")
        XCTAssertEqual(diagram.yRange?.min, 4000)
        XCTAssertEqual(diagram.yRange?.max, 11000)
        XCTAssertEqual(diagram.series.map(\.kind), [.bar, .line])
        XCTAssertEqual(diagram.series[0].values, [5000, 6000, 7500, 8200])
    }

    func testAxisTitlesQuotedCategoriesAndNamedSeries() throws {
        let diagram = try AgentXYChartDiagram(source: """
            xychart
            x-axis "Quarter" ["Q1, early", Q2, "Q3"]
            y-axis "Units"
            bar "Plan" [1, 2.5, -3]
            """)
        XCTAssertEqual(diagram.xTitle, "Quarter")
        XCTAssertEqual(diagram.xCategories, ["Q1, early", "Q2", "Q3"])
        XCTAssertEqual(diagram.yTitle, "Units")
        XCTAssertNil(diagram.yRange)
        XCTAssertEqual(diagram.series[0].name, "Plan")
        XCTAssertEqual(diagram.series[0].values, [1, 2.5, -3])
        let range = diagram.valueRange
        XCTAssertLessThanOrEqual(range.min, -3)
        XCTAssertGreaterThanOrEqual(range.max, 2.5)
    }

    func testNumericXAxisRangeLabelsEachPoint() throws {
        let diagram = try AgentXYChartDiagram(source: "xychart-beta\nx-axis \"Hour\" 0 --> 10\nline [1, 2, 3, 4, 5, 6]")
        XCTAssertEqual(diagram.xTitle, "Hour")
        XCTAssertEqual(diagram.xLabels, ["0", "2", "4", "6", "8", "10"])
        let unlabeled = try AgentXYChartDiagram(source: "xychart-beta\nbar [3, 4]")
        XCTAssertEqual(unlabeled.xLabels, ["1", "2"])
    }

    func testHorizontalHeaderIsTolerated() throws {
        let diagram = try AgentXYChartDiagram(source: "xychart-beta horizontal\nbar [1, 2]")
        XCTAssertTrue(diagram.horizontal)
    }

    func testErrorsReportTheirLines() {
        let cases: [(String, Int?)] = [
            ("xychart-beta\nbar [1, two, 3]", 2),
            ("xychart-beta\ntitle x\nline 1, 2", 3),
            ("xychart-beta\ny-axis [a, b]", 2),
            ("xychart-beta\ny-axis 10 --> 1", 2),
            ("xychart-beta\nscatter [1]", 2),
            ("xychart-beta\nbar []", 2),
            ("xychart-beta\ntitle Nothing", nil),
        ]
        for (source, line) in cases {
            XCTAssertThrowsError(try AgentXYChartDiagram(source: source), source) { error in
                XCTAssertEqual((error as? AgentDiagramError)?.line, line, source)
            }
        }
    }

    func testBarsScaleWithValuesAndShareTheBaseline() throws {
        let diagram = try AgentXYChartDiagram(source: "xychart-beta\nx-axis [a, b, c]\ny-axis 0 --> 100\nbar [25, 50, 100]\nbar [10, 20, 30]")
        let geometry = diagram.geometry(maxWidth: 600, style: style)
        XCTAssertEqual(geometry.bars.count, 2)
        let first = geometry.bars[0]
        XCTAssertEqual(first[1].height, first[0].height * 2, accuracy: 0.5)
        XCTAssertEqual(first[2].height, geometry.plot.height, accuracy: 0.5)
        for rect in first + geometry.bars[1] {
            XCTAssertEqual(rect.maxY, geometry.plot.maxY, accuracy: 0.5)
            XCTAssertTrue(geometry.plot.insetBy(dx: -0.5, dy: -0.5).contains(rect))
        }
        for index in 0..<3 {
            XCTAssertLessThanOrEqual(first[index].maxX, geometry.bars[1][index].minX + 0.5)
        }
    }

    func testLinePointsFollowCategoriesLeftToRight() throws {
        let diagram = try AgentXYChartDiagram(source: "xychart-beta\nx-axis [a, b, c, d]\nline [1, 3, 2, 4]")
        let geometry = diagram.geometry(maxWidth: 600, style: style)
        let points = try XCTUnwrap(geometry.lines.first)
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points.map(\.x), points.map(\.x).sorted())
        XCTAssertLessThan(points[1].y, points[0].y)
        XCTAssertGreaterThan(points[2].y, points[1].y)
        XCTAssertEqual(geometry.xTicks.map(\.x), points.map(\.x))
        let tickYs = geometry.yTicks.map(\.y)
        XCTAssertEqual(tickYs, tickYs.sorted(by: >))
    }

    func testOutOfRangeValuesAreClamped() throws {
        let diagram = try AgentXYChartDiagram(source: "xychart-beta\ny-axis 0 --> 10\nbar [50, -5]")
        let geometry = diagram.geometry(maxWidth: 600, style: style)
        for rect in geometry.bars[0] {
            XCTAssertGreaterThanOrEqual(rect.minY, geometry.plot.minY - 0.5)
            XCTAssertLessThanOrEqual(rect.maxY, geometry.plot.maxY + 0.5)
        }
    }

    func testRenderingPaintsPixels() throws {
        let diagram = try AgentXYChartDiagram(source: """
            xychart-beta
            title "Weekly"
            x-axis "Day" [Monday, Tuesday, Wednesday, Thursday, Friday, Saturday, Sunday, "Next Monday"]
            y-axis "Visits"
            bar [3, 5, 9, 4, 7, 2, 1, 6]
            line [2, 6, 8, 5, 6, 3, 2, 7]
            """)
        let geometry = diagram.geometry(maxWidth: 360, style: style)
        XCTAssertTrue(geometry.rotateXLabels)
        let painted = try AgentDiagramTextRendering.paintedPixels(diagram.layout(maxWidth: 360, style: style))
        XCTAssertGreaterThan(painted, 3_000)
    }
}
