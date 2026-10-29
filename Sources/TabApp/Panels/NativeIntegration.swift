import AppKit
import TabCore
import TabProtocol

/// Sends native panel requests through the shell's `ServerAPI` side client.
public final class ServerAPITransport: NativeTransport {
    public let api: ServerAPI

    public init(_ api: ServerAPI) {
        self.api = api
    }

    public func git(_ request: GitRequest) async throws -> GitReply { try await api.git(request) }
    public func files(_ request: FilesRequest) async throws -> FilesReply { try await api.files(request) }
}

/// A right panel that shows one controller per project, such as Files or
/// Source Control, switching with the current project. Controllers and
/// their hosts are made once per project and kept.
@MainActor
public final class ProjectPanelContent<Controller: NSViewController>: RightPanelContent {
    /// Makes a project's controller and the host it reports to, which the
    /// panel keeps alive; `nil` shows nothing for that project.
    public typealias Factory = @MainActor (Project) -> (controller: Controller, host: AnyObject)?

    public let kind: RightPanelKind
    public let view: NSView = FlippedView()
    private let make: Factory
    private var entries: [ProjectId: (controller: Controller, host: AnyObject)] = [:]
    public private(set) var current: Controller?
    private let onShow: @MainActor (Controller) -> Void
    private let onFocus: @MainActor (Controller) -> Void

    public init(kind: RightPanelKind, make: @escaping Factory,
                onShow: @escaping @MainActor (Controller) -> Void = { _ in },
                onFocus: @escaping @MainActor (Controller) -> Void = { $0.view.window?.makeFirstResponder($0.view) }) {
        self.kind = kind
        self.make = make
        self.onShow = onShow
        self.onFocus = onFocus
    }

    /// The controller made for `project`, to route its events.
    public func controller(for project: ProjectId) -> Controller? { entries[project]?.controller }

    /// Every controller made so far.
    public var controllers: [Controller] { entries.values.map(\.controller) }

    public func projectDidChange(_ project: Project?) {
        current?.view.removeFromSuperview()
        current = nil
        guard let project else { return }
        let entry = entries[project.id] ?? make(project)
        guard let entry else { return }
        entries[project.id] = entry
        current = entry.controller
        view.addSubview(entry.controller.view)
        entry.controller.view.pinEdges(to: view)
        onShow(entry.controller)
    }

    /// Forgets projects that no longer exist.
    public func retain(_ projects: Set<ProjectId>) {
        for id in entries.keys where !projects.contains(id) {
            if entries[id]?.controller === current {
                current?.view.removeFromSuperview()
                current = nil
            }
            entries[id] = nil
        }
    }

    public func didShow() {
        if let current { onShow(current) }
    }

    public func didHide() {}

    public func focusContent() {
        if let current { onFocus(current) }
    }
}

extension ProjectPanelContent where Controller == FilesPanelController {
    /// The Files panel: `host` makes the host for a project's panel.
    public static func files(host: @escaping @MainActor (Project) -> FilesPanelHost?) -> ProjectPanelContent {
        ProjectPanelContent(kind: .files, make: { project in
            guard let host = host(project) else { return nil }
            let controller = FilesPanelController(host: host)
            controller.drawsCard = false
            return (controller, host)
        }, onShow: { $0.ensureRoot() }, onFocus: { $0.focus() })
    }
}

extension ProjectPanelContent where Controller == SourceControlController {
    /// The Source Control panel: `host` makes the host for a project's panel.
    public static func sourceControl(host: @escaping @MainActor (Project) -> SourceControlHost?) -> ProjectPanelContent {
        ProjectPanelContent(kind: .sourceControl, make: { project in
            guard let host = host(project) else { return nil }
            let controller = SourceControlController(host: host)
            controller.drawsCard = false
            return (controller, host)
        }, onShow: { $0.didShow() }, onFocus: { $0.focusMessage() })
    }
}

/// An editor pane in a pane card.
@MainActor
public final class EditorPaneContent: PaneContentController, EditorLocationReceiver {
    public let controller: EditorPaneController
    private let host: EditorHost
    public var titleDidChange: (() -> Void)?

    public init(host: EditorHost, path: String) {
        self.host = host
        controller = EditorPaneController(host: host, path: path)
        controller.onTitleChange = { [weak self] in self?.titleDidChange?() }
    }

    public var view: NSView { controller.view }
    public var title: String { controller.paneTitle }
    public var icon: NSImage? { nil }
    public func focusContent() { controller.focus() }
    public func didShow() { controller.didShow() }

    /// Puts the caret at `line` and `column`, once the file is read.
    public func reveal(line: Int?, column: Int?) {
        guard let line else { return }
        controller.go(line: line, column: column ?? 1)
    }
    public func didHide() {}

    public func willClose() async -> Bool {
        await withCheckedContinuation { continuation in
            controller.willClose { continuation.resume(returning: $0) }
        }
    }
}

/// A diff pane in a pane card.
@MainActor
public final class DiffPaneContent: PaneContentController {
    public let controller: DiffPaneController
    private let host: DiffHost
    public var titleDidChange: (() -> Void)?

    public init(host: DiffHost, path: String, staged: Bool) {
        self.host = host
        controller = DiffPaneController(host: host, path: path, staged: staged)
    }

    public var view: NSView { controller.view }
    public var title: String { PaneContent.diff(path: controller.path, staged: controller.staged).nativeTitle ?? controller.path }
    public var icon: NSImage? { nil }
    public func focusContent() { controller.view.window?.makeFirstResponder(controller.rowsView) }
    public func didShow() { controller.didShow() }
    public func didHide() {}
    public func willClose() async -> Bool { true }
}
