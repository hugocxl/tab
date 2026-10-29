import AppKit
import TabCore
import TabProtocol

/// What the Files panel needs from the app.
@MainActor
public protocol FilesPanelHost: NativeHost {
    /// Opens the project file at `path` in an editor pane, with the caret at
    /// a one-based line and column when given.
    func openEditor(path: String, line: Int?, column: Int?)
    /// Makes the side connection watch the project's folder, so
    /// `filesChanged(_:)` hears about changes on disk.
    func watchProjectFiles()
    /// Hides the panel.
    func closeFilesPanel()
}

/// The Files panel pinned on the right of a project: the project's tree,
/// listed lazily from its server and kept current from file watch events.
@MainActor
public final class FilesPanelController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public weak var host: FilesPanelHost?
    public private(set) var tree = FilesTree()
    private(set) var rows: [FilesTree.Row] = []
    private var edit: Edit?
    private var error: String?

    private enum Edit: Equatable {
        case rename(String)
        case newFile(String)
        case newFolder(String)
    }

    private let card = NativePanelCard()

    /// Whether the panel draws its own rounded card; off when the shell
    /// draws the panel's frame.
    public var drawsCard: Bool {
        get { card.drawsCard }
        set { card.drawsCard = newValue }
    }
    private let header = NativePanelHeader(icon: .folder, title: "Files")
    private let editArea = NSStackView()
    private let editLabel = makeLabel("", font: AppFont.footnote)
    private(set) var newItemField: InlineNameField?
    private(set) var renameField: InlineNameField?
    private let statusLabel = makeLabel("", font: AppFont.footnote)
    let table = FilesTableView()
    private let scroll = NSScrollView()

    public init(host: FilesPanelHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        card.theme = host?.theme ?? .shared
        view = card
        header.title = host?.nativeProject.name ?? "Files"
        let buttons: [(AppIcon, String, () -> Void)] = [
            (.file, "New File", { [weak self] in self?.beginNewItem(folder: false) }),
            (.folder, "New Folder", { [weak self] in self?.beginNewItem(folder: true) }),
            (.chevronUp, "Collapse All", { [weak self] in self?.collapseAll() }),
            (.refresh, "Refresh", { [weak self] in self?.refreshAll() }),
            (.close, "Close", { [weak self] in self?.host?.closeFilesPanel() }),
        ]
        for (icon, label, action) in buttons {
            header.addTrailing(IconButton(icon, label: label, action: action))
        }

        editArea.orientation = .vertical
        editArea.alignment = .leading
        editArea.spacing = 4
        editArea.addArrangedSubview(editLabel)
        editArea.isHidden = true
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0

        table.controller = self
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 24
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.style = .plain
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Files")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let stack = NSStackView(views: [header, editArea, statusLabel, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.gutter),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Metrics.gutter),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.gutter),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            editArea.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        applyColors()
        updateStatus()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        host?.watchProjectFiles()
        ensureRoot()
    }

    // MARK: Events from the app

    /// Files changed on the project's server: lists the affected folders again.
    public func filesChanged(_ changes: FileChanges) {
        for path in tree.refresh(paths: changes.paths.map(\.rawValue), rescan: changes.rescan) {
            list(path)
        }
        changed()
    }

    /// The side connection opened again: lists everything shown again.
    public func reconnected() {
        tree.retry()
        error = nil
        filesChanged(FileChanges(rescan: true))
    }

    /// The project was renamed.
    public func projectDidChange() {
        header.title = host?.nativeProject.name ?? header.title
    }

    /// The theme changed.
    public func themeDidChange() {
        applyColors()
        table.reloadData()
    }

    /// Selects `path`, the file the focused editor shows, expanding its folders.
    public func reveal(path: String) {
        guard tree.selected != path else { return }
        for folder in tree.reveal(path) { list(folder) }
        changed()
        scrollToSelection()
    }

    /// Gives the tree the keyboard.
    public func focus() {
        view.window?.makeFirstResponder(table)
    }

    /// Lists the root if nothing is shown yet.
    public func ensureRoot() {
        if tree.request("") {
            list("")
            return
        }
        guard rows.isEmpty else { return }
        filesChanged(FileChanges(rescan: true))
    }

    // MARK: Requests

    private func list(_ path: String) {
        guard let host, let transport = host.nativeTransport else { return }
        let request = FilesRequest(project: host.nativeProject.id, action: .list(ServerPath(path)))
        Task { [weak self] in
            do {
                let reply = try await transport.files(request)
                self?.listed(path, reply)
            } catch {
                self?.failed(NativeErrors.describe(error))
            }
        }
    }

    func listed(_ path: String, _ reply: FilesReply) {
        guard case .entries(let entries) = reply else {
            failed(NativeErrors.unexpectedReply)
            return
        }
        error = nil
        if tree.setEntries(path, entries) { list(path) }
        changed()
    }

    private func failed(_ message: String) {
        tree.retry()
        error = NativeErrors.friendly(message, folder: true)
        updateStatus()
    }

    /// Runs a change to the project's files, then lists the folders it touched.
    private func mutate(_ action: FilesAction, touched: [String], then: (() -> Void)? = nil) {
        guard let host else { return }
        guard let transport = host.nativeTransport else {
            host.showToast("The project's server isn't connected.", style: .error)
            return
        }
        let request = FilesRequest(project: host.nativeProject.id, action: action)
        Task { [weak self] in
            do {
                _ = try await transport.files(request)
                guard let self else { return }
                for path in self.tree.refresh(paths: touched, rescan: false) { self.list(path) }
                self.changed()
                then?()
            } catch {
                self?.error = NativeErrors.friendly(error, folder: false)
                self?.updateStatus()
            }
        }
    }

    // MARK: Actions

    /// Opens a file in an editor, or expands or collapses a folder.
    func open(_ path: String) {
        guard tree.node(path)?.isDirectory == true else {
            host?.openEditor(path: path, line: nil, column: nil)
            return
        }
        if tree.isExpanded(path) {
            tree.collapse(path)
        } else if tree.expand(path) {
            list(path)
        }
        changed()
    }

    func click(row: Int) {
        guard rows.indices.contains(row) else { return }
        let path = rows[row].node.path
        if case .rename(let editing) = edit, editing == path { return }
        cancelEdit()
        view.window?.makeFirstResponder(table)
        tree.selected = path
        open(path)
        table.reloadData()
    }

    private func collapseAll() {
        tree.collapseAll()
        changed()
    }

    private func refreshAll() {
        error = nil
        filesChanged(FileChanges(rescan: true))
        if rows.isEmpty, tree.request("") { list("") }
    }

    func beginNewItem(folder: Bool) {
        let directory = tree.selectedDirectory
        if tree.request(directory) { list(directory) }
        cancelEdit()
        edit = folder ? .newFolder(directory) : .newFile(directory)
        let place = directory.isEmpty ? "/" : directory
        editLabel.stringValue = folder ? "New folder in \(place)" : "New file in \(place)"
        let field = InlineNameField(text: "", label: folder ? "New folder name" : "New file name")
        field.theme = card.theme
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: Metrics.controlHeight).isActive = true
        configure(field)
        editArea.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: editArea.widthAnchor).isActive = true
        newItemField = field
        editArea.isHidden = false
        error = nil
        updateStatus()
        field.begin()
    }

    func beginRename(_ path: String) {
        cancelEdit()
        tree.selected = path
        edit = .rename(path)
        error = nil
        updateStatus()
        guard let index = rows.firstIndex(where: { $0.node.path == path }) else { return }
        table.scrollRowToVisible(index)
        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? FilesCellView else { return }
        let field = InlineNameField(text: NativePath.basename(path), label: "Name")
        field.theme = card.theme
        configure(field)
        renameField = field
        cell.showEditor(field)
        field.begin()
    }

    private func configure(_ field: InlineNameField) {
        field.onSubmit = { [weak self, weak field] name in
            guard let self, let field else { return }
            if !self.submit(name) { field.resume() }
        }
        field.onCancel = { [weak self] in self?.cancelEdit(returnFocus: true) }
        field.onChange = { [weak self] in
            guard let self, self.error != nil else { return }
            self.error = nil
            self.updateStatus()
        }
    }

    /// Creates or renames with `name`; `false` when the name is refused.
    private func submit(_ name: String) -> Bool {
        guard let edit else { return true }
        guard NativePath.isValidName(name) else {
            showEditError("Enter a name without path separators.")
            return false
        }
        let directory: String
        switch edit {
        case .rename(let path): directory = NativePath.parent(path)
        case .newFile(let dir), .newFolder(let dir): directory = dir
        }
        guard tree.isLoaded(directory) else {
            showEditError("Wait for the folder listing before choosing a name.")
            return false
        }
        let path = NativePath.join(directory, name)
        if tree.node(path) != nil, edit != .rename(path) {
            showEditError("A file or folder with this name already exists.")
            return false
        }
        cancelEdit(returnFocus: true)
        switch edit {
        case .rename(let from) where from != path:
            mutate(.rename(path: ServerPath(from), name: ServerPath(name)), touched: [from, path])
        case .rename:
            break
        case .newFile:
            mutate(.write(path: ServerPath(path), content: ""), touched: [path]) { [weak self] in
                self?.host?.openEditor(path: path, line: nil, column: nil)
            }
        case .newFolder:
            mutate(.mkdir(ServerPath(path)), touched: [path])
        }
        return true
    }

    private func showEditError(_ message: String) {
        error = message
        updateStatus()
    }

    private func cancelEdit(returnFocus: Bool = false) {
        guard let current = edit else { return }
        edit = nil
        if let newItemField {
            newItemField.onCancel = nil
            newItemField.removeFromSuperview()
            self.newItemField = nil
        }
        editArea.isHidden = true
        if case .rename = current, let renameField {
            renameField.onCancel = nil
            renameField.removeFromSuperview()
            self.renameField = nil
            table.reloadData()
        }
        if returnFocus { view.window?.makeFirstResponder(table) }
        updateStatus()
    }

    func confirmDelete(_ path: String) {
        let name = NativePath.basename(path)
        host?.confirm(
            title: "Delete “\(name)”?",
            message: "It moves to the Trash on the computer that has the project.",
            confirmTitle: "Delete",
            destructive: true
        ) { [weak self] confirmed in
            guard confirmed else { return }
            self?.mutate(.delete([ServerPath(path)]), touched: [path])
        }
    }

    func menu(forRow row: Int) -> NSMenu? {
        guard rows.indices.contains(row), let host else { return nil }
        let node = rows[row].node
        tree.selected = node.path
        table.reloadData()
        let menu = NSMenu()
        if !node.isDirectory {
            menu.addItem(ActionMenuItem("Open") { [weak self] in self?.open(node.path) })
            menu.addItem(.separator())
        }
        menu.addItem(ActionMenuItem("New File…") { [weak self] in self?.beginNewItem(folder: false) })
        menu.addItem(ActionMenuItem("New Folder…") { [weak self] in self?.beginNewItem(folder: true) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Rename…") { [weak self] in self?.beginRename(node.path) })
        menu.addItem(ActionMenuItem("Delete") { [weak self] in self?.confirmDelete(node.path) })
        menu.addItem(.separator())
        let project = host.nativeProject
        menu.addItem(ActionMenuItem("Copy Path") { Self.copy(project.absolutePath(node.path)) })
        menu.addItem(ActionMenuItem("Copy Relative Path") { Self.copy(node.path) })
        if project.isLocal {
            menu.addItem(ActionMenuItem("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.absolutePath(node.path))])
            })
        }
        return menu
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Handles a key in the tree; `false` lets it go on.
    func key(_ event: NSEvent) -> Bool {
        guard edit == nil else { return false }
        let selected = tree.selected
        let horizontal: Bool
        switch Int(event.keyCode) {
        case 126: tree.step(forward: false); horizontal = false
        case 125: tree.step(forward: true); horizontal = false
        case 123: tree.left(); horizontal = true
        case 124:
            if let folder = tree.right() { list(folder) }
            horizontal = true
        case 36, 76:
            guard let selected else { return true }
            open(selected)
            return true
        case 120:
            guard let selected else { return true }
            beginRename(selected)
            return true
        case 51 where event.modifierFlags.contains(.command):
            guard let selected else { return true }
            confirmDelete(selected)
            return true
        default:
            return false
        }
        if horizontal { changed() } else { table.reloadData() }
        scrollToSelection()
        return true
    }

    // MARK: Drawing

    private func changed() {
        rows = tree.visible()
        for row in rows where row.node.isDirectory && tree.isExpanded(row.node.path) && tree.request(row.node.path) {
            list(row.node.path)
        }
        guard isViewLoaded else { return }
        table.reloadData()
        updateStatus()
    }

    private func scrollToSelection() {
        guard let selected = tree.selected, let index = rows.firstIndex(where: { $0.node.path == selected }) else { return }
        table.scrollRowToVisible(index)
    }

    private func updateStatus() {
        guard isViewLoaded else { return }
        if let error {
            statusLabel.stringValue = error
            statusLabel.textColor = card.theme.danger
            statusLabel.isHidden = false
        } else if !tree.isLoaded("") {
            statusLabel.stringValue = "Loading…"
            statusLabel.textColor = card.theme.fgMuted
            statusLabel.isHidden = false
        } else {
            statusLabel.isHidden = true
        }
    }

    private func applyColors() {
        editLabel.textColor = card.theme.fgMuted
        updateStatus()
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("file")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? FilesCellView) ?? FilesCellView()
        cell.identifier = identifier
        cell.theme = card.theme
        let item = rows[row]
        cell.configure(
            node: item.node,
            depth: item.depth,
            expanded: tree.isExpanded(item.node.path),
            selected: tree.selected == item.node.path
        )
        if case .rename(let path) = edit, path == item.node.path, let renameField {
            cell.showEditor(renameField)
        } else {
            cell.hideEditor()
        }
        return cell
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// The tree's table: clicks, keys and context menus go to the controller,
/// which owns the selection.
final class FilesTableView: NSTableView {
    weak var controller: FilesPanelController?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else {
            window?.makeFirstResponder(self)
            return
        }
        controller?.click(row: row)
    }

    override func keyDown(with event: NSEvent) {
        let handled = controller?.key(event) ?? false
        if !handled { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return controller?.menu(forRow: row)
    }
}

/// One tree row, drawn directly: chevron, folder or file glyph and name,
/// with hover and selection fills.
final class FilesCellView: HoverView {
    private var node = FilesTree.Node(path: "", name: "", isDirectory: false, dimmed: false)
    private var depth = 0
    private var expanded = false
    private var selected = false
    private weak var editor: InlineNameField?

    static let indent: CGFloat = 12

    func configure(node: FilesTree.Node, depth: Int, expanded: Bool, selected: Bool) {
        self.node = node
        self.depth = depth
        self.expanded = expanded
        self.selected = selected
        setAccessibilityElement(true)
        setAccessibilityRole(node.isDirectory ? .group : .row)
        setAccessibilityLabel(node.name)
        needsDisplay = true
    }

    private var textX: CGFloat { 4 + CGFloat(depth) * Self.indent + 12 + 4 + 14 + 6 }

    func showEditor(_ field: InlineNameField) {
        guard editor !== field else { return }
        hideEditor()
        field.frame = NSRect(x: textX - 4, y: 1, width: max(bounds.width - textX, 40), height: bounds.height - 2)
        field.autoresizingMask = [.width]
        addSubview(field)
        editor = field
        needsDisplay = true
    }

    func hideEditor() {
        guard let editor else { return }
        if editor.superview === self { editor.removeFromSuperview() }
        self.editor = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium)
        if selected {
            theme.surface.setFill()
            path.fill()
            theme.cardBorder.setStroke()
            path.lineWidth = Metrics.border
            path.stroke()
        } else if isHovered {
            theme.hover.setFill()
            path.fill()
        }
        var x = 4 + CGFloat(depth) * Self.indent
        let midY = bounds.midY
        if node.isDirectory, let chevron = (expanded ? AppIcon.chevronDown : AppIcon.chevronRight).image(size: 12) {
            chevron.tinted(theme.fgMuted).draw(in: NSRect(x: x, y: midY - 6, width: 12, height: 12),
                                                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        x += 16
        let color = node.dimmed ? theme.fgMuted : theme.fg
        if let glyph = (node.isDirectory ? AppIcon.folder : AppIcon.file).image(size: 14) {
            glyph.tinted(color).draw(in: NSRect(x: x, y: midY - 7, width: 14, height: 14),
                                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        guard editor == nil else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: AppFont.body, .foregroundColor: color, .paragraphStyle: style]
        let text = NSAttributedString(string: node.name, attributes: attributes)
        let height = text.size().height
        text.draw(in: NSRect(x: textX, y: midY - height / 2, width: max(bounds.width - textX - 4, 0), height: height))
    }
}
