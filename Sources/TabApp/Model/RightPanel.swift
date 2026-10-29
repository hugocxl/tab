import AppKit
import TabCore

/// The native panels pinned on the right of the current project, one at a
/// time, like Files in the reference window.
public enum RightPanelKind: String, CaseIterable, Sendable {
    case files
    case sourceControl
    case agents
    case agentSessions

    public var title: String {
        switch self {
        case .files: return "Files"
        case .sourceControl: return "Source Control"
        case .agents: return "Agents"
        case .agentSessions: return "Agent Sessions"
        }
    }

    public static let defaultWidth: CGFloat = 300
    public static let minimumWidth: CGFloat = 220
    public static let maximumWidth: CGFloat = 640
}

/// A right panel's content. The shell draws the panel's frame, header-less
/// card and resize handle; the content fills it.
@MainActor
public protocol RightPanelContent: AnyObject {
    var kind: RightPanelKind { get }
    var view: NSView { get }
    /// The current project changed while the panel shows; `nil` for Home.
    func projectDidChange(_ project: Project?)
    func didShow()
    func didHide()
    func focusContent()
}

/// Makes a panel's content, or `nil` when the module providing it is not
/// there yet.
public typealias RightPanelFactory = @MainActor (RightPanelKind, AppModel) -> RightPanelContent?

/// Stands in for a panel whose module is not present.
@MainActor
final class PlaceholderPanel: RightPanelContent {
    let kind: RightPanelKind
    let view: NSView

    init(kind: RightPanelKind) {
        self.kind = kind
        view = PlaceholderView(title: kind.title, detail: "")
    }

    func projectDidChange(_ project: Project?) {
        (view as? PlaceholderView)?.update(title: kind.title, detail: project?.name ?? "")
    }

    func didShow() {}
    func didHide() {}
    func focusContent() {}
}

extension AppModel {
    /// The panel open on the right, if any.
    public var rightPanel: RightPanelKind? {
        if appearance.agentSessionsVisible { return .agentSessions }
        if appearance.agentsPanelVisible, appearance.agentsPanelDock == .right { return .agents }
        switch appearance.sidePanel {
        case .files: return .files
        case .sourceControl: return .sourceControl
        case .none: return nil
        }
    }

    /// Opens `kind` on the right, or closes it when it is open.
    public func toggleRightPanel(_ kind: RightPanelKind) {
        let open = rightPanel == kind
        updateAppearance { appearance in
            appearance.agentSessionsVisible = false
            if appearance.agentsPanelDock == .right { appearance.agentsPanelVisible = false }
            appearance.sidePanel = .none
            guard !open else { return }
            switch kind {
            case .files: appearance.sidePanel = .files
            case .sourceControl: appearance.sidePanel = .sourceControl
            case .agents:
                appearance.agentsPanelVisible = true
                appearance.agentsPanelDock = .right
            case .agentSessions: appearance.agentSessionsVisible = true
            }
        }
        notify(.panel)
        if !open { rightPanelContent(kind)?.focusContent() }
    }

    /// The content of `kind`, made once.
    public func rightPanelContent(_ kind: RightPanelKind) -> RightPanelContent? {
        if let existing = rightPanels[kind] { return existing }
        let content = rightPanelFactory?(kind, self) ?? PlaceholderPanel(kind: kind)
        rightPanels[kind] = content
        return content
    }

    /// The right panel's width, remembered per panel.
    public func rightPanelWidth(_ kind: RightPanelKind) -> CGFloat {
        let saved: Double?
        switch kind {
        case .files, .sourceControl: saved = appearance.sidePanelWidth
        case .agents: saved = appearance.agentsPanelRightWidth
        case .agentSessions: saved = appearance.agentSessionsWidth
        }
        let width = saved.map { CGFloat($0) } ?? RightPanelKind.defaultWidth
        return min(max(width, RightPanelKind.minimumWidth), RightPanelKind.maximumWidth)
    }

    public func setRightPanelWidth(_ kind: RightPanelKind, _ width: CGFloat) {
        let width = Double(min(max(width, RightPanelKind.minimumWidth), RightPanelKind.maximumWidth).rounded())
        updateAppearance { appearance in
            switch kind {
            case .files, .sourceControl: appearance.sidePanelWidth = width
            case .agents: appearance.agentsPanelRightWidth = width
            case .agentSessions: appearance.agentSessionsWidth = width
            }
        }
        notify(.panel)
    }
}
