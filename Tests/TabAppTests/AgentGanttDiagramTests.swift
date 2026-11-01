import AppKit
import XCTest
@testable import TabApp

final class AgentGanttDiagramTests: XCTestCase {
    private let style = AgentDiagramStyle()
    private let day = 86_400.0

    private func date(_ text: String) throws -> Double {
        try XCTUnwrap(AgentGanttDiagram.parseDate(text))
    }

    func testParsesSectionsTasksAndSettings() throws {
        let diagram = try AgentGanttDiagram(source: """
            gantt
                title A Gantt Diagram
                dateFormat YYYY-MM-DD
                axisFormat %m/%d
                excludes weekends
                section Section
                A task           :a1, 2014-01-01, 30d
                Another task     :after a1, 20d
                section Another
                Task in sec      :2014-01-12, 12d
                another task     :24d
            """)
        XCTAssertEqual(diagram.title, "A Gantt Diagram")
        XCTAssertEqual(diagram.axisFormat, "%m/%d")
        XCTAssertEqual(diagram.sections, ["Section", "Another"])
        XCTAssertEqual(diagram.tasks.map(\.name), ["A task", "Another task", "Task in sec", "another task"])
        XCTAssertEqual(diagram.tasks.map(\.section), [0, 0, 1, 1])
        XCTAssertEqual(diagram.tasks[0].id, "a1")
        let start = try date("2014-01-01")
        XCTAssertEqual(diagram.tasks[0].start, start)
        XCTAssertEqual(diagram.tasks[0].end, start + 30 * day)
        XCTAssertEqual(diagram.tasks[1].start, diagram.tasks[0].end)
        XCTAssertEqual(diagram.tasks[1].end, diagram.tasks[1].start + 20 * day)
        XCTAssertEqual(diagram.tasks[2].start, try date("2014-01-12"))
        XCTAssertEqual(diagram.tasks[3].start, diagram.tasks[2].end)
    }

    func testTagsAndExplicitEndDates() throws {
        let diagram = try AgentGanttDiagram(source: """
            gantt
            Done thing      :done,    des1, 2014-01-06,2014-01-08
            Active thing    :active,  des2, 2014-01-09, 3d
            Critical        :crit, done, 2014-01-06, 24h
            Release         :milestone, m1, 2014-01-12, 0d
            """)
        let tasks = diagram.tasks
        XCTAssertTrue(tasks[0].done)
        XCTAssertEqual(tasks[0].end - tasks[0].start, 2 * day)
        XCTAssertTrue(tasks[1].active)
        XCTAssertTrue(tasks[2].critical && tasks[2].done)
        XCTAssertEqual(tasks[2].end - tasks[2].start, day)
        XCTAssertTrue(tasks[3].milestone)
        XCTAssertEqual(tasks[3].end, tasks[3].start)
    }

    func testAfterSeveralTasksAndUntil() throws {
        let diagram = try AgentGanttDiagram(source: """
            gantt
            First  :a, 2024-03-01, 2d
            Second :b, 2024-03-01, 5d
            Third  :c, after a b, 1w
            Fourth :2024-03-02, until c
            """)
        XCTAssertEqual(diagram.tasks[2].start, diagram.tasks[1].end)
        XCTAssertEqual(diagram.tasks[2].end - diagram.tasks[2].start, 7 * day)
        XCTAssertEqual(diagram.tasks[3].end, diagram.tasks[2].start)
    }

    func testDurationsAndDates() throws {
        XCTAssertEqual(AgentGanttDiagram.parseDuration("3d"), 3 * day)
        XCTAssertEqual(AgentGanttDiagram.parseDuration("2w"), 14 * day)
        XCTAssertEqual(AgentGanttDiagram.parseDuration("12h"), 12 * 3_600)
        XCTAssertEqual(AgentGanttDiagram.parseDuration("30m"), 1_800)
        XCTAssertEqual(AgentGanttDiagram.parseDuration("1.5d"), 1.5 * day)
        XCTAssertNil(AgentGanttDiagram.parseDuration("d"))
        XCTAssertNil(AgentGanttDiagram.parseDuration("-3d"))
        XCTAssertNil(AgentGanttDiagram.parseDuration("3 days"))
        XCTAssertEqual(try date("2024-01-02 06:30") - date("2024-01-02"), 6.5 * 3_600)
        XCTAssertEqual(try date("1970-01-02"), day)
        XCTAssertNil(AgentGanttDiagram.parseDate("2024-13-01"))
        XCTAssertNil(AgentGanttDiagram.parseDate("01/02/2024"))
    }

