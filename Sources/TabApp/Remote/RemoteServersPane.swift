import AppKit
import Combine
import TabCore

/// The Remote Servers pane: every server by group with checkboxes, Shift-
/// click ranges and Select all, a bar acting on the ticked servers, and
/// group headings that connect, rename or delete their group.
@MainActor
public final class RemoteServersPaneController: PaneContentController {
    public let view: NSView
    public let title = "Remote Servers"
    public var titleDidChange: (() -> Void)?
    private let content: RemoteServersPaneView

    init(controller: RemoteServersController) {
        content = RemoteServersPaneView(controller: controller)
        view = content
    }

    public func focusContent() { content.focusSearch() }
    public func willClose() async -> Bool { true }
    public func didShow() { content.reload(force: true) }
    public func didHide() {}

    public var headerActions: [PaneAction] {
        [PaneAction(id: "remote-add-server", icon: .plus, label: "Add Server…") { [weak content] in
            content?.controller.editServer(nil)
        }]
    }
}

final class RemoteServersPaneView: ThemedView {
    static let contentWidth: CGFloat = 960
    let controller: RemoteServersController
    private var model: RemoteServersModel { controller.model }
    private let scroll = ScrollView()
    private let column = NSStackView()
    private let search = SearchField(placeholder: "Search servers…")
    private var subscription: AnyCancellable?
    private var renderedKey: [String] = []

