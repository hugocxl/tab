import AppKit
import Combine
import TabCore

/// A small round state dot.
final class StatusDot: ThemedView {
    var glyph: RemoteStatusGlyph = .offline {
        didSet {
            needsDisplay = true
            setAccessibilityValue(glyph.accessibilityName)
        }
    }

    init(diameter: CGFloat = 6) {
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        glyph.color(theme).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// One server in the host menu: its state dot and name, its state on the
/// right, replaced by an Edit pencil while hovered, and why it failed below.
final class HostMenuServerRow: HoverView {
    let id: ServerId
    var onEdit: (() -> Void)?
    var onMenu: ((NSView, NSPoint) -> Void)?
    private let dot = StatusDot()
    private let name = makeLabel("", font: AppFont.body)
    private let state = makeLabel("", font: AppFont.footnote)
    private let detail = makeLabel("", font: AppFont.footnote)
    private let edit: IconButton

    init(_ status: RemoteServerStatus) {
        id = status.id
        edit = IconButton(.pencil, label: "Edit…", side: 20)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        edit.toolTip = "Edit…"
        edit.action = { [weak self] in self?.onEdit?() }
        edit.isHidden = true
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 4
        detail.isSelectable = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let trailing = NSView()
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.addSubview(state)
        trailing.addSubview(edit)
        NSLayoutConstraint.activate([
            trailing.widthAnchor.constraint(greaterThanOrEqualTo: state.widthAnchor),
            trailing.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            trailing.heightAnchor.constraint(equalToConstant: 20),
            state.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
            state.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
            edit.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
            edit.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
        ])
        let line = DialogParts.row([dot, name, DialogParts.spacer(), trailing])
        let column = NSStackView(views: [line, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        addSubview(column)
        column.pinEdges(to: self, insets: NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 8))
        line.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        detail.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 14).isActive = true
        detail.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update(status)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ status: RemoteServerStatus) {
        dot.glyph = status.glyph
        name.stringValue = status.entry.name
        state.stringValue = status.label
        detail.stringValue = status.detail ?? ""
        detail.isHidden = status.detail == nil
        setAccessibilityLabel("\(status.entry.name), \(status.label)")
    }

    override func themeDidChange() {
        name.textColor = theme.fg
        state.textColor = theme.fgMuted
        detail.textColor = theme.danger
        needsDisplay = true
    }

    override func hoverDidChange() {
        edit.isHidden = !isHovered
        state.isHidden = isHovered
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        theme.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onMenu?(self, point)
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(self, convert(event.locationInWindow, from: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        onMenu?(self, NSPoint(x: 10, y: bounds.maxY))
        return true
    }
}

/// A group's heading in the host menu; right-click it for the group's menu.
final class HostMenuGroupHeading: ThemedView {
    var onMenu: ((NSView, NSPoint) -> Void)?
    private let label: NSTextField

    init(_ title: String) {
        label = makeLabel(title.uppercased(), font: AppFont.footnoteMedium)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.pinEdges(to: self, insets: NSEdgeInsets(top: 10, left: 10, bottom: 3, right: 10))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func themeDidChange() { label.textColor = theme.fgMuted }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(self, convert(event.locationInWindow, from: nil))
    }
}

/// The host menu popover over the sidebar footer: every remote server by
/// group with its state, then Add Server… and Manage Remote Servers….
final class HostMenuView: ThemedView {
    static let width: CGFloat = 300
    private let controller: RemoteServersController
    private let stack = NSStackView()
    private let scroll = ScrollView()
    private var rows: [ServerId: HostMenuServerRow] = [:]
    private var layoutKey: [String] = []
    private var subscription: AnyCancellable?
    private var heightConstraint: NSLayoutConstraint?
    /// The popover grows to its content, up to this height.
    var maximumHeight: CGFloat = 520
    var onSizeChange: ((NSSize) -> Void)?
    var dismiss: (() -> Void)?

    init(controller: RemoteServersController) {
        self.controller = controller
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.content.addSubview(stack)
        stack.pinEdges(to: scroll.content, insets: NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6))
        addSubview(scroll)
        scroll.pinEdges(to: self)
        heightConstraint = heightAnchor.constraint(equalToConstant: 120)
        heightConstraint?.isActive = true
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        subscription = controller.model.changes
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func themeDidChange() {
        needsDisplay = true
    }

    /// Rebuilds rows only when the list or its grouping changed; otherwise
    /// updates the rows in place.
    func reload() {
        let servers = controller.model.servers
        let groups = serversByGroup(servers, entry: \.entry)
        let key = groups.flatMap { [$0.group ?? "\u{0}"] + $0.members.map(\.id.description) }
        guard key == layoutKey else {
            layoutKey = key
            rebuild(groups, empty: servers.isEmpty)
            return
        }
        for server in servers { rows[server.id]?.update(server) }
        fitHeight()
    }

    private func rebuild(_ groups: [(group: String?, members: [RemoteServerStatus])], empty: Bool) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        add(HostMenuGroupHeading("Remote Servers"))
        if empty {
            let note = DialogParts.note("No remote servers yet.")
            let wrapper = NSView()
            wrapper.addSubview(note)
            note.pinEdges(to: wrapper, insets: NSEdgeInsets(top: 4, left: 10, bottom: 6, right: 10))
            add(wrapper)
        }
        let headed = groups.contains { $0.group != nil }
        for (group, members) in groups {
            if headed {
                let heading = HostMenuGroupHeading(group ?? "Ungrouped")
                heading.onMenu = { [weak self] view, point in
                    self?.controller.showGroupMenu(group, in: view, at: point)
                }
                add(heading)
            }
            for server in members {
                let row = HostMenuServerRow(server)
                let id = server.id
                row.onEdit = { [weak self] in
                    self?.dismiss?()
                    self?.controller.editServer(id)
                }
                row.onMenu = { [weak self] view, point in
                    self?.controller.showServerMenu(id, in: view, at: point)
                }
                rows[id] = row
                add(row)
            }
        }
        add(Divider())
        add(action(.plus, "Add Server…") { [weak self] in
            self?.dismiss?()
            self?.controller.editServer(nil)
        })
        add(action(.settings, "Manage Remote Servers…") { [weak self] in
            self?.dismiss?()
            self?.controller.host?.showRemoteServersPane()
        })
        fitHeight()
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func action(_ icon: AppIcon, _ title: String, _ perform: @escaping () -> Void) -> ListRow {
        let row = ListRow(title: title, icon: icon.image())
        row.onClick = perform
        return row
    }

    private func fitHeight() {
        stack.layoutSubtreeIfNeeded()
        let height = min(stack.fittingSize.height + 12, maximumHeight)
        guard heightConstraint?.constant != height else { return }
        heightConstraint?.constant = height
        onSizeChange?(NSSize(width: Self.width, height: height))
    }
}

/// A hairline between sections.
final class Divider: ThemedView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 9).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        theme.separator.setFill()
        NSRect(x: 6, y: 4, width: bounds.width - 12, height: 1).fill()
    }
}
