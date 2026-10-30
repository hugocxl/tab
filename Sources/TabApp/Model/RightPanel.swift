import AppKit
import TabCore

/// The tabs of the right sidebar, pinned beside the current project and
/// shown one at a time.
public enum RightPanelKind: String, CaseIterable, Sendable {
    case files
    case sourceControl

    public var icon: AppIcon {
        switch self {
        case .files: return .folder
        case .sourceControl: return .gitBranch
        }
    }

    var sidePanel: SidePanel {
        switch self {
        case .files: return .files
        case .sourceControl: return .sourceControl
        }
    }

    public var title: String {
        switch self {
        case .files: return "Files"
        case .sourceControl: return "Source Control"
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
        switch appearance.sidePanel {
        case .files: return .files
        case .sourceControl: return .sourceControl
        case .none: return nil
        }
    }

    /// Opens the right sidebar on `kind`, or closes it when `kind` shows.
    public func toggleRightPanel(_ kind: RightPanelKind) {
        if rightPanel == kind {
            closeRightSidebar()
        } else {
            selectRightPanel(kind)
        }
    }

    /// Shows `kind` in the right sidebar, opening it when it is closed.
    public func selectRightPanel(_ kind: RightPanelKind) {
        guard rightPanel != kind else { return }
        updateAppearance { appearance in
            appearance.sidePanel = kind.sidePanel
            appearance.lastSidePanel = kind.sidePanel
        }
        notify(.panel)
        rightPanelContent(kind)?.focusContent()
    }

    /// Hides the right sidebar, or shows it again on the tab it last showed.
    public func toggleRightSidebar() {
        if rightPanel != nil {
            closeRightSidebar()
        } else {
            selectRightPanel(appearance.lastSidePanel == .sourceControl ? .sourceControl : .files)
        }
    }

    private func closeRightSidebar() {
        updateAppearance { $0.sidePanel = .none }
        notify(.panel)
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
        let width = appearance.sidePanelWidth.map { CGFloat($0) } ?? RightPanelKind.defaultWidth
        return min(max(width, RightPanelKind.minimumWidth), RightPanelKind.maximumWidth)
    }

    public func setRightPanelWidth(_ kind: RightPanelKind, _ width: CGFloat) {
        let width = Double(min(max(width, RightPanelKind.minimumWidth), RightPanelKind.maximumWidth).rounded())
        updateAppearance { $0.sidePanelWidth = width }
        notify(.panel)
    }
}
