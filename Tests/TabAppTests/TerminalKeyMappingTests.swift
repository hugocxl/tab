import AppKit
import XCTest
import TabCore
import TabProtocol
import TabTerminal
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

    func testMappedEventsUseGhosttyApplicationCursorAndKittyEncoding() throws {
        let terminal = try TabTerminal.Terminal(size: Size(cols: 80, rows: 24), historyBudgetBytes: 1024)
        let up = key(126, "\u{F700}")
        XCTAssertEqual(try terminal.encodeKey(up), Data("\u{1b}[A".utf8))
        terminal.feed(Data("\u{1b}[?1h".utf8))
        XCTAssertEqual(try terminal.encodeKey(up), Data("\u{1b}OA".utf8))
        terminal.feed(Data("\u{1b}[>31u".utf8))
        XCTAssertEqual(try terminal.encodeKey(key(0, "a")), Data("\u{1b}[97;;97u".utf8))
        XCTAssertEqual(try terminal.encodeKey(key(0, "\u{01}", unshifted: "a", flags: .control)), Data("\u{1b}[97;5u".utf8))
        let repeated = KeyMapping.keyEvent(keyCode: 0, characters: "a", unshifted: "a", flags: [], isRepeat: true, optionAsAlt: .both)
        XCTAssertEqual(try terminal.encodeKey(repeated), Data("\u{1b}[97;1:2;97u".utf8))
        let release = KeyMapping.keyEvent(keyCode: 0, characters: "A", unshifted: "a", flags: .shift,
                                          optionAsAlt: .both, release: true)
        XCTAssertEqual(release.consumedModifiers, [])
        XCTAssertEqual(release.text, "")
        XCTAssertEqual(try terminal.encodeKey(release), Data("\u{1b}[97;2:3u".utf8))
    }

    func testOptionSideMatrixAndShiftedPunctuationReachTheEngine() throws {
        let terminal = try TabTerminal.Terminal(size: Size(cols: 80, rows: 24), historyBudgetBytes: 1024)
        for option in OptionAsAlt.allCases {
            for side in [KeyMapping.leftOption, KeyMapping.rightOption] {
                let flags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | side)
                let mapped = key(11, "∫", unshifted: "b", flags: flags, option: option)
                let alt = option == .both || option == .left && side == KeyMapping.leftOption
                    || option == .right && side == KeyMapping.rightOption
                XCTAssertEqual(try terminal.encodeKey(mapped), Data((alt ? "\u{1b}b" : "∫").utf8))
            }
        }
        let flags: NSEvent.ModifierFlags = [.option, .shift]
        let punctuation = KeyMapping.keyEvent(keyCode: 18, characters: "⁄", unshifted: "1", shifted: "!",
                                              flags: flags, optionAsAlt: .both)
        XCTAssertEqual(punctuation.text, "!")
        XCTAssertEqual(try terminal.encodeKey(punctuation), Data("\u{1b}!".utf8))
        XCTAssertEqual(key(49, " ", flags: .option).text, " ")
        XCTAssertEqual(try terminal.encodeKey(key(49, " ", flags: .option)), Data("\u{1b} ".utf8))
        XCTAssertEqual(try terminal.encodeKey(key(49, "\0", unshifted: " ", flags: .control)), Data([0]))
    }

    @MainActor
    func testIMEReplacementUTF16AndCommitDoNotSendCompositionKeys() {
        let view = TerminalView(settings: TerminalFixtures.settings(), palette: TerminalPalette())
        let host = RecordingHost()
        view.host = host
        view.setGrid(TerminalFixtures.grid([[]]))
        view.setMarkedText("a😀b", selectedRange: NSRange(location: 1, length: 2),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 4))
        XCTAssertTrue(host.inputs.isEmpty)
        view.setMarkedText("界", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 2))
        XCTAssertEqual(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 3), actualRange: nil)?.string, "a界b")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
        view.insertText("c", replacementRange: NSRange(location: 2, length: 1))
        XCTAssertEqual(host.inputs, [.text("a界c")])
        XCTAssertFalse(view.hasMarkedText())
        view.setMarkedText("é", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        view.unmarkText()
        XCTAssertEqual(host.inputs, [.text("a界c"), .text("é")], "unmark commits once, matching Codesh")
    }

    @MainActor
    func testKeyReleaseRemembersPhysicalPressWithoutNSAppCurrentEvent() throws {
        let view = TerminalView(settings: TerminalFixtures.settings(), palette: TerminalPalette())
        let host = RecordingHost()
        view.host = host
        view.setGrid(TerminalFixtures.grid([[]]))
        view.keyDown(with: try event(keyCode: 126, characters: "\u{F700}", flags: []))
        let released = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                      isARepeat: false, keyCode: 126))
        view.keyUp(with: released)
        guard case .key(let key)? = host.inputs.last else { return XCTFail("release missing") }
        XCTAssertEqual(host.inputs.count, 2)
        XCTAssertEqual(key.action, .release)
        XCTAssertEqual(key.key, "arrow_up")
        XCTAssertEqual(key.text, "")
        XCTAssertEqual(key.consumedModifiers, [])
    }

    private func event(keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }
}