    func testAxisFormat() throws {
        let time = try date("2024-03-05 14:07")
        XCTAssertEqual(AgentGanttDiagram.format(time, "%Y-%m-%d"), "2024-03-05")
        XCTAssertEqual(AgentGanttDiagram.format(time, "%b %e, %H:%M"), "Mar 5, 14:07")
        XCTAssertEqual(AgentGanttDiagram.format(time, "%a %I%p %%"), "Tue 02PM %")
    }

    func testUnknownTaskIDReportsItsLine() {
        XCTAssertThrowsError(try AgentGanttDiagram(source: "gantt\nA :a, 2024-01-01, 1d\nB :after zz, 2d")) { error in
            XCTAssertEqual((error as? AgentDiagramError)?.line, 3)
        }
    }

    func testBadDatesAndShapesReportTheirLines() {
        let cases: [(String, Int)] = [
            ("gantt\nA : 2024-99-01, 1d", 2),
            ("gantt\ntitle x\nA : 3d", 3),
            ("gantt\nA : 2024-01-01, soon", 2),
            ("gantt\nA : 2024-01-05, 2024-01-01", 2),
            ("gantt\nA : a, b, c, d, e", 2),
            ("gantt\nsection S\nno colon here", 3),
        ]
        for (source, line) in cases {
            XCTAssertThrowsError(try AgentGanttDiagram(source: source), source) { error in
                XCTAssertEqual((error as? AgentDiagramError)?.line, line, source)
            }
        }
        XCTAssertThrowsError(try AgentGanttDiagram(source: "gantt\ntitle Empty"))
    }

    func testBarsAreOrderedByStart() throws {
        let diagram = try AgentGanttDiagram(source: """
            gantt
            section One
            A :a, 2024-01-01, 3d
            B :after a, 2d
            section Two
            C :c, after a, 4d
            D :after c, 1d
            """)
        let geometry = diagram.geometry(maxWidth: 700, style: style)
        XCTAssertEqual(geometry.bars.count, 4)
        let order = diagram.tasks.indices.sorted { diagram.tasks[$0].start < diagram.tasks[$1].start }
        let xs = order.map { geometry.bars[$0].minX }
        XCTAssertEqual(xs, xs.sorted())
        for (upper, lower) in zip(geometry.bars, geometry.bars.dropFirst()) {
            XCTAssertLessThan(upper.maxY, lower.minY)
        }
        XCTAssertEqual(geometry.sectionRects.count, 2)
        XCTAssertEqual(geometry.bars[1].minX, geometry.bars[0].maxX, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(geometry.bars[0].minX, geometry.chartRect.minX)
        XCTAssertLessThanOrEqual(geometry.bars.map(\.maxX).max() ?? 0, geometry.chartRect.maxX + 0.5)
    }

    func testTicksAreOrderedAndInsideTheChart() throws {
        let diagram = try AgentGanttDiagram(source: "gantt\nLong :2024-01-01, 120d\nShort :2024-02-01, 2d")
        let geometry = diagram.geometry(maxWidth: 800, style: style)
        XCTAssertGreaterThan(geometry.ticks.count, 1)
        let xs = geometry.ticks.map(\.x)
        XCTAssertEqual(xs, xs.sorted())
        XCTAssertGreaterThanOrEqual(xs.first ?? 0, geometry.chartRect.minX)
        XCTAssertLessThanOrEqual(xs.last ?? 0, geometry.chartRect.maxX + 0.5)
        let hours = try AgentGanttDiagram(source: "gantt\nQuick :2024-01-01 09:00, 6h").geometry(maxWidth: 800, style: style)
        XCTAssertTrue(hours.ticks.first?.label.contains(":") == true)
    }

    func testRenderingPaintsPixels() throws {
        let diagram = try AgentGanttDiagram(source: """
            gantt
            title Release
            section Build
            Compile :done, a, 2024-05-01, 2d
            Test    :active, b, after a, 3d
            section Ship
            Hotfix  :crit, c, after b, 1d
            Launch  :milestone, after c, 0d
            """)
        let painted = try AgentDiagramTextRendering.paintedPixels(diagram.layout(maxWidth: 600, style: style))
        XCTAssertGreaterThan(painted, 2_000)
    }
}
