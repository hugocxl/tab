import AppKit

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

extension NSMenu {
    /// A menu with items that enable themselves.
    static func make(_ items: [NSMenuItem], title: String = "") -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
        return menu
    }

    /// Shows the menu under `view`.
    func popUp(below view: NSView) {
        popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
    }
}

extension NSMenuItem {
    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = NSMenu.make(items, title: title)
        return item
    }
}

extension NSTextField {
    /// The width the label's text needs on one line, with the cell's insets.
    var textWidth: CGFloat {
        ceil(attributedStringValue.size().width) + 4
    }
}