    init(controller: RemoteServersController) {
        self.controller = controller
        super.init(frame: .zero)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 16
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.content.addSubview(column)
        let width = column.widthAnchor.constraint(equalTo: scroll.content.widthAnchor, constant: -48)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            width,
            column.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.content.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: scroll.content.trailingAnchor, constant: -24),
            column.centerXAnchor.constraint(equalTo: scroll.content.centerXAnchor),
            column.topAnchor.constraint(equalTo: scroll.content.topAnchor, constant: 24),
            column.bottomAnchor.constraint(equalTo: scroll.content.bottomAnchor, constant: -24),
        ])
        addSubview(scroll)
        scroll.pinEdges(to: self)
        let header = DialogParts.row([
            makeLabel("Remote Servers", font: AppFont.title),
            DialogParts.spacer(),
            search,
            PillButton("Add Server…") { [weak self] in self?.controller.editServer(nil) },
        ], spacing: 12)
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true
        add(header)
        search.onChange = { [weak self] _ in
            guard let self else { return }
            self.model.selection.retain(self.shownIDs)
            self.reload(force: true)
        }
        subscription = model.changes.receive(on: RunLoop.main).sink { [weak self] in self?.reload(force: false) }
        reload(force: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func focusSearch() { window?.makeFirstResponder(search.field) }

    private var shown: [(group: String?, members: [RemoteServerStatus])] {
        shownServers(model.servers, query: search.stringValue)
    }

    private var shownIDs: [ServerId] { shown.flatMap { $0.members.map(\.id) } }

    /// Rebuilds when what the pane shows changed.
    func reload(force: Bool) {
        let servers = model.servers
        var key = servers.map { "\($0.id)|\($0.entry.name)|\($0.entry.group ?? "")|\($0.label)|\($0.detail ?? "")" }
        key.append(model.selection.ids.map(\.description).joined(separator: ","))
        key.append(search.stringValue)
        guard force || key != renderedKey else { return }
        renderedKey = key
        rebuild(servers)
    }

    private func rebuild(_ servers: [RemoteServerStatus]) {
        column.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
        guard !servers.isEmpty else {
            add(emptyState("No remote servers yet", "Add a computer you reach over SSH to work with its projects here."))
            return
        }
        let shown = shown
        add(SelectionBar(controller: controller, shown: shownIDs))
        guard !shown.isEmpty else {
            add(emptyState("No matching servers", "Try a different name or clear your search."))
            return
        }
        let ids = shownIDs
        for (group, members) in shown {
            let whole = model.members(ofGroup: group).compactMap(model.status(of:))
            add(GroupHeading(controller: controller, group: group, members: whole))
            let card = Card()
            for server in members {
                card.addRow(PaneServerRow(controller: controller, server: server, shown: ids))
            }
            add(card)
        }
    }

    private func add(_ view: NSView) {
        column.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    private func emptyState(_ title: String, _ detail: String) -> NSView {
        let stack = DialogParts.column([makeLabel(title, font: AppFont.header), DialogParts.note(detail)], spacing: 4)
        let box = NSView()
        box.addSubview(stack)
        stack.pinEdges(to: box, insets: NSEdgeInsets(top: 32, left: 0, bottom: 0, right: 0))
        return box
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.bg.setFill()
        dirtyRect.fill()
    }
}

/// Select all, the count ticked, and what to do with them.
private final class SelectionBar: ThemedView {
    private let any: Bool

    init(controller: RemoteServersController, shown: [ServerId]) {
        let model = controller.model
        let selected = model.listedIDs.filter(model.selection.contains).compactMap(model.status(of:))
        any = !selected.isEmpty
        super.init(frame: .zero)
        let all = any && shown.allSatisfy(model.selection.contains)
        let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        box.allowsMixedState = true
        box.state = all ? .on : (any ? .mixed : .off)
        box.setAccessibilityLabel("Select all")
        let label = makeLabel(any ? "\(selected.count) selected" : "Select all",
                              font: any ? AppFont.bodyMedium : AppFont.body)
        var views: [NSView] = [box, label, DialogParts.spacer()]
        let tickAll: () -> Void = { [weak model] in model?.selection.tickAll(shown: shown) }
        box.target = BlockTarget.attach(to: box, tickAll)
        box.action = #selector(BlockTarget.run)
        if any {
            let ids = selected.map(\.id)
            let connect = PillButton("Connect") { model.connect(ids) }
            connect.isEnabled = selected.contains { $0.state == .offline }
            let disconnect = PillButton("Disconnect") { model.disconnect(ids) }
            disconnect.isEnabled = selected.contains { $0.state.isLive || $0.waitingToRetry }
            let move = PillButton("Move to Group…")
            move.onPress = { [weak move] in
                guard let move else { return }
                controller.moveMenu(ids).popUp(positioning: nil, at: NSPoint(x: 0, y: move.bounds.maxY + 4), in: move)
            }
            let forget = PillButton("Forget…", style: .destructive) { controller.confirmForget(ids) }
            views += [connect, disconnect, move, forget]
        } else {
            label.textColor = AppTheme.shared.fgMuted
        }
        let row = DialogParts.row(views)
        addSubview(row)
        row.pinEdges(to: self, insets: NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10))
        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.radiusLarge, yRadius: Metrics.radiusLarge)
        (any ? theme.accentSoft : theme.surface).setFill()
        path.fill()
        (any ? theme.accentSoft : theme.border).setStroke()
        path.stroke()
    }
}

/// A group's title, its count, Connect, and its menu.
private final class GroupHeading: ThemedView {
    private let controller: RemoteServersController
    private let group: String?

    init(controller: RemoteServersController, group: String?, members: [RemoteServerStatus]) {
        self.controller = controller
        self.group = group
        super.init(frame: .zero)
        let title = makeLabel(group ?? "Ungrouped", font: AppFont.header)
        let count = makeLabel("\(members.count)", font: AppFont.footnote, color: AppTheme.shared.fgMuted)
        let choice = ConnectChoice(members)
        let ids = members.map(\.id)
        let connect = PillButton(choice == .reconnect(count: members.count) ? "Reconnect" : "Connect", style: .plain) {
            switch choice {
            case .connect: controller.model.connect(ids)
            case .reconnect: controller.model.reconnect(ids)
            }
        }
        let more = IconButton(.ellipsis, label: "Group Actions")
        more.toolTip = "Group Actions"
        more.onPress = { [weak more] in
            guard let more else { return }
            controller.groupMenu(group)?.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
        }
        let row = DialogParts.row([title, count, DialogParts.spacer(), connect, more])
        addSubview(row)
        row.pinEdges(to: self, insets: NSEdgeInsets(top: 4, left: 4, bottom: 0, right: 0))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func rightMouseDown(with event: NSEvent) {
        controller.showGroupMenu(group, in: self, at: convert(event.locationInWindow, from: nil))
    }
}

/// One server: its box and state, name, destination and why it failed, and
/// New Terminal, Edit and More shown while hovered.
private final class PaneServerRow: HoverView {
    private let controller: RemoteServersController
    private let id: ServerId
    private let actions: NSStackView
    private var errorLabel: NSTextField?

