import AppKit
import TabCore

extension AppModel {
    /// The sidebar's New Tab menu: each item opens a new tab, a new card.
    func newTabMenu() -> NSMenu {
        NSMenu.make(PaneKind.created.map { kind in
            ClosureMenuItem("\(kind.name) Tab", enabled: kind != .browser || settings.browser.enabled) { [weak self] in
                self?.newTab(kind)
            }
        })
    }

    /// Items adding a pane to an existing tab: `project`'s, or the Home tab
    /// `tab`.
    func newPaneItems(in project: ProjectId, tab: TabId? = nil) -> [NSMenuItem] {
        PaneKind.created.map { kind in
            ClosureMenuItem(kind.name, enabled: kind != .browser || settings.browser.enabled) { [weak self] in
                self?.newPane(kind, in: project, tab: tab)
            }
        }
    }

    /// A New Pane submenu of `newPaneItems`.
    func newPaneSubmenu(in project: ProjectId, tab: TabId? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "New Pane", action: nil, keyEquivalent: "")
        item.submenu = NSMenu.make(newPaneItems(in: project, tab: tab))
        return item
    }
}
