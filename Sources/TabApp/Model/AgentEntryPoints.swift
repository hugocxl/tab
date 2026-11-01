import AppKit
import TabCore

extension AppModel {
    func newPaneMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("New Terminal") { [weak self] in self?.newTerminal() })
        menu.addItem(ClosureMenuItem("New Agent Tab") { [weak self] in self?.newAgent() })
        menu.addItem(ClosureMenuItem("New Browser") { [weak self] in self?.openBrowser() })
        return menu
    }
}