    init(controller: RemoteServersController, server: RemoteServerStatus, shown: [ServerId]) {
        self.controller = controller
        id = server.id
        let model = controller.model
        let id = server.id
        let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        box.state = model.selection.contains(id) ? .on : .off
        box.setAccessibilityLabel("Select \(server.entry.name)")
        box.target = BlockTarget.attach(to: box) { [weak model] in
            model?.selection.tick(id, range: NSEvent.modifierFlags.contains(.shift), shown: shown)
        }
        box.action = #selector(BlockTarget.run)
        let dot = StatusDot()
        dot.glyph = server.glyph
        let name = makeLabel(server.entry.name, font: AppFont.bodyMedium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let badge = Badge(server.label.uppercased())
        let destination = makeLabel(server.entry.destination, font: AppFont.footnote, color: AppTheme.shared.fgMuted)
        destination.lineBreakMode = .byTruncatingMiddle
        destination.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var lines: [NSView] = [DialogParts.row([name, badge]), destination]
        var errorLabel: NSTextField?
        if let detail = server.detail {
            let error = DialogParts.note(detail, color: AppTheme.shared.danger)
            error.maximumNumberOfLines = 3
            lines.append(error)
            errorLabel = error
        }
        let text = DialogParts.column(lines, spacing: 2)
        text.alignment = .leading
        let terminal = IconButton(.terminal, label: "New Terminal") { controller.host?.openRemoteHome(on: id) }
        terminal.toolTip = "New Terminal"
        let edit = IconButton(.pencil, label: "Edit…") { controller.editServer(id) }
        edit.toolTip = "Edit…"
        let more = IconButton(.ellipsis, label: "More Actions")
        more.toolTip = "More Actions"
        more.onPress = { [weak more] in
            guard let more else { return }
            controller.showServerMenu(id, in: more, at: NSPoint(x: 0, y: more.bounds.maxY + 4))
        }
        actions = DialogParts.row([terminal, edit, more], spacing: 2)
        actions.isHidden = true
        self.errorLabel = errorLabel
        super.init(frame: .zero)
        for view in [box, text, actions] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addSubview(dot)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            box.widthAnchor.constraint(equalToConstant: 16),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            dot.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            text.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actions.widthAnchor.constraint(equalToConstant: 76),
            actions.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
        actions.setHuggingPriority(.required, for: .horizontal)
        text.setHuggingPriority(.init(1), for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Wraps the error line at the width the row gives it.
    override func layout() {
        super.layout()
        guard let errorLabel, errorLabel.preferredMaxLayoutWidth != errorLabel.frame.width else { return }
        errorLabel.preferredMaxLayoutWidth = errorLabel.frame.width
        needsLayout = true
    }

    override func hoverDidChange() {
        actions.isHidden = !isHovered
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        theme.hover.setFill()
        bounds.fill()
    }

    override func rightMouseDown(with event: NSEvent) {
        controller.showServerMenu(id, in: self, at: convert(event.locationInWindow, from: nil), selection: true)
    }
}

/// Runs a closure as a control's action; kept alive by the control.
final class BlockTarget: NSObject {
    private let block: () -> Void
    private static var key = 0

    private init(_ block: @escaping () -> Void) { self.block = block }

    @objc func run() { block() }

    /// Makes a target for `control` and ties its life to the control's.
    static func attach(to control: NSControl, _ block: @escaping () -> Void) -> BlockTarget {
        let target = BlockTarget(block)
        objc_setAssociatedObject(control, &key, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return target
    }
}
