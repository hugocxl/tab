import AppKit
import TabClient
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class ComponentsTests: XCTestCase {
    func testSliderPreviewsWhileDraggingAndCommitsOnRelease() {
        let slider = Slider(value: 10, range: 0...100, step: 1, suffix: "%", label: "Opacity")
        var previews: [Double] = []
        var commits: [Double] = []
        slider.onPreview = { previews.append($0) }
        slider.onCommit = { commits.append($0) }
        slider.beginDrag()
        slider.drag(to: 0.5)
        slider.drag(to: 0.504)
        slider.drag(to: 0.75)
        XCTAssertEqual(previews, [50, 75])
        XCTAssertTrue(commits.isEmpty)
        slider.endDrag()
        XCTAssertEqual(commits, [75])
        XCTAssertEqual(slider.displayText, "75%")
        XCTAssertEqual(Slider.format(0.5, step: 0.01), "0.5")
    }

    func testShortcutRecorderKeepsChordWhenRefused() throws {
        let original = try KeyChord("cmd-d")
        let recorder = ShortcutRecorder(chord: original, label: "Split")
        recorder.onRecord = { $0.rawValue == "cmd-t" ? "Taken" : nil }
        var errors: [String?] = []
        recorder.onError = { errors.append($0) }
        recorder.record(try KeyChord("cmd-t"))
        XCTAssertEqual(recorder.chord, original)
        XCTAssertEqual(errors.last, "Taken")
        recorder.record(try KeyChord("cmd-shift-d"))
        XCTAssertEqual(recorder.chord?.rawValue, "cmd-shift-d")
        XCTAssertEqual(recorder.title, "⇧⌘D")
    }

    func testChordFromKeyEvent() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: "P", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35
        ))
        XCTAssertEqual(KeyChord(event: event)?.rawValue, "cmd-shift-p")
        let arrow = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option, .function], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123
        ))
        XCTAssertEqual(KeyChord(event: arrow)?.rawValue, "alt-left")
        XCTAssertEqual(KeyCap.symbols(for: try KeyChord("cmd-shift-n")), ["⇧", "⌘", "N"])
    }

    func testControlsReportChanges() {
        var segment = -1
        let pill = SegmentedPill(["Close sessions", "Detach"], selected: 0) { segment = $0 }
        pill.select(1)
        XCTAssertEqual(segment, 1)
        pill.select(1)
        XCTAssertEqual(segment, 1)

        var on: Bool?
        let toggle = Switch(isOn: false, label: "Confirm") { on = $0 }
        toggle.toggle()
        XCTAssertEqual(on, true)

        var chosen: String?
        let popUp = PopUp(items: [.init(id: "a", title: "A"), .init(id: "b", title: "B")], selected: "a", label: "Pick") { chosen = $0 }
        XCTAssertEqual(popUp.makeMenu().items.first { $0.state == .on }?.title, "A")
        popUp.choose("b")
        XCTAssertEqual(chosen, "b")
        XCTAssertEqual(popUp.selectedTitle, "B")
    }

    func testQRCodeViewDrawsTheCode() throws {
        let code = try XCTUnwrap(QRCode("tab://pair?v=1&h=10.0.0.2&p=7419"))
        let view = QRCodeView(code: code)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var dark = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) where (bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5 {
                dark += 1
            }
        }
        XCTAssertGreaterThan(dark, 100)
    }
}
