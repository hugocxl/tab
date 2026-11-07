import TabProtocol
import XCTest
@testable import TabMobileKit

/// Text typed on the phone reaches a simulator as US keyboard presses.
final class SimulatorKeyboardTests: XCTestCase {
    func testShiftWrapsCapitalsAndSymbols() {
        let shift = SimulatorKeyboard.leftShift
        XCTAssertEqual(SimulatorKeyboard.input(typing: "Hi!"), [
            .key(usage: shift, down: true), .key(usage: 0x0B, down: true), .key(usage: 0x0B, down: false),
            .key(usage: shift, down: false),
            .key(usage: 0x0C, down: true), .key(usage: 0x0C, down: false),
            .key(usage: shift, down: true), .key(usage: 0x1E, down: true), .key(usage: 0x1E, down: false),
            .key(usage: shift, down: false),
        ])
    }

    func testReturnCurledQuotesAndUntypableCharacters() {
        XCTAssertEqual(SimulatorKeyboard.input(typing: "\n"), SimulatorKeyboard.tap(SimulatorKeyboard.returnKey))
        XCTAssertEqual(SimulatorKeyboard.input(typing: "’"), SimulatorKeyboard.input(typing: "'"))
        XCTAssertEqual(SimulatorKeyboard.input(typing: "”"), SimulatorKeyboard.input(typing: "\""))
        XCTAssertEqual(SimulatorKeyboard.input(typing: "é😀"), [])
    }
}
