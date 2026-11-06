import TabProtocol
import XCTest
@testable import TabMobileUI

final class TerminalKeysTests: XCTestCase {
    /// Control latched on the accessory bar, then a letter: Ctrl-C.
    func testStickyControlSendsTheLetterAsAControlKey() {
        let event = TerminalKeys.event(for: "C", modifiers: [.control])
        XCTAssertEqual(event?.key, "c")
        XCTAssertEqual(event?.modifiers, [.control])
        XCTAssertEqual(event?.text, "c")
        XCTAssertEqual(event?.unshiftedCodepoint, UInt32(UInt8(ascii: "c")))
    }

    func testStickyAltSpaceAndPunctuation() {
        XCTAssertEqual(TerminalKeys.event(for: " ", modifiers: [.alt])?.key, "space")
        XCTAssertEqual(TerminalKeys.event(for: "/", modifiers: [.control])?.key, "slash")
        XCTAssertNil(TerminalKeys.event(for: "é", modifiers: [.control]))
    }

    /// Named keys keep printable text, so a hardware space types a space.
    func testSpaceIsNamedAndPrintable() {
        XCTAssertEqual(TerminalKeys.named[44], "space")
        XCTAssertTrue(TerminalKeys.isPrintable(" "))
        XCTAssertFalse(TerminalKeys.isPrintable("\r"))
        XCTAssertFalse(TerminalKeys.isPrintable("\u{F700}"))
    }

    func testHardwareKeysUseTheDesktopNames() {
        XCTAssertEqual(TerminalKeys.named[40], "enter")
        XCTAssertEqual(TerminalKeys.named[82], "arrow_up")
        XCTAssertEqual(TerminalKeys.named[58], "f1")
        XCTAssertEqual(TerminalKeys.physical[4], "a")
        XCTAssertEqual(TerminalKeys.physical[39], "digit_0")
    }
}
