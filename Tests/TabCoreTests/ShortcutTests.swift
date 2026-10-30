import XCTest
@testable import TabCore

final class ShortcutTests: XCTestCase {
    func testEveryShortcutHasOneRowWithParsableDefaultsAndMatchingContexts() throws {
        XCTAssertEqual(ShortcutCatalog.all.map(\.id), ShortcutId.allCases)
        for shortcut in ShortcutCatalog.all {
            XCTAssertEqual(shortcut.keys.count, shortcut.keyContexts.count, shortcut.name)
            XCTAssertFalse(shortcut.contexts.isEmpty, shortcut.name)
            for key in shortcut.keys {
                XCTAssertNoThrow(try KeyChord(key), "\(shortcut.name): \(key)")
            }
            for contexts in shortcut.keyContexts {
                for context in contexts { XCTAssertTrue(shortcut.contexts.contains(context), shortcut.name) }
            }
        }
        XCTAssertEqual(ShortcutId.newTab.label, "New terminal")
        XCTAssertEqual(ShortcutId.textInputSelectAll.label, "Text input select all")
        XCTAssertEqual(ShortcutId.toggleVoiceRecording.definition.feature, .voice)
        XCTAssertEqual(ShortcutCatalog.find("split_right")?.defaultChord?.rawValue, "cmd-d")
    }

    func testDefaultsDoNotCollideWhereTheyApply() {
        let conflicts = ShortcutCatalog.defaultConflicts().map { "\($0.0.rawValue) ↔ \($0.1.rawValue): \($0.2)" }
        // Find and Settings search share cmd-f only across separate windows,
        // and the browser's keys only apply in a browser pane.
        XCTAssertEqual(conflicts, [], "\(conflicts)")
    }

