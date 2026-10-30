import AppKit
import TabCore

extension SettingsModel {
    func buildGeneral(_ b: SettingsPageBuilder) {
        let settings = store.settings
        b.row("close-behavior", b.segmented("close-behavior", ["Close sessions", "Detach"], selected: settings.window.closeBehavior == .detach ? 1 : 0) { [store] index in
            store.setCloseBehavior(index == 1 ? .detach : .closeSession)
        })
        b.row("confirm-process", b.toggle("confirm-process", settings.window.confirmRunningProcess) { [store] in
            store.setConfirmRunningProcess($0)
        })
        b.row("file-opener", fileOpenerPopUp(b))
        b.row("width", b.field("width", Self.number(settings.window.defaultSize.width)) { [store] in store.setWindowSize("width", $0) })
        b.row("height", b.field("height", Self.number(settings.window.defaultSize.height)) { [store] in store.setWindowSize("height", $0) })
        b.row("worktree-template", b.field("worktree-template", settings.worktrees.defaultLocation.pathTemplate, placeholder: WorktreeLocation.suggestedTemplate) { [store] in
            store.setWorktreeLocation("worktree-template", $0)
        })
        b.row("worktree-folder", b.field("worktree-folder", settings.worktrees.defaultLocation.parentPath, placeholder: TabDirs.defaultWorktreeFolder) { [store] in
            store.setWorktreeLocation("worktree-folder", $0)
        })
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(value)
    }

    static let choosingApplication = "choose.application"

    /// Where files clicked in a terminal open: Tab's editor, the default
    /// application, Finder, or a chosen app.
    private func fileOpenerPopUp(_ b: SettingsPageBuilder) -> SettingControl {
        let current = store.settings.openers.file
        var items = [
            Choice(id: OpenerSettings.tabEditor, title: "Tab editor"),
            Choice(id: "system.application", title: "Default application"),
            Choice(id: "system.finder", title: "Finder"),
        ]
        if !items.contains(where: { $0.id == current }) {
            items.append(Choice(id: current, title: Self.applicationName(current), separatorBefore: true))
        }
        items.append(Choice(id: Self.choosingApplication, title: "Other Application…", separatorBefore: true))
        return b.popUp("file-opener", items, selected: current) { [weak self] id in
            guard let self else { return }
            guard id == Self.choosingApplication else { return store.setFileOpener(id) }
            chooseApplication()
        }
    }

    static func applicationName(_ bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return bundleId }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url, let bundle = Bundle(url: url)?.bundleIdentifier else {
                return reload()
            }
            store.setFileOpener(bundle)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    func buildAppearance(_ b: SettingsPageBuilder) {
        let appearance = store.settings.appearance
        let entries = store.theme.catalog.entries
        for dark in [false, true] {
            let id = dark ? "dark-theme" : "light-theme"
            let current = dark ? appearance.darkTheme : appearance.lightTheme
            var items = entries.map { Choice(id: $0.name, title: $0.name) }
            if !items.contains(where: { $0.id == current }) {
                items.insert(Choice(id: current, title: current), at: 0)
            }
            b.row(id, b.popUp(id, items, selected: current) { [store] in store.setTheme(dark: dark, $0) })
        }
        for problem in store.theme.catalog.errors { b.note("dark-theme", problem, error: true) }
        b.row("sidebar", b.toggle("sidebar", appearance.sidebarExpanded) { [store] value in
            store.updateAppearance("sidebar") { $0.sidebarExpanded = value }
        })
        b.row("sidebar-width", b.slider(
            "sidebar-width",
            value: appearance.sidebarExpandedWidth ?? Metrics.sidebarExpandedWidth,
            range: Metrics.sidebarMinimumWidth...Metrics.sidebarMaximumWidth,
            step: 1
        ) { [store] value in
            store.updateAppearance("sidebar-width") { $0.sidebarExpandedWidth = value }
        })
        let toggles: [(String, Bool, WritableKeyPath<Appearance, Bool>)] = [
            ("auto-expand-worktrees", appearance.autoExpandWorktrees, \.autoExpandWorktrees),
            ("worktree-unread", appearance.worktreeShowUnread, \.worktreeShowUnread),
            ("worktree-recent-order", appearance.worktreeRecentOrder, \.worktreeRecentOrder),
            ("agents-panel", appearance.agentsPanelVisible, \.agentsPanelVisible),
        ]
        for (id, value, path) in toggles {
            b.row(id, b.toggle(id, value) { [store] on in store.updateAppearance(id) { $0[keyPath: path] = on } })
        }
        b.row("agents-panel-grouping", b.segmented("agents-panel-grouping", ["Agents", "Worktrees"], selected: appearance.agentsPanelGrouping == .worktrees ? 1 : 0) { [store] index in
            store.updateAppearance("agents-panel-grouping") { $0.agentsPanelGrouping = index == 1 ? .worktrees : .agents }
        })
    }
}
