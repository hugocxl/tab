import AppKit
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentResponsePerformanceTests: XCTestCase {
    private let source = """
    A completed paragraph with **formatting**.

    ```swift
    let complete = true
    let longLine = "A deliberately long line that should wrap in a narrow response column and retain its own native text selection."
    ```

    | Name | State |
    | --- | --- |
    | Completed table | Ready |

    The streaming tail
    """

    func testTrailingStreamUpdatesOnlyOneSectionAndReusesCompletedMeasurements() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        let theme = AppTheme(systemIsDark: true)
        response.setContent(source, theme: theme)
        let height = response.height(for: 640)
        response.frame = NSRect(x: 0, y: 0, width: 640, height: height)
        response.layoutSubtreeIfNeeded()
        let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        code.text.setSelectedRange(NSRange(location: 0, length: 3))
        let initialUpdates = response.sectionUpdateCount
        let initialMeasurements = response.sectionMeasurementCount
        let initialLineScans = code.longestLineScanCount
        XCTAssertEqual(initialUpdates, 4, "The fixture has prose, code, table, and trailing prose")

        for _ in 0..<50 { _ = response.height(for: 640) }
        XCTAssertEqual(response.sectionMeasurementCount, initialMeasurements)
        for token in 1...25 {
            response.setContent(source + String(repeating: " token", count: token), theme: theme)
            _ = response.height(for: 640)
        }
        XCTAssertEqual(response.sectionUpdateCount - initialUpdates, 25,
                       "Completed prose, code and table must not rebuild attributed text")
        XCTAssertEqual(response.sectionMeasurementCount - initialMeasurements, 25,
                       "Only the growing tail should run TextKit measurement")
        XCTAssertEqual(code.longestLineScanCount, initialLineScans)
        XCTAssertEqual(code.text.selectedRange(), NSRange(location: 0, length: 3))
        XCTAssertTrue(code === response.subviews.compactMap { $0 as? AgentResponseCode }.first)

        let beforeResize = response.sectionMeasurementCount
        _ = response.height(for: 360)
        XCTAssertEqual(response.sectionMeasurementCount - beforeResize, 4)
        XCTAssertEqual(code.longestLineScanCount, initialLineScans,
                       "A width change must not rescan unchanged source lines")
        for _ in 0..<50 { _ = response.height(for: 360) }
        XCTAssertEqual(response.sectionMeasurementCount - beforeResize, 4)
    }

    func testWrapStateSurvivesEvictionAndRestoresSilently() throws {
        _ = NSApplication.shared
        let theme = AppTheme(systemIsDark: true)
        let original = AgentResponseView(frame: .zero)
        original.setContent(source, theme: theme)
        let unwrappedHeight = original.height(for: 280)
        let code = try XCTUnwrap(original.subviews.compactMap { $0 as? AgentResponseCode }.first)
        var userChanges = 0
        original.onHeightChanged = { userChanges += 1 }
        code.wrap.perform()
        XCTAssertEqual(userChanges, 1)
        XCTAssertTrue(code.wrapped)
        let metadata = original.wrappedCodeSections
        XCTAssertEqual(metadata, [1], "Indices address all response sections, not just code sections")

        let recreated = AgentResponseView(frame: .zero)
        recreated.setContent(source, theme: theme)
        var restoreCallbacks = 0
        recreated.onHeightChanged = { restoreCallbacks += 1 }
        recreated.wrappedCodeSections = metadata
        let wrappedHeight = recreated.height(for: 280)
        XCTAssertEqual(restoreCallbacks, 0, "Restoration must not recursively reflow the virtualizer")
        XCTAssertEqual(recreated.wrappedCodeSections, metadata)
        XCTAssertGreaterThan(wrappedHeight, unwrappedHeight)

        let measured = recreated.sectionMeasurementCount
        recreated.wrappedCodeSections = metadata
        _ = recreated.height(for: 280)
        XCTAssertEqual(recreated.sectionMeasurementCount, measured, "Idempotent restore must not invalidate caches")
        recreated.wrappedCodeSections = []
        _ = recreated.height(for: 280)
        XCTAssertEqual(recreated.sectionMeasurementCount, measured + 1, "Only the changed code section is remeasured")
        XCTAssertEqual(restoreCallbacks, 0)
    }

    func testThemeInvalidatesSectionCachesButDoesNotRescanCodeWidth() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        let catalog = ThemeCatalog.load(customDirectory: nil)
        let dark = AppTheme(catalog: catalog, systemIsDark: true)
        let light = AppTheme(catalog: catalog, systemIsDark: false)
        XCTAssertNotEqual(dark.palette, light.palette)
        response.setContent(source, theme: dark)
        _ = response.height(for: 640)
        let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        let updates = response.sectionUpdateCount
        let measurements = response.sectionMeasurementCount
        let lineScans = code.longestLineScanCount
        response.setContent(source, theme: light)
        _ = response.height(for: 640)
        XCTAssertEqual(response.sectionUpdateCount, updates + 4)
        XCTAssertEqual(response.sectionMeasurementCount, measurements + 4)
        XCTAssertEqual(code.longestLineScanCount, lineScans)
        let afterTheme = response.sectionMeasurementCount
        _ = response.height(for: 640)
        XCTAssertEqual(response.sectionMeasurementCount, afterTheme)
    }
}
