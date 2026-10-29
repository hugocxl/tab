import AppKit

/// The terminal's right-click menu. The terminal handles its own items
/// (Copy, Paste, Select All, Select Command Output, Find, Clear); the shell
/// says which of its items to show and enable and performs them.
public enum TerminalContextMenu {
    public enum Item: String, CaseIterable, Sendable {
        case copy, paste, selectAll, selectCommandOutput, find, clear
        case splitRight, splitDown, toggleZoom, equalizeSplits
        case setUpProxy, applyProxy, detach, close

        /// Items the terminal performs itself.
        public var isTerminalItem: Bool {
            switch self {
            case .copy, .paste, .selectAll, .selectCommandOutput, .find, .clear: return true
            default: return false
            }
        }

        public var defaultTitle: String {
            switch self {
            case .copy: return "Copy"
            case .paste: return "Paste"
            case .selectAll: return "Select All"
            case .selectCommandOutput: return "Select Command Output"
            case .find: return "Find…"
            case .clear: return "Clear"
            case .splitRight: return "Split Right"
            case .splitDown: return "Split Down"
            case .toggleZoom: return "Maximize Pane"
            case .equalizeSplits: return "Equalize Splits"
            case .setUpProxy: return "Set Up Proxy…"
            case .applyProxy: return "Apply Proxy"
            case .detach: return "Detach Terminal"
            case .close: return "Close Pane"
            }
        }
    }

    /// What the shell contributes: which of its items appear, which are
    /// disabled, and titles that change (Restore Pane, Remove Proxy…).
    public struct ShellItems: Equatable, Sendable {
        public var shown: [Item]
        public var disabled: Set<Item>
        public var titles: [Item: String]

        public init(shown: [Item] = [.splitRight, .splitDown, .toggleZoom, .equalizeSplits, .setUpProxy, .detach, .close],
                    disabled: Set<Item> = [], titles: [Item: String] = [:]) {
            self.shown = shown
            self.disabled = disabled
            self.titles = titles
        }
    }

    /// What the terminal knows about its own items.
    public struct TerminalState: Equatable, Sendable {
        public var hasSelection: Bool
        public var isLive: Bool
        public var hasContent: Bool

        public init(hasSelection: Bool, isLive: Bool, hasContent: Bool) {
            self.hasSelection = hasSelection
            self.isLive = isLive
            self.hasContent = hasContent
        }
    }

    /// The items in menu order, with separators (`nil`) between groups.
    public static func layout(_ shell: ShellItems) -> [Item?] {
        var items: [Item?] = [.copy, .paste, .selectAll, .selectCommandOutput, nil, .find, .clear]
        let layoutGroup = [Item.splitRight, .splitDown, .toggleZoom, .equalizeSplits].filter(shell.shown.contains)
        let proxyGroup = [Item.setUpProxy, .applyProxy].filter(shell.shown.contains)
        let paneGroup = [Item.detach, .close].filter(shell.shown.contains)
        for group in [layoutGroup, proxyGroup, paneGroup] where !group.isEmpty {
            items.append(nil)
            items += group.map(Optional.some)
        }
        return items
    }

    public static func isEnabled(_ item: Item, terminal: TerminalState, shell: ShellItems) -> Bool {
        switch item {
        case .copy: return terminal.hasSelection
        case .paste, .selectCommandOutput, .clear: return terminal.isLive
        case .selectAll, .find: return terminal.hasContent
        default: return !shell.disabled.contains(item)
        }
    }

    /// Builds the menu; choosing an item calls `perform` with it.
    @MainActor
    public static func menu(terminal: TerminalState, shell: ShellItems, perform: @escaping (Item) -> Void) -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false
        let target = MenuTarget(perform)
        for entry in layout(shell) {
            guard let item = entry else {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: shell.titles[item] ?? item.defaultTitle,
                                      action: #selector(MenuTarget.choose(_:)), keyEquivalent: "")
            menuItem.target = target
            menuItem.representedObject = target
            menuItem.identifier = NSUserInterfaceItemIdentifier(item.rawValue)
            menuItem.isEnabled = isEnabled(item, terminal: terminal, shell: shell)
            menu.addItem(menuItem)
        }
        return menu
    }

    /// Keeps the callback alive as long as the menu's items reference it.
    final class MenuTarget: NSObject {
        let perform: (Item) -> Void

        init(_ perform: @escaping (Item) -> Void) {
            self.perform = perform
        }

        @MainActor @objc func choose(_ sender: NSMenuItem) {
            guard let raw = sender.identifier?.rawValue, let item = Item(rawValue: raw) else { return }
            perform(item)
        }
    }
}