    func testChordsParseCanonicallyAndShowMacGlyphs() throws {
        XCTAssertEqual(try KeyChord("Shift-Cmd-P").rawValue, "cmd-shift-p")
        XCTAssertEqual(try KeyChord("super-k").rawValue, "cmd-k")
        XCTAssertEqual(try KeyChord("cmd-P").rawValue, "cmd-shift-p")
        XCTAssertEqual(try KeyChord("ctrl-cmd-space").rawValue, "cmd-ctrl-space")
        XCTAssertEqual(try KeyChord("cmd-minus").rawValue, "cmd--")
        XCTAssertEqual(try KeyChord("cmd--").rawValue, "cmd--")
        XCTAssertEqual(try KeyChord("alt-Return").rawValue, "alt-enter")
        XCTAssertEqual(try KeyChord("esc").rawValue, "escape")
        XCTAssertEqual(try KeyChord("f12").rawValue, "f12")
        for invalid in ["cmd-cmd-k", "cmd-", "f25", "f01", "cmd-space bar", "ctrl-\u{7}", "hyper-k"] {
            XCTAssertThrowsError(try KeyChord(invalid), invalid)
        }
        let chord = try KeyChord("cmd-shift-p")
        XCTAssertEqual(chord.display, "⇧⌘P")
        XCTAssertEqual(chord.modifiers, [.command, .shift])
        XCTAssertEqual(chord.key, "p")
        XCTAssertEqual(try KeyChord("cmd--").key, "-")
        XCTAssertEqual(ShortcutCatalog.displayChord("ctrl-alt-left"), "⌃⌥←")
        XCTAssertEqual(ShortcutCatalog.displayChord("cmd-enter"), "⌘↩")
        XCTAssertEqual(ShortcutCatalog.displayChord("cmd-ctrl-="), "⌃⌘=")
        XCTAssertThrowsError(try JSONDecoder().decode(KeyChord.self, from: Data(#""cmd-""#.utf8)))
    }

    func testMenusNameEveryCommandOnceAndHideUnavailableFeatures() {
        let menus = ShortcutCatalog.menus(appName: "Tab")
        XCTAssertEqual(menus.map(\.title), ["Tab", "Edit", "File", "View", "Window"])
        XCTAssertTrue(menus[0].items.contains(.shortcut(.quit, title: "Quit Tab")))
        let withoutVoice = ShortcutCatalog.menus(appName: "Tab", available: [.commandLineTool])
        let items = withoutVoice.flatMap(\.items)
        XCTAssertFalse(items.contains(.shortcut(.toggleVoiceRecording, title: "Toggle Voice Recording")))
        XCTAssertFalse(items.contains(.command("check_for_updates", title: "Check for Updates…")))
        let windowItems = menus[4].items.compactMap { item -> ShortcutId? in
            if case .shortcut(let id, _) = item { return id }
            return nil
        }
        XCTAssertTrue(ShortcutId.tabs.allSatisfy(windowItems.contains))
        XCTAssertTrue(ShortcutId.projects.allSatisfy(windowItems.contains))
    }

    // MARK: Keymap

    func testEveryDefaultBindingRoundTripsAndResolvesBothDirections() throws {
        let keymap = Keymap()
        for action in ShortcutCatalog.keymapActions {
            if [.selectCommandOutput, .detachTerminal, .toggleAgentSessions].contains(action) {
                XCTAssertNil(keymap.chord(action))
                continue
            }
            let chord = try KeyChord(XCTUnwrap(keymap.chord(action)).rawValue)
            XCTAssertEqual(keymap.chord(action), chord)
            XCTAssertEqual(keymap.action(for: chord), action, action.rawValue)
        }
        XCTAssertNil(keymap.action(for: try KeyChord("ctrl-alt-f24")))
        XCTAssertNoThrow(try Keymap.fromOverrides([:]))
        XCTAssertEqual(try roundTrip(Keymap()), Keymap())
    }

    func testExistingBindingsTakePrecedenceOverNewerDefaults() throws {
        for project in [ShortcutId.addProject, .previousProject, .nextProject, .selectProject1, .selectProject9, .equalizeSplits] {
            let key = try XCTUnwrap(project.definition.keys.first)
            for existing in [ShortcutId.newTab, .copy] {
                let keymap = try Keymap.fromOverrides([existing.rawValue: key])
                let chord = try KeyChord(key)
                XCTAssertEqual(keymap.chord(existing), chord)
                XCTAssertEqual(keymap.action(for: chord), existing)
                XCTAssertNil(keymap.chord(project), "\(project) yields to \(existing)")
                XCTAssertEqual(try roundTrip(keymap), keymap)
            }
        }
    }

    func testRemovedActionsStillLoadAndUnknownOnesAreRefused() throws {
        let keymap = try Keymap.fromOverrides(["command.tests": "cmd-ctrl-t", "open_configuration": "cmd-ctrl-o"])
        XCTAssertNil(keymap.binding("command.tests"))
        XCTAssertTrue(keymap.overrides.isEmpty)
        XCTAssertThrowsError(try Keymap.fromOverrides(["no_such_action": "cmd-j"]))
        XCTAssertThrowsError(try Keymap.fromOverrides(["split_right": "cmd-"]))
        XCTAssertThrowsError(try Keymap.fromOverrides(["split_right": "cmd-t"]), "two actions on one key")
    }

    func testRebindingResetAndPersistenceKeepContextsAndOtherSections() throws {
        let directory = try TemporaryDirectory()
        let path = try directory.write("settings.json", #"{"window": {"confirmRunningProcess": false}}"#)
        let settings = try Settings.load(path)
        let custom = try settings.keymap.withBinding("new_tab", KeyChord("cmd-n"))
        XCTAssertNil(custom.binding("new_home_tab"))
        XCTAssertThrowsError(try custom.withBinding("close_tab", KeyChord("cmd-n")))
        XCTAssertEqual(custom.conflict(for: "close_tab", chord: try KeyChord("cmd-n")), "new_tab")
        try custom.save(to: path)
        let loaded = try Settings.load(path)
        XCTAssertEqual(loaded.keymap, custom)
        XCTAssertFalse(loaded.window.confirmRunningProcess)
        XCTAssertEqual(loaded.keymap.keys("text_input.copy", context: "TextInput"), ["cmd-c"])
        XCTAssertEqual(loaded.keymap.keys("popover.dismiss", context: "Picker"), ["escape"])
        XCTAssertEqual(loaded.keymap.keys("increase_font_size", context: "WorkspaceTabs"), ["cmd-+", "cmd-=", "cmd-shift-="])
        XCTAssertFalse(loaded.keymap.isDefault("new_tab"))
        XCTAssertThrowsError(try loaded.keymap.withBinding("new_home_tab", nil), "its default is taken")
        let reset = try loaded.keymap.withBinding("new_tab", nil)
        try reset.save(to: path)
        XCTAssertEqual(try Settings.load(path).keymap, Keymap())
        XCTAssertTrue(reset.isDefault("new_tab"))
    }
}
