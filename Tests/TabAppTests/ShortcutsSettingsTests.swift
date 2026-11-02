import TabCore
import XCTest
@testable import TabApp

final class ShortcutsSettingsTests: XCTestCase {
    func testSearchUsesReboundKeysAndAlternateDefaults() throws {
        let shortcut = ShortcutId.previousPrompt.definition
        let defaults = Keymap()
        XCTAssertTrue(ShortcutFilter.matches(shortcut, query: "cmd+shift+up", keymap: defaults))
        let rebound = try defaults.withBinding(shortcut.name, KeyChord("cmd-ctrl-alt-f9"))
        XCTAssertTrue(ShortcutFilter.matches(shortcut, query: "cmd+ctrl+alt+f9", keymap: rebound))
        XCTAssertFalse(ShortcutFilter.matches(shortcut, query: "cmd+shift+up", keymap: rebound))
        XCTAssertFalse(ShortcutFilter.matches(shortcut, query: "cmd+up", keymap: rebound))
    }

    func testCategorySearchKeepsOnlyMatchingGroups() {
        let keymap = Keymap()
        let matches = ShortcutCatalog.all.filter {
            ShortcutFilter.matches($0, query: "Text Editing", keymap: keymap)
        }
        XCTAssertFalse(matches.isEmpty)
        XCTAssertTrue(matches.allSatisfy { $0.group == .textEditing })
        let items = SettingsCatalog.shortcutItems()
        for shortcut in matches {
            XCTAssertEqual(items.first { $0.id == "shortcut.\(shortcut.name)" }?.section, shortcut.group.title)
        }
        XCTAssertTrue(ShortcutCatalog.all.allSatisfy {
            !ShortcutFilter.matches($0, query: "zzz-no-such-shortcut", keymap: keymap)
        })
    }
}
