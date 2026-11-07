import TabProtocol
import XCTest
@testable import TabMobileUI

final class TerminalKeyboardTests: XCTestCase {
    func testOneTapHoldsAModifierForTheNextKeyOnly() {
        var latch = TerminalKeyLatch()
        latch.tap(.control, at: 0)
        XCTAssertEqual(latch.consume(), [.control])
        XCTAssertEqual(latch.consume(), [])
    }

    func testDoubleTapLocksUntilTappedAgain() {
        var latch = TerminalKeyLatch()
        latch.tap(.control, at: 0)
        latch.tap(.control, at: 0.2)
        XCTAssertEqual(latch.consume(), [.control])
        XCTAssertEqual(latch.consume(), [.control])
        latch.tap(.control, at: 5)
        XCTAssertEqual(latch.consume(), [])
    }

    func testSlowSecondTapTurnsTheModifierOff() {
        var latch = TerminalKeyLatch()
        latch.tap(.alt, at: 0)
        latch.tap(.alt, at: 1)
        XCTAssertEqual(latch.active, [])
    }

    /// A tap on another modifier between two taps doesn't lock the first.
    func testTapsOnDifferentModifiersNeverLock() {
        var latch = TerminalKeyLatch()
        latch.tap(.shift, at: 0)
        latch.tap(.control, at: 0.1)
        latch.tap(.shift, at: 0.2)
        XCTAssertEqual(latch.locked, [])
        XCTAssertEqual(latch.consume(), [.control])
    }

    /// Every named key in the grid is one the server's Ghostty encoder knows.
    func testGridKeysUseTheDesktopNames() {
        let known = Set(TerminalKeys.named.values)
        let names = (TerminalKeyboardLayout.main + TerminalKeyboardLayout.functions).joined().compactMap { key in
            if case .key(let name, _, _, _, _) = key { return name }
            return nil
        }
        XCTAssertFalse(names.isEmpty)
        for name in names { XCTAssertTrue(known.contains(name), name) }
    }

    func testEveryRowIsFullWidth() {
        for row in TerminalKeyboardLayout.main + TerminalKeyboardLayout.functions {
            XCTAssertEqual(row.count, 8)
        }
    }
}
