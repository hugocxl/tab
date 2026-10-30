import AppKit
import TabCore

/// A button in a pane card's header, before the split, zoom and close
/// buttons every card has.
public struct PaneAction {
    public var id: String
    public var icon: AppIcon
    public var label: String
    /// Draws the icon in the accent color, for a toggle that is on.
    public var isActive: Bool
    public var perform: @MainActor () -> Void

    public init(id: String, icon: AppIcon, label: String, isActive: Bool = false, perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.icon = icon
        self.label = label
        self.isActive = isActive
        self.perform = perform
    }
}

/// What a pane card shows below its header: a terminal, an editor, a diff,
/// a browser or the Remote Servers pane. The shell owns the card, its header
/// and focus; the controller owns its content view.
@MainActor
public protocol PaneContentController: AnyObject {
    /// The content, laid out to fill the card's body.
    var view: NSView { get }
    /// The header title.
    var title: String { get }
    /// The header glyph; `nil` draws the pane kind's glyph.
    var icon: NSImage? { get }
    /// Set by the shell; call it whenever `title`, `icon`, `headerActions`
    /// or `progress` change.
    var titleDidChange: (() -> Void)? { get set }
    /// Gives the content the keyboard.
    func focusContent()
    /// Asks before closing, such as for unsaved changes or a running program.
    /// `false` keeps the pane.
    func willClose() async -> Bool
    /// Commits an approved close, such as ending a server-owned conversation.
    /// Called only after every pane in a group has agreed to close.
    func commitClose() async -> Bool
    /// The pane is on screen again, or for the first time.
    func didShow()
    /// The pane left the screen: another project, a zoomed sibling, or closed.
    func didHide()
    /// Buttons for the header, shown on the active or hovered card.
    var headerActions: [PaneAction] { get }
    /// The menu for a right click on the header.
    var contextMenu: NSMenu? { get }

    // MARK: Optional, with defaults

    /// Whether the content has the keyboard now.
    var hasFocus: Bool { get }
    /// Lets the content handle a key before the app's shortcuts, such as a
    /// terminal's own key bindings. Returns whether it did.
    func handleKeyFirst(_ event: NSEvent) -> Bool
    /// Work the content reports, drawn as a ring in the header.
    var progress: TerminalProgress? { get }
    /// The pane was removed for good; release resources.
    func dispose()
}

extension PaneContentController {
    public func commitClose() async -> Bool { true }

    public var hasFocus: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    public func handleKeyFirst(_ event: NSEvent) -> Bool { false }
    public var progress: TerminalProgress? { nil }
    public func dispose() {}
    public var headerActions: [PaneAction] { [] }
    public var contextMenu: NSMenu? { nil }
    public var icon: NSImage? { nil }
}

/// The kinds of pane content, as `PaneContent` cases without their data.
public enum PaneKind: Hashable, Sendable, CaseIterable {
    case terminal, agent, editor, diff, browser, servers

    public init(_ content: PaneContent) {
        switch content {
        case .terminal: self = .terminal
        case .agent: self = .agent
        case .editor: self = .editor
        case .diff: self = .diff
        case .browser: self = .browser
        case .servers: self = .servers
        }
    }

    /// The glyph a card header draws for the kind.
    public var glyph: AppIcon {
        switch self {
        case .terminal: return .terminal
        case .agent: return .code
        case .editor: return .file
        case .diff: return .gitBranch
        case .browser: return .globe
        case .servers: return .network
        }
    }

    public var name: String {
        switch self {
        case .terminal: return "Terminal"
        case .agent: return "Agent"
        case .editor: return "Editor"
        case .diff: return "Diff"
        case .browser: return "Browser"
        case .servers: return "Remote Servers"
        }
    }
}

/// What a factory gets to build a pane's controller.
@MainActor
public struct PaneContext {
    public let pane: Pane
    public let project: Project
    public unowned let model: AppModel

