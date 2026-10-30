import AppKit
import TabCore

/// One function per shortcut: what each `ShortcutId` does in the main
/// window, from its key, the menu bar or the palette.
@MainActor
final class Actions {
    unowned let model: AppModel
    weak var window: MainWindowController?

    init(model: AppModel) {
        self.model = model
    }

    private var terminal: TerminalPane? {
        model.activePane.flatMap { model.panes.controller(for: $0) } as? TerminalPane
    }

    /// Runs `id`; false when it does nothing here, so the key goes on.
    @discardableResult
    func perform(_ id: ShortcutId) -> Bool {
        if let pane = model.activePane,
           let browser = model.controller(for: pane) as? BrowserPaneContent,
           browser.controller.perform(id) { return true }
        switch id {
        case .newTab: model.newTerminal()
        case .newHomeTab: model.newHomeTerminal()
        case .newTabInProject: window?.openPalette(.newTerminal)
        case .existingTerminals: window?.openPalette(.terminals(model.currentProject.id))
        case .detachTerminal: model.detachTerminal()
        case .closeTab: model.closeTab()
        case .closePane: model.closePane()
        case .splitRight: model.split(.right)
        case .splitDown: model.split(.down)
        case .focusPaneLeft: model.focus(.left)
        case .focusPaneRight: model.focus(.right)
        case .focusPaneUp: model.focus(.up)
        case .focusPaneDown: model.focus(.down)
        case .toggleZoomPane: model.toggleZoom()
        case .equalizeSplits: model.equalizeSplits()
        case .nextTab: model.cycleCard(forward: true)
        case .previousTab: model.cycleCard(forward: false)
        case .nextProject: model.cycleProject(forward: true)
        case .previousProject: model.cycleProject(forward: false)
        case .addProject: window?.openPalette(.addProject(.local))
        case .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5, .selectTab6, .selectTab7, .selectTab8, .selectTab9:
            model.selectCard(ShortcutId.tabs.firstIndex(of: id) ?? 0)
        case .selectProject1, .selectProject2, .selectProject3, .selectProject4, .selectProject5, .selectProject6,
             .selectProject7, .selectProject8, .selectProject9:
            model.selectProject(at: ShortcutId.projects.firstIndex(of: id) ?? 0)
        case .copy: return terminalCommand(.copy)
        case .paste: return terminalCommand(.paste)
        case .find: return terminalCommand(.find)
        case .findNext: return terminalCommand(.findNext)
        case .findPrevious: return terminalCommand(.findPrevious)
        case .scrollToBottom: return terminalCommand(.scrollToBottom)
        case .previousPrompt: return terminalCommand(.previousPrompt)
        case .nextPrompt: return terminalCommand(.nextPrompt)
        case .selectCommandOutput: return terminalCommand(.selectCommandOutput)
        case .increaseFontSize: return terminalCommand(.increaseFontSize(1))
        case .decreaseFontSize: return terminalCommand(.decreaseFontSize(1))
        case .newWorktree:
            guard let parent = model.newWorktreeTarget else { return false }
            window?.newWorktree(parent: parent)
        case .switchWorktree:
            let current = model.currentProject
            window?.openPalette(.worktrees(current.parentId ?? current.id))
        case .toggleSidebar: model.toggleSidebar()
        case .toggleAgentsPanel: toggleAgentsPanel()
        case .toggleAgentSessions: model.toggleRightPanel(.agentSessions)
        case .toggleFiles: model.toggleRightPanel(.files)
        case .toggleSourceControl: model.toggleRightPanel(.sourceControl)
        case .goToFile: window?.openPalette(.files)
        case .findInFiles: window?.openPalette(.find)
        case .toggleFullScreen: window?.window?.toggleFullScreen(nil)
        case .toggleThemePicker: window?.openPalette(.themes)
        case .toggleCommandPalette: window?.openPalette(.root)
        case .navigateBack: model.navigate(forward: false)
        case .navigateForward: model.navigate(forward: true)
        case .quit: NSApp.terminate(nil)
        case .hideApp: NSApp.hide(nil)
        case .hideOthers: NSApp.hideOtherApplications(nil)
        case .showAll: NSApp.unhideAllApplications(nil)
        case .minimize: window?.window?.miniaturize(nil)
        case .zoom: window?.window?.zoom(nil)
        case .endAllSessionsAndQuit: window?.endAllSessionsAndQuit()
        case .openSettings: window?.showSettings()
        case .installCommandLineTool: CommandLineInstaller.installAndReport(on: window?.window)
        case .toggleVoiceRecording: window?.toggleDictation()
        case .newBrowserTab: model.openBrowser()
        case .openConfiguration: NSWorkspace.shared.open(model.dirs.settings)
        default: return false
        }
        return true
    }

    private func terminalCommand(_ command: TerminalCommand) -> Bool {
        guard let terminal else { return false }
        terminal.perform(command)
        return true
    }

    /// Shows the Agents panel where it is placed and gives it the keyboard;
    /// hides it when it is shown and already has the keyboard, as Codesh.
    func toggleAgentsPanel() {
        let appearance = model.appearance
        let placement = AgentsPanelPlacement(appearance, sidebarExpanded: appearance.sidebarExpanded)
        if placement == .right {
            model.toggleRightPanel(.agents)
            return
        }
        let panel = model.agentsPanel
        let shown = appearance.agentsPanelVisible && (placement != .popup || model.agentsPopupOpen)
        if shown && panel.hasFocus {
            model.hideAgentsPanel()
            return
        }
        if !appearance.agentsPanelVisible { model.updateAppearance { $0.agentsPanelVisible = true } }
        if placement == .popup { model.agentsPopupOpen = true }
        model.notify(.panel)
        DispatchQueue.main.async { panel.focus() }
    }

    func clearSidebarFilter() {
        window?.sidebar.clearFilter()
    }
}
