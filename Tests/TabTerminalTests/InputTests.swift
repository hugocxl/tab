import TabProtocol
import XCTest
@testable import TabTerminal

final class InputTests: XCTestCase {
    private func key(_ name: String, text: String? = nil, modifiers: KeyModifiers = [], action: KeyAction = .press)
        -> KeyEvent
    {
        let single = name.unicodeScalars.count == 1
        return KeyEvent(
            key: name, action: action, modifiers: modifiers, text: text ?? (single ? name : ""),
            unshiftedCodepoint: single ? name.unicodeScalars.first!.value : 0, optionAsAlt: true)
    }

    private func encoded(_ terminal: Terminal, _ event: KeyEvent) throws -> String {
        String(decoding: try terminal.encodeKey(event), as: UTF8.self)
    }

    func testEnterArrowsAndApplicationCursorMode() throws {
        let terminal = try makeTerminal(cols: 80, rows: 24)
        XCTAssertEqual(try encoded(terminal, key("enter")), "\r")
        XCTAssertEqual(try encoded(terminal, key("arrow_up")), "\u{1b}[A")
        XCTAssertEqual(try encoded(terminal, key("left")), "\u{1b}[D")
        terminal.feed("\u{1b}[?1h")
        XCTAssertEqual(try encoded(terminal, key("arrow_up")), "\u{1b}OA")
        XCTAssertEqual(try encoded(terminal, key("arrow_right")), "\u{1b}OC")
        terminal.feed("\u{1b}[?1l\u{1b}[?67h")
        XCTAssertEqual(try encoded(terminal, key("arrow_up")), "\u{1b}[A")
        XCTAssertEqual(try encoded(terminal, key("backspace")), "\u{08}")
        XCTAssertEqual(try encoded(terminal, key("f1")), "\u{1b}OP")
        XCTAssertEqual(try encoded(terminal, key("unknown", text: "")), "")
    }

    func testControlAndOptionAsAlt() throws {
        let terminal = try makeTerminal(cols: 80, rows: 24)
        XCTAssertEqual(try encoded(terminal, key("c", modifiers: .control)), "\u{03}")
        XCTAssertEqual(try encoded(terminal, key("b", modifiers: .alt)), "\u{1b}b")
        var composed = key("b", text: "∫", modifiers: .alt)
        composed.optionAsAlt = false
        composed.consumedModifiers = .alt
        XCTAssertEqual(try encoded(terminal, composed), "∫")
        XCTAssertEqual(try encoded(terminal, key("é")), "é")
    }

    func testKittyKeyboardProtocolWhenEnabled() throws {
        let terminal = try makeTerminal(cols: 80, rows: 24)
        terminal.feed("\u{1b}[>3u")
        XCTAssertEqual(try encoded(terminal, key("enter")), "\r")
        XCTAssertEqual(try encoded(terminal, key("enter", action: .release)), "")
        terminal.feed("\u{1b}[<u\u{1b}[>31u")
        XCTAssertEqual(try encoded(terminal, key("a", modifiers: .control)), "\u{1b}[97;5u")
        XCTAssertEqual(try encoded(terminal, key("a")), "\u{1b}[97;;97u")
        XCTAssertEqual(try encoded(terminal, key("a", action: .release)), "\u{1b}[97;1:3u")
        terminal.feed("\u{1b}[<u")
        XCTAssertEqual(try encoded(terminal, key("a")), "a")
    }

    func testLongTextGrowsTheEncodeBuffer() throws {
        let terminal = try makeTerminal(cols: 80, rows: 24)
        for length in [127, 128, 129, 4096] {
            let text = String(repeating: "x", count: length)
            XCTAssertEqual(try encoded(terminal, key("a", text: text)), text)
        }
    }

