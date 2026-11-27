import AppKit
import XCTest
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class TerminalMouseMappingTests: XCTestCase {
    func testReportingModesShiftOverrideAndAlternateScroll() {
        var modes = InputModes()
        XCTAssertFalse(TerminalMouseMapping.reports(flags: [], modes: modes, live: true))
        modes.alternateScroll = true
        XCTAssertFalse(TerminalMouseMapping.reports(flags: [], modes: modes, live: true))
        XCTAssertTrue(TerminalMouseMapping.reports(flags: [], modes: modes, live: true, wheel: true))
        modes.mouseTracking = true
        XCTAssertTrue(TerminalMouseMapping.reports(flags: [], modes: modes, live: true))
        for wheel in [false, true] {
            XCTAssertFalse(TerminalMouseMapping.reports(flags: .shift, modes: modes, live: true, wheel: wheel))
            XCTAssertFalse(TerminalMouseMapping.reports(flags: [], modes: modes, live: false, wheel: wheel))
        }
    }

    func testCellMappingClampsCoordinatesAndRemovesAppModifiers() {
        let state = TerminalRendererTests().state(TerminalFixtures.grid([[], []], cols: 10))
        let rect = state.layout.cellRect(row: 1, column: 3)
        let event = TerminalMouseMapping.event(action: .press, button: .left, location: CGPoint(x: rect.midX, y: rect.midY),
                                               layout: state.layout, flags: [.control, .option, .command, .capsLock])
        XCTAssertEqual(event.col, 3)
        XCTAssertEqual(event.row, 1)
        XCTAssertEqual(event.modifiers, [.control, .alt])
        let outside = TerminalMouseMapping.event(action: .motion, button: nil, location: CGPoint(x: -100, y: 10000),
                                                 layout: state.layout, flags: [])
        XCTAssertEqual(outside.col, 0)
        XCTAssertEqual(outside.row, 1)
    }

    func testTrackpadAndWheelRowsFractionalInputReversalAndFloodLimit() {
        XCTAssertEqual(TerminalMouseMapping.scrollRows(delta: 8, precise: true, cellHeight: 16), 0.5)
        XCTAssertEqual(TerminalMouseMapping.scrollRows(delta: -2, precise: false, cellHeight: 16), -2)
        var scroll = TerminalScrollAccumulator()
        XCTAssertEqual(scroll.consume(0.4, reporting: true), 0)
        XCTAssertEqual(scroll.consume(0.4, reporting: true), 0)
        XCTAssertEqual(scroll.consume(-0.4, reporting: true), 0)
        XCTAssertEqual(scroll.remainder, -0.4, accuracy: 0.001)
        XCTAssertEqual(scroll.consume(-0.7, reporting: true), -1)
        XCTAssertEqual(scroll.consume(10000, reporting: true), 100)
        XCTAssertEqual(scroll.consume(-10000, reporting: true), -100)
        scroll.reset()
        XCTAssertEqual(scroll.consume(0.75, reporting: false), 0)
        XCTAssertEqual(scroll.consume(0.75, reporting: false), 1)
        XCTAssertEqual(scroll.remainder, 0.5)
        XCTAssertEqual(scroll.consume(.infinity, reporting: false), 0)
        scroll.reset()
        let up = scroll.consumeFraction(1.25)
        XCTAssertEqual(up.whole, 1)
        XCTAssertEqual(up.fraction, 0.25, accuracy: 0.001)
        let down = scroll.consumeFraction(-0.5)
        XCTAssertEqual(down.whole, -1, "smooth scrolling keeps the fraction above the row")
        XCTAssertEqual(down.fraction, 0.75, accuracy: 0.001)
    }

    func testClickDragDoubleWordTripleLineAndShiftOverride() throws {
        let view = TerminalView(settings: TerminalFixtures.settings(), palette: TerminalPalette())
        let host = RecordingHost()
        view.host = host
        view.setFrameSize(CGSize(width: 600, height: 100))
        view.setGrid(TerminalFixtures.grid([[TerminalFixtures.run("hello world")]], cols: 20))
        func mouse(_ type: NSEvent.EventType, _ column: Int, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let rect = view.layout.cellRect(row: 0, column: column)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: rect.minX, y: view.bounds.height - rect.midY),
                                                    modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                                    eventNumber: 1, clickCount: clicks, pressure: 1))
        }
        view.mouseDown(with: try mouse(.leftMouseDown, 0))
        XCTAssertNil(view.selection)
        view.mouseDragged(with: try mouse(.leftMouseDragged, 5))
        XCTAssertEqual(view.selectedText, "hello")
        view.mouseUp(with: try mouse(.leftMouseUp, 5))
        view.mouseDown(with: try mouse(.leftMouseDown, 7, clicks: 2))
        XCTAssertEqual(view.selectedText, "world")
        view.mouseUp(with: try mouse(.leftMouseUp, 7))
        view.mouseDown(with: try mouse(.leftMouseDown, 7, clicks: 3))
        XCTAssertEqual(view.selectedText, "hello world")
        view.mouseUp(with: try mouse(.leftMouseUp, 7))
        view.inputModes.mouseTracking = true
        view.clearSelection()
        view.mouseDown(with: try mouse(.leftMouseDown, 2))
        view.mouseUp(with: try mouse(.leftMouseUp, 2))
        XCTAssertEqual(host.inputs.count, 2)
        XCTAssertNil(view.selection)
        view.mouseDown(with: try mouse(.leftMouseDown, 0, flags: .shift))
        view.mouseDragged(with: try mouse(.leftMouseDragged, 5, flags: .shift))
        view.mouseUp(with: try mouse(.leftMouseUp, 5, flags: .shift))
        XCTAssertEqual(view.selectedText, "hello")
        XCTAssertEqual(host.inputs.count, 2)
    }

    func testCopyOnSelectKeepsTheSelectionThroughCopyAndTyping() throws {
        var settings = TerminalFixtures.settings()
        settings.copyOnSelect = true
        let view = TerminalView(settings: settings, palette: TerminalPalette())
        let host = RecordingHost()
        view.host = host
        view.setFrameSize(CGSize(width: 300, height: 100))
        view.setGrid(TerminalFixtures.grid([[TerminalFixtures.run("hello")]]))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var copies: [String] = []
        view.selectionCopyHandler = { copies.append($0) }
        let rect = view.layout.cellRect(row: 0, column: 1)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: rect.midX, y: view.bounds.height - rect.midY),
                                                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                    eventNumber: 1, clickCount: 2, pressure: 1))
        view.mouseDown(with: down)
        view.mouseUp(with: down)
        XCTAssertEqual(copies, ["hello"])
        XCTAssertNotNil(view.selection, "copy on select preserves the selection")
        XCTAssertTrue(view.copySelection(to: pasteboard))
        XCTAssertNotNil(view.selection)
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNotNil(view.selection)
        XCTAssertEqual(host.inputs, [.text("x")])
    }
}
