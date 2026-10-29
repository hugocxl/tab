import AppKit
import XCTest
import TabCore
import TabProtocol
@testable import TabApp

final class TerminalKeyMappingTests: XCTestCase {
    private func key(_ code: UInt16, _ characters: String, unshifted: String? = nil, flags: NSEvent.ModifierFlags = [],
                     option: OptionAsAlt = .both) -> KeyEvent {
        KeyMapping.keyEvent(keyCode: code, characters: characters, unshifted: unshifted ?? characters, flags: flags,
                            optionAsAlt: option)
    }

    func testLettersCarryTextAndUnshiftedCodepoint() {
        let plain = key(0, "a")
        XCTAssertEqual(plain.key, "a")
        XCTAssertEqual(plain.text, "a")
        XCTAssertEqual(plain.unshiftedCodepoint, UInt32(UInt8(ascii: "a")))
        XCTAssertEqual(plain.modifiers, [])

        let shifted = key(0, "A", unshifted: "a", flags: .shift)
        XCTAssertEqual(shifted.key, "a")
        XCTAssertEqual(shifted.text, "A")
        XCTAssertEqual(shifted.consumedModifiers, .shift)

        let control = key(8, "\u{03}", unshifted: "c", flags: .control)
        XCTAssertEqual(control.key, "c")
        XCTAssertEqual(control.text, "c")
        XCTAssertEqual(control.modifiers, .control)
        XCTAssertEqual(control.consumedModifiers, [])
    }

    func testNamedKeysSendNoText() {
        let enter = key(36, "\r")
        XCTAssertEqual(enter.key, "enter")
        XCTAssertEqual(enter.text, "")
        XCTAssertEqual(enter.unshiftedCodepoint, 0)
        for (code, name) in [(126 as UInt16, "arrow_up"), (125, "arrow_down"), (123, "arrow_left"), (124, "arrow_right")] {
            let arrow = key(code, "\u{F700}")
            XCTAssertEqual(arrow.key, name)
            XCTAssertEqual(arrow.text, "")
            XCTAssertNoThrow(try TerminalInput.key(arrow).validate())
        }
        XCTAssertEqual(key(126, "\u{F700}", flags: .shift).modifiers, .shift)
        XCTAssertEqual(key(49, " ").text, " ")
        XCTAssertEqual(key(18, "1").key, "digit_1")
        XCTAssertEqual(key(27, "-").key, "minus")
    }

    func testOptionAsAltFollowsTheSettingAndSide() {
        let leftOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | KeyMapping.leftOption)
        let rightOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | KeyMapping.rightOption)

        let alt = key(11, "∫", unshifted: "b", flags: leftOption, option: .both)
        XCTAssertTrue(alt.optionAsAlt)
        XCTAssertEqual(alt.text, "b")
        XCTAssertEqual(alt.modifiers, .alt)
        XCTAssertEqual(alt.consumedModifiers, [])

        let composed = key(11, "∫", unshifted: "b", flags: leftOption, option: .none)
        XCTAssertFalse(composed.optionAsAlt)
        XCTAssertEqual(composed.text, "∫")
        XCTAssertEqual(composed.consumedModifiers, .alt)

        XCTAssertTrue(key(11, "∫", unshifted: "b", flags: leftOption, option: .left).optionAsAlt)
        XCTAssertFalse(key(11, "∫", unshifted: "b", flags: rightOption, option: .left).optionAsAlt)
        XCTAssertTrue(key(11, "∫", unshifted: "b", flags: rightOption, option: .right).optionAsAlt)

        let shiftedAlt = key(11, "ı", unshifted: "b", flags: [leftOption, .shift], option: .both)
        XCTAssertEqual(shiftedAlt.text, "B")
    }

    func testChordsUseKeyChordSyntax() {
        XCTAssertEqual(KeyMapping.chord(keyCode: 40, unshifted: "k", flags: .command), try KeyChord("cmd-k"))
        XCTAssertEqual(KeyMapping.chord(keyCode: 36, unshifted: "\r", flags: .shift), try KeyChord("shift-enter"))
        XCTAssertEqual(KeyMapping.chord(keyCode: 51, unshifted: "\u{7F}", flags: .command), try KeyChord("cmd-backspace"))
        XCTAssertEqual(KeyMapping.chord(keyCode: 27, unshifted: "-", flags: .command), try KeyChord("cmd-minus"))
        XCTAssertEqual(KeyMapping.chord(keyCode: 5, unshifted: "g", flags: [.command, .shift]),
                       try KeyChord("cmd-shift-g"))
    }

    @MainActor
    func testCommandKeysNeverReachTheProgramAndBindingsWin() throws {
        let view = TerminalView(settings: TerminalFixtures.settings(), palette: TerminalPalette())
        let host = RecordingHost()
        view.host = host
        view.setGrid(TerminalFixtures.grid([[TerminalFixtures.run("$ ")]]))

        view.keyDown(with: try event(keyCode: 7, characters: "x", flags: .command))
        XCTAssertTrue(host.inputs.isEmpty, "Cmd+X is an app shortcut, not terminal input")

        view.keyDown(with: try event(keyCode: 40, characters: "k", flags: .command))
        XCTAssertEqual(host.commands, [.clearScreen])

        view.keyDown(with: try event(keyCode: 36, characters: "\r", flags: .shift))
        XCTAssertEqual(host.inputs, [.bytes(Data([0x0A]))])

        view.keyDown(with: try event(keyCode: 126, characters: "\u{F700}", flags: .command))
        XCTAssertEqual(host.commands, [.clearScreen, .previousPrompt])

        host.inputs = []
        view.keyDown(with: try event(keyCode: 126, characters: "\u{F700}", flags: []))
        guard case .key(let arrow)? = host.inputs.first else { return XCTFail("arrow not sent") }
        XCTAssertEqual(arrow.key, "arrow_up")

        var settings = TerminalFixtures.settings()
        settings.keybindings = TerminalBindings(bindings: [try KeyChord("cmd-k"): .text([0x41])], clearDefaults: true)
        view.configure(settings: settings, palette: TerminalPalette())
        host.inputs = []
        view.keyDown(with: try event(keyCode: 40, characters: "k", flags: .command))
        XCTAssertEqual(host.inputs, [.bytes(Data([0x41]))])
        XCTAssertNil(view.handledShortcut(try event(keyCode: 36, characters: "\r", flags: .shift)),
                     "Clearing the defaults drops Shift+Return")
        XCTAssertFalse(view.canHandle(try event(keyCode: 7, characters: "x", flags: .command)))
        XCTAssertTrue(view.canHandle(try event(keyCode: 7, characters: "x", flags: .control)))
    }

    private func event(keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }
}
