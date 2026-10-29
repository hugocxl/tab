import AppKit
import TabCore

/// Builds the menu bar from the shortcut catalog, with the keymap's keys.
@MainActor
enum MenuBarBuilder {
    /// Commands the responder chain handles with standard selectors.
    static let selectors: [ShortcutId: Selector] = [
        .textInputCut: #selector(NSText.cut(_:)),
        .textInputCopy: #selector(NSText.copy(_:)),
        .textInputPaste: #selector(NSText.paste(_:)),
        .textInputSelectAll: #selector(NSText.selectAll(_:)),
        .quit: #selector(NSApplication.terminate(_:)),
        .hideApp: #selector(NSApplication.hide(_:)),
        .hideOthers: #selector(NSApplication.hideOtherApplications(_:)),
        .showAll: #selector(NSApplication.unhideAllApplications(_:)),
        .minimize: #selector(NSWindow.performMiniaturize(_:)),
        .zoom: #selector(NSWindow.performZoom(_:)),
    ]

    static func build(keymap: Keymap, actions: Actions, available: Set<ShortcutFeature>) -> NSMenu {
        let bar = NSMenu()
        let appName = Release.appName
        for menu in ShortcutCatalog.menus(appName: appName, available: available) {
            let top = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: menu.title)
            if menu.title == appName {
                submenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
                submenu.addItem(.separator())
            }
            for entry in menu.items {
                submenu.addItem(item(entry, keymap: keymap, actions: actions))
            }
            if menu.title == "Window" {
                NSApp.windowsMenu = submenu
            }
            top.submenu = submenu
            bar.addItem(top)
        }
        let help = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(ClosureMenuItem("\(appName) Help") {
            if let url = URL(string: "https://github.com/hugocxl/tab#readme") { NSWorkspace.shared.open(url) }
        })
        help.submenu = helpMenu
        NSApp.helpMenu = helpMenu
        bar.addItem(help)
        return bar
    }

    private static func item(_ entry: ShortcutMenuItem, keymap: Keymap, actions: Actions) -> NSMenuItem {
        switch entry {
        case .separator:
            return .separator()
        case .services:
            let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
            let services = NSMenu(title: "Services")
            item.submenu = services
            NSApp.servicesMenu = services
            return item
        case let .command(id, title):
            guard id == "check_for_updates" else { return NSMenuItem(title: title, action: nil, keyEquivalent: "") }
            return ClosureMenuItem(title) { [weak actions] in actions?.model.updater.checkForUpdates() }
        case let .shortcut(id, title):
            let item: NSMenuItem
            if let selector = selectors[id] {
                item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            } else {
                item = ClosureMenuItem(title) { [weak actions] in actions?.perform(id) }
            }
            if let chord = keymap.chord(id) { apply(chord, to: item) }
            return item
        }
    }

    /// Sets a menu item's key equivalent from a chord.
    static func apply(_ chord: KeyChord, to item: NSMenuItem) {
        guard let key = keyEquivalent(chord.key) else { return }
        item.keyEquivalent = key
        var mask: NSEvent.ModifierFlags = []
        let modifiers = chord.modifiers
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.function) { mask.insert(.function) }
        item.keyEquivalentModifierMask = mask
    }

    static func keyEquivalent(_ key: String) -> String? {
        func scalar(_ value: Int) -> String { String(UnicodeScalar(UInt16(value)).map(Character.init) ?? " ") }
        switch key {
        case "enter": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "escape": return "\u{1b}"
        case "backspace": return "\u{8}"
        case "delete": return scalar(NSDeleteFunctionKey)
        case "left": return scalar(NSLeftArrowFunctionKey)
        case "right": return scalar(NSRightArrowFunctionKey)
        case "up": return scalar(NSUpArrowFunctionKey)
        case "down": return scalar(NSDownArrowFunctionKey)
        case "home": return scalar(NSHomeFunctionKey)
        case "end": return scalar(NSEndFunctionKey)
        case "pageup": return scalar(NSPageUpFunctionKey)
        case "pagedown": return scalar(NSPageDownFunctionKey)
        default:
            if key.count == 1 { return key }
            if key.hasPrefix("f"), let number = Int(key.dropFirst()), (1...24).contains(number) {
                return scalar(NSF1FunctionKey + number - 1)
            }
            return nil
        }
    }
}