    func testPasteFollowsBracketedPasteAndStripsUnsafeBytes() throws {
        let terminal = try makeTerminal(cols: 80, rows: 24)
        let text = "one\r\ntwo\n\u{1b}[201~\0\u{03}\u{15}\u{009b}201~界\t"
        XCTAssertEqual(String(decoding: try terminal.encodePaste(text), as: UTF8.self), "one\rtwo\r [201~    201~界\t")
        terminal.feed("\u{1b}[?2004h\u{1b}[?1004h")
        XCTAssertEqual(
            String(decoding: try terminal.encodePaste(text), as: UTF8.self),
            "\u{1b}[200~one\ntwo\n [201~    201~界\t\u{1b}[201~")
        XCTAssertEqual(try terminal.encodePaste(""), Data())
        XCTAssertEqual(try terminal.encodeText("ls"), Data("ls".utf8))
        XCTAssertEqual(try terminal.encodeText("a\nb"), Data("\u{1b}[200~a\nb\u{1b}[201~".utf8))
        XCTAssertEqual(try terminal.encodeFocus(true), Data("\u{1b}[I".utf8))
        terminal.feed("\u{1b}[?1004l")
        XCTAssertEqual(try terminal.encodeFocus(false), Data())
    }

    func testMouseIsEncodedOnlyWhileTracking() throws {
        let terminal = try makeTerminal(cols: 80, rows: 24)
        let press = MouseEvent(action: .press, button: .left, col: 2, row: 3)
        XCTAssertEqual(try terminal.encodeMouse(press), Data())
        terminal.feed("\u{1b}[?1000h")
        XCTAssertEqual(try terminal.inputModes().mouseTracking, true)
        XCTAssertEqual(try terminal.encodeMouse(press), Data("\u{1b}[M #$".utf8))
        terminal.feed("\u{1b}[?1006h")
        XCTAssertEqual(try terminal.encodeMouse(press), Data("\u{1b}[<0;3;4M".utf8))
        let release = MouseEvent(action: .release, button: .left, col: 2, row: 3)
        XCTAssertEqual(try terminal.encodeMouse(release), Data("\u{1b}[<0;3;4m".utf8))
        let wheel = MouseEvent(action: .scroll, scroll: .down, col: 2, row: 3)
        XCTAssertEqual(try terminal.encodeMouse(wheel), Data("\u{1b}[<65;3;4M".utf8))
        var modified = MouseEvent(action: .press, button: .forward, col: 2, row: 3)
        modified.modifiers = [.shift, .alt, .control]
        XCTAssertEqual(try terminal.encodeMouse(modified), Data("\u{1b}[<157;3;4M".utf8))
        let far = MouseEvent(action: .press, button: .left, col: .max, row: .max)
        XCTAssertEqual(try terminal.encodeMouse(far), Data("\u{1b}[<0;80;24M".utf8))
    }

    func testDragsReportHeldButtonsWithButtonTracking() throws {
        let terminal = try makeTerminal(cols: 80, rows: 24)
        terminal.feed("\u{1b}[?1002h\u{1b}[?1006h")
        _ = try terminal.encodeMouse(MouseEvent(action: .press, button: .left, col: 2, row: 3))
        let drag = MouseEvent(action: .motion, button: .left, col: 4, row: 3)
        XCTAssertEqual(try terminal.encodeMouse(drag), Data("\u{1b}[<32;5;4M".utf8))
        _ = try terminal.encodeMouse(MouseEvent(action: .release, button: .left, col: 4, row: 3))
        XCTAssertEqual(try terminal.encodeMouse(MouseEvent(action: .motion, col: 5, row: 3)), Data())
    }

    func testWheelBecomesArrowsOnTheAlternateScreen() throws {
        let terminal = try makeTerminal(cols: 80, rows: 24)
        let wheel = MouseEvent(action: .scroll, scroll: .up, col: 0, row: 0)
        XCTAssertEqual(try terminal.encodeMouse(wheel), Data())
        terminal.feed("\u{1b}[?1049h")
        XCTAssertTrue(try terminal.inputModes().alternateScroll)
        XCTAssertEqual(try terminal.encodeMouse(wheel), Data("\u{1b}[A\u{1b}[A\u{1b}[A".utf8))
        terminal.feed("\u{1b}[?1h")
        XCTAssertEqual(try terminal.encodeMouse(wheel), Data("\u{1b}OA\u{1b}OA\u{1b}OA".utf8))
    }
}
