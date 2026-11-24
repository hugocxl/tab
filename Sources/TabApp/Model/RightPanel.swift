import AppKit
import TabCore

/// Width constraints shared by the right sidebar shell and its plugins.
public enum RightPanelMetrics {
    public static let defaultWidth: CGFloat = 300
    public static let minimumWidth: CGFloat = 220
    public static let maximumWidth: CGFloat = 640
}

/// Metadata for a right-sidebar tab provided by an active plugin.
public struct RightPanelDescriptor: Equatable, Identifiable, Sendable {
    public let id: String
    public let pluginId: PluginId
    public let title: String
    public let icon: AppIcon
    public let shortcut: ShortcutId?
    public let order: Int

    public init(
        id: String,
        pluginId: PluginId,
        title: String,
        icon: AppIcon,
        shortcut: ShortcutId? = nil,
        order: Int = 100
    ) {
        self.id = id
        self.pluginId = pluginId
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.order = order
    }
}

/// A right panel's content. The shell draws the sidebar's top row and
/// resize handle; the content fills the rest, its footer row included.
@MainActor
public protocol RightPanelContent: AnyObject {
    var panelId: String { get }
    var view: NSView { get }
    /// The current project changed while the panel shows.
    func projectDidChange(_ project: Project?)
    func didShow()
    func didHide()
    func focusContent()
}

/// Makes a panel's content, or `nil` when no plugin provides `panelId`.
public typealias RightPanelFactory = @MainActor (String, AppModel) -> RightPanelContent?

extension AppModel {
    /// All right-sidebar tabs contributed by active plugins, in order.
    public var rightSidebarPanels: [RightPanelDescriptor] {
        plugins.sidebarPanels
    }

    /// All left-sidebar footer buttons contributed by active plugins, in order.
    public var sidebarFooterItems: [PluginSidebarFooterItem] {
        plugins.sidebarFooterItems
    }

    /// The panel open on the right, if any active plugin provides it.
    public var rightPanel: String? {
        guard activeTab?.zoomed == nil else { return nil }
        guard let id = appearance.sidePanel.panelId else { return nil }
        guard plugins.sidebarPanel(id) != nil || rightPanelFactory != nil else { return nil }
        return id
    }

    /// Whether the right sidebar is visible (either showing a plugin panel or
    /// the empty state when no plugins are installed).
    public var rightSidebarVisible: Bool {
        guard activeTab?.zoomed == nil else { return false }
        if rightPanel != nil { return true }
        return rightSidebarShowingEmpty && rightSidebarPanels.isEmpty
    }

    /// Opens the right sidebar on `panelId`, or closes it when `panelId` shows.
    public func toggleRightPanel(_ panelId: String) {
        guard plugins.sidebarPanel(panelId) != nil || rightPanelFactory != nil else { return }
        if rightPanel == panelId {
            closeRightSidebar()
        } else {
            selectRightPanel(panelId)
        }
    }

    /// Shows `panelId` in the right sidebar, opening it when it is closed.
    public func selectRightPanel(_ panelId: String) {
        guard plugins.sidebarPanel(panelId) != nil || rightPanelFactory != nil else { return }
        guard rightPanel != panelId else { return }
        if activeTab?.zoomed != nil { toggleZoom() }
        rightSidebarShowingEmpty = false
        updateAppearance { appearance in
            appearance.sidePanel = .panel(panelId)
            appearance.lastSidePanel = .panel(panelId)
        }
        rightPanelAwaitingFocus = panelId
        notify(.panel)
    }

    /// Gives the keyboard to `panelId` if opening it asked for that; the shell
    /// calls this once the panel's content is in the window.
    public func focusRightPanelIfRequested(_ panelId: String) {
        guard rightPanelAwaitingFocus == panelId else { return }
        rightPanelAwaitingFocus = nil
        rightPanelContent(panelId)?.focusContent()
    }

    /// Hides the right sidebar, or shows it again on the tab it last showed
    /// (or the empty state when no plugins are installed).
    public func toggleRightSidebar() {
        if rightSidebarVisible {
            closeRightSidebar()
            return
        }
        let available = rightSidebarPanels
        if available.isEmpty && rightPanelFactory == nil {
            if activeTab?.zoomed != nil { toggleZoom() }
            rightSidebarShowingEmpty = true
            notify(.panel)
            return
        }
        if let last = appearance.lastSidePanel.panelId,
           available.contains(where: { $0.id == last }) || rightPanelFactory != nil {
            selectRightPanel(last)
        } else if let first = available.first {
            selectRightPanel(first.id)
        }
    }

    public func closeRightSidebar() {
        rightPanelAwaitingFocus = nil
        rightSidebarShowingEmpty = false
        updateAppearance { $0.sidePanel = .none }
        notify(.panel)
    }

    /// The content of `panelId`, made once while its plugin stays active.
    public func rightPanelContent(_ panelId: String) -> RightPanelContent? {
        if let existing = rightPanels[panelId] { return existing }
        let content = plugins.makePanelContent(panelId) ?? rightPanelFactory?(panelId, self)
        if let content {
            rightPanels[panelId] = content
        }
        return content
    }

    /// The right panel's width, remembered across launches.
    public func rightPanelWidth(_ panelId: String? = nil) -> CGFloat {
        let width = appearance.sidePanelWidth.map { CGFloat($0) } ?? RightPanelMetrics.defaultWidth
        return min(max(width, RightPanelMetrics.minimumWidth), RightPanelMetrics.maximumWidth)
    }

    public func setRightPanelWidth(_ panelId: String?, _ width: CGFloat) {
        let width = Double(min(max(width, RightPanelMetrics.minimumWidth), RightPanelMetrics.maximumWidth).rounded())
        updateAppearance { $0.sidePanelWidth = width }
        notify(.panel)
    }
}