    /// The pane's project folder on its server.
    public var directory: ServerPath { project.directory }
    /// The connection for Git, files and search on the pane's server.
    public var sideClient: ServerAPI? { model.sideClient(for: project.id) }
}

/// Maps each pane to the controller that shows it, creating controllers on
/// first use from the factory registered for the pane's kind. Other modules
/// plug their pane kinds in with `register`.
@MainActor
public final class PaneRegistry {
    public typealias Factory = @MainActor (PaneContext) -> PaneContentController

    private var factories: [PaneKind: Factory] = [:]
    private var controllers: [PaneId: PaneContentController] = [:]
    private var kinds: [PaneId: PaneContent] = [:]

    public init() {}

    /// Builds panes of `kind` with `factory` from now on. Panes already
    /// shown keep their controller.
    public func register(_ kind: PaneKind, factory: @escaping Factory) {
        factories[kind] = factory
    }

    /// Whether a factory builds panes of `kind`.
    public func hasFactory(_ kind: PaneKind) -> Bool { factories[kind] != nil }

    /// The controller showing `pane`, if one was made.
    public func controller(for pane: PaneId) -> PaneContentController? { controllers[pane] }

    /// Every controller made so far.
    public var all: [(PaneId, PaneContentController)] { controllers.map { ($0.key, $0.value) } }

    /// The controller for `context.pane`, made now if needed. A pane whose
    /// content changed kind or target gets a new controller.
    public func controller(for context: PaneContext) -> PaneContentController {
        let id = context.pane.id
        if let existing = controllers[id], Self.sameTarget(kinds[id], context.pane.content) {
            return existing
        }
        controllers[id]?.dispose()
        let kind = PaneKind(context.pane.content)
        let controller = factories[kind]?(context) ?? PlaceholderPaneController(context: context)
        controllers[id] = controller
        kinds[id] = context.pane.content
        return controller
    }

    /// Forgets `pane`, disposing of its controller.
    public func remove(_ pane: PaneId) {
        controllers.removeValue(forKey: pane)?.dispose()
        kinds[pane] = nil
    }

    /// Keeps only `panes`, disposing of the rest.
    public func retain(_ panes: Set<PaneId>) {
        for id in controllers.keys where !panes.contains(id) { remove(id) }
    }

    /// A terminal keeps its controller when its session is assigned; other
    /// kinds are rebuilt when their target changes.
    private static func sameTarget(_ old: PaneContent?, _ new: PaneContent) -> Bool {
        guard let old else { return false }
        if old.isTerminal && new.isTerminal { return true }
        if case .browser = old, case .browser = new { return true }
        return old == new
    }
}

/// Stands in for a pane kind no module provides yet: its kind and target.
@MainActor
final class PlaceholderPaneController: PaneContentController {
    let view: NSView
    let title: String
    var titleDidChange: (() -> Void)?

    init(context: PaneContext) {
        let kind = PaneKind(context.pane.content)
        let detail: String
        switch context.pane.content {
        case .editor(let path), .diff(let path, _): detail = path
        case .browser(let browser): detail = browser.url ?? "New page"
        case .terminal, .agent, .servers: detail = context.project.directory.rawValue
        }
        title = context.pane.title.isEmpty ? kind.name : context.pane.title
        view = PlaceholderView(title: kind.name, detail: detail)
    }

    func focusContent() { view.window?.makeFirstResponder(view) }
    func willClose() async -> Bool { true }
    func didShow() {}
    func didHide() {}
}

/// A centered title and detail line, for empty and stand-in panes.
final class PlaceholderView: ThemedView {
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField

    init(title: String, detail: String) {
        titleLabel = makeLabel(title, font: AppFont.system(15, weight: .semibold))
        detailLabel = makeLabel(detail, font: AppFont.body)
        titleLabel.alignment = .center
        detailLabel.alignment = .center
        super.init(frame: .zero)
        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    func update(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
    }

    override func themeDidChange() {
        titleLabel.textColor = theme.fgMuted
        detailLabel.textColor = theme.fgDim
    }
}
