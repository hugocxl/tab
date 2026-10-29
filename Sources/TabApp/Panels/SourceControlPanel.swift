import AppKit
import TabCore
import TabProtocol

/// What the Source Control panel needs from the app.
@MainActor
public protocol SourceControlHost: NativeHost {
    /// Opens a file's diff in a pane, of its index when `staged`.
    func openDiff(path: String, staged: Bool)
    /// The panel changed the repository: open diffs should refresh.
    func repositoryDidChange()
    /// Whether an AI tool is configured to write commit messages.
    var canGenerateCommitMessage: Bool { get }
    /// Writes a commit message for the staged changes with the configured AI tool.
    func generateCommitMessage() async throws -> String
    /// Hides the panel.
    func closeSourceControl()
}

/// The Source Control panel pinned on the right of a project: branch,
/// commit message, Amend and Commit, and the changed files by group.
@MainActor
public final class SourceControlController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public weak var host: SourceControlHost?
    public private(set) var model = SourceControlModel()
    public private(set) var isBusy = false
    private var error: String?
    private var stale = true
    private var amend = false
    private var generating = false

    private let card = NativePanelCard()

    /// Whether the panel draws its own rounded card; off when the shell
    /// draws the panel's frame.
    public var drawsCard: Bool {
        get { card.drawsCard }
        set { card.drawsCard = newValue }
    }
    private let header = NativePanelHeader(icon: .gitBranch, title: "Source Control")
    private let refreshButton = IconButton(.refresh, label: "Refresh")
    private let spinner = Spinner()
    let messageField = CommitMessageField(placeholder: "Message (⌘↩ to commit)")
    private let amendBox = NSButton(checkboxWithTitle: "Amend", target: nil, action: nil)
    private let generateButton = IconButton(.sparkles, label: "Generate Commit Message")
    let commitButton = PillButton("Commit")
    private let message = NativeMessageView("Loading changes…")
    private let table = NSTableView()
    private let scroll = NSScrollView()

    public init(host: SourceControlHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        let theme = host?.theme ?? .shared
        card.theme = theme
        view = card
        header.title = host?.nativeProject.name ?? "Source Control"
        refreshButton.action = { [weak self] in self?.refresh() }
        spinner.isHidden = true
        header.addTrailing(spinner)
        header.addTrailing(refreshButton)
        header.addTrailing(IconButton(.close, label: "Close") { [weak self] in self?.host?.closeSourceControl() })

        messageField.theme = theme
        messageField.onChange = { [weak self] in self?.updateCommitButton() }
        messageField.onSubmit = { [weak self] in self?.commit() }

        amendBox.target = self
        amendBox.action = #selector(toggleAmend)
        amendBox.font = AppFont.body
        generateButton.action = { [weak self] in self?.generateMessage() }
        generateButton.isHidden = !(host?.canGenerateCommitMessage ?? false)
        commitButton.action = { [weak self] in self?.commit() }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let commitRow = NSStackView(views: [amendBox, spacer, generateButton, commitButton])
        commitRow.orientation = .horizontal
        commitRow.alignment = .centerY
        commitRow.spacing = Metrics.controlGap

        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 28
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.style = .plain
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Changes")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        message.theme = theme
        let stack = NSStackView(views: [header, messageField, commitRow, message, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.controlGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.gutter),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Metrics.gutter),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.gutter),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commitRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.heightAnchor.constraint(equalToConstant: 32),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        message.setContentHuggingPriority(.required, for: .vertical)
        themeDidChange()
        render()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        if stale || model.status == nil { refresh() }
    }

    // MARK: Events from the app

    /// The repository changed on the server: refreshes when shown, else on
    /// the next showing.
    public func gitChanged() {
        guard isViewLoaded, view.window != nil else {
            stale = true
            return
        }
        refresh()
    }

    /// The side connection opened again.
    public func reconnected() { gitChanged() }

    /// Puts the caret in the commit message.
    public func focusMessage() {
        messageField.focus()
    }

    public func themeDidChange() {
        let theme = card.theme
        amendBox.attributedTitle = NSAttributedString(string: "Amend", attributes: [.foregroundColor: theme.fg, .font: AppFont.body])
        amendBox.appearance = theme.nsAppearance
        table.reloadData()
    }

    // MARK: Requests

    /// Reads the working tree status again.
    public func refresh() {
        stale = false
        guard let host, let transport = host.nativeTransport else { return }
        let request = GitRequest(project: host.nativeProject.id, action: .status(local: true))
        Task { [weak self] in
            do {
                let reply = try await transport.git(request)
                self?.received(reply)
            } catch {
                self?.showError(NativeErrors.describe(error))
            }
        }
    }

    func received(_ reply: GitReply) {
        guard case .status(let status) = reply else { return }
        error = nil
        model.setStatus(status)
        render()
    }

    private func showError(_ text: String?) {
        error = text.map { NativeErrors.friendly($0, folder: true) }
        render()
    }

    /// Runs a change the user asked for, then reads the status again.
    private func change(_ action: GitAction, committed: Bool = false) {
        guard let host, !isBusy else { return }
        guard let transport = host.nativeTransport else {
            host.showToast("The project's server isn't connected.", style: .error)
            return
        }
        setBusy(true)
        error = nil
        let request = GitRequest(project: host.nativeProject.id, action: action)
        Task { [weak self] in
            var failure: String?
            do {
                _ = try await transport.git(request)
            } catch {
                failure = NativeErrors.friendly(error, folder: true)
            }
            guard let self else { return }
            self.setBusy(false)
            if let failure {
                if committed {
                    self.host?.showToast(failure, style: .error)
                } else {
                    self.showError(failure)
                }
            } else if committed {
                self.messageField.string = ""
                self.amend = false
                self.amendBox.state = .off
            }
            self.refresh()
            self.host?.repositoryDidChange()
        }
    }

    func stage(_ paths: [String]) { change(.stage(paths.map { ServerPath($0) })) }
    func unstage(_ paths: [String]) { change(.unstage(paths.map { ServerPath($0) })) }

    func discard(_ paths: [String]) {
        host?.confirm(
            title: paths.count == 1 ? "Discard Changes?" : "Discard \(paths.count) Changes?",
            message: SourceControlModel.discardMessage(paths),
            confirmTitle: "Discard",
            destructive: true
        ) { [weak self] confirmed in
            guard confirmed else { return }
            self?.change(.discard(paths.map { ServerPath($0) }))
        }
    }

    func commit() {
        guard model.canCommit(message: messageField.string, amend: amend, busy: isBusy) else { return }
        change(.commit(message: messageField.string, stageAll: false, amend: amend), committed: true)
    }

    /// Checks or clears Amend, as clicking the box does.
    func setAmend(_ on: Bool) {
        amendBox.state = on ? .on : .off
        toggleAmend()
    }

    @objc private func toggleAmend() {
        guard !isBusy else {
            amendBox.state = amend ? .on : .off
            return
        }
        amend = amendBox.state == .on
        updateCommitButton()
    }

    private func generateMessage() {
        guard let host, !generating else { return }
        generating = true
        generateButton.isEnabled = false
        Task { [weak self] in
            do {
                let text = try await host.generateCommitMessage()
                self?.messageField.string = text
            } catch {
                self?.host?.showToast(NativeErrors.describe(error), style: .error)
            }
            self?.generating = false
            self?.generateButton.isEnabled = true
            self?.updateCommitButton()
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        spinner.isHidden = !busy
        refreshButton.isHidden = busy
        amendBox.isEnabled = !busy
        updateCommitButton()
        table.reloadData()
    }

    // MARK: Drawing

    private func render() {
        guard isViewLoaded else { return }
        if let branch = model.status?.summary.branch, !branch.isEmpty {
            header.title = branch
        } else {
            header.title = host?.nativeProject.name ?? header.title
        }
        if let error {
            message.set(error)
            message.isHidden = false
        } else if model.rows.isEmpty {
            message.set(model.status == nil ? "Loading changes…" : "No changes")
            message.isHidden = false
        } else {
            message.isHidden = true
        }
        scroll.isHidden = model.rows.isEmpty
        table.reloadData()
        updateCommitButton()
    }

    private func updateCommitButton() {
        commitButton.title = amend ? "Amend" : "Commit"
        commitButton.isEnabled = model.canCommit(message: messageField.string, amend: amend, busy: isBusy)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.rows.indices.contains(row) else { return nil }
        switch model.rows[row] {
        case .header(let group):
            let identifier = NSUserInterfaceItemIdentifier("group")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ChangeGroupCell) ?? ChangeGroupCell()
            cell.identifier = identifier
            cell.theme = card.theme
            cell.configure(group: group, count: model.files(in: group).count, collapsed: model.collapsed.contains(group), busy: isBusy)
            cell.onToggle = { [weak self] in
                self?.model.toggle(group)
                self?.render()
            }
            cell.onBulk = { [weak self] in
                guard let self else { return }
                let paths = self.model.paths(in: group)
                if group == .staged { self.unstage(paths) } else { self.stage(paths) }
            }
            return cell
        case .file(let group, let index):
            guard let entry = model.file(index) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("file")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? ChangeFileCell) ?? ChangeFileCell()
            cell.identifier = identifier
            cell.theme = card.theme
            cell.configure(entry: entry, group: group, busy: isBusy)
            let path = entry.file.path.rawValue
            cell.onOpen = { [weak self] in
                guard let self, !self.isBusy else { return }
                self.host?.openDiff(path: path, staged: group == .staged)
            }
            cell.onStage = { [weak self] in self?.stage([path]) }
            cell.onUnstage = { [weak self] in self?.unstage([path]) }
            cell.onDiscard = { [weak self] in self?.discard([path]) }
            return cell
        }
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// The multi-line commit message: a dark inset field that grows from three
/// to eight lines, with a placeholder; Cmd+Return submits.
final class CommitMessageField: ThemedView, NSTextViewDelegate {
    let textView = PlaceholderTextView()
    private let scroll = NSScrollView()
    private var heightConstraint: NSLayoutConstraint?
    var onChange: (() -> Void)?
    var onSubmit: (() -> Void)?
    private static let padding: CGFloat = 8

    init(placeholder: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        textView.placeholder = placeholder
        textView.font = AppFont.body
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.setAccessibilityLabel("Commit message")
        textView.onCommandReturn = { [weak self] in self?.onSubmit?() }
        textView.onFocusChange = { [weak self] in self?.needsDisplay = true }
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let height = heightAnchor.constraint(equalToConstant: Self.height(lines: 3))
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static var lineHeight: CGFloat {
        let font = AppFont.body
        return (font.ascender - font.descender + font.leading).rounded(.up)
    }

    private static func height(lines: Int) -> CGFloat {
        CGFloat(lines) * lineHeight + padding * 2
    }

    var string: String {
        get { textView.string }
        set {
            textView.string = newValue
            textChanged()
        }
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    override func themeDidChange() {
        textView.textColor = theme.fg
        textView.insertionPointColor = theme.fg
        textView.placeholderColor = theme.fgDim
        textView.typingAttributes = [.font: AppFont.body, .foregroundColor: theme.fg]
        needsDisplay = true
        textView.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium)
        theme.surface.setFill()
        path.fill()
        let editing = window?.firstResponder === textView
        (editing ? theme.accent : theme.border).setStroke()
        path.lineWidth = editing ? 1.5 : Metrics.border
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        focus()
    }

    func textDidChange(_ notification: Notification) {
        textChanged()
    }

    private func textChanged() {
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            let lines = Int((used / Self.lineHeight).rounded(.up))
            heightConstraint?.constant = Self.height(lines: min(max(lines, 3), 8))
        }
        textView.needsDisplay = true
        onChange?()
    }
}

/// A plain text view with a placeholder and a Cmd+Return hook.
final class PlaceholderTextView: NSTextView {
    var placeholder = ""
    var placeholderColor = NSColor.placeholderTextColor
    var onCommandReturn: (() -> Void)?
    var onFocusChange: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? AppFont.body, .foregroundColor: placeholderColor]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attributes)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isCommandReturn(event), window?.firstResponder === self {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isCommandReturn(event) {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }

    private func isCommandReturn(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return (event.keyCode == 36 || event.keyCode == 76) && flags == .command
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        onFocusChange?()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        onFocusChange?()
        return accepted
    }
}

/// A small text button such as "Stage All", "+" or "↺": muted text with a
/// hover pill.
final class TextGlyphButton: HoverView {
    private let label: NSTextField
    var action: (() -> Void)?
    var isEnabled = true { didSet { themeDidChange() } }

    init(_ title: String, tooltip: String, font: NSFont = AppFont.body) {
        label = makeLabel(title, font: font)
        label.alignment = .center
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tooltip
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            heightAnchor.constraint(equalToConstant: 20),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tooltip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func themeDidChange() {
        label.textColor = isHovered && isEnabled ? theme.fg : theme.fgMuted
        alphaValue = isEnabled ? 1 : 0.4
        needsDisplay = true
    }

    override func hoverDidChange() { themeDidChange() }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered, isEnabled else { return }
        theme.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusSmall, yRadius: Metrics.radiusSmall).fill()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action?()
        return true
    }
}

/// A group heading: chevron, title with count, and Stage All or Unstage All.
final class ChangeGroupCell: ThemedView {
    private let chevron = NSImageView()
    private let title = makeLabel("", font: AppFont.header)
    private let bulk = TextGlyphButton("", tooltip: "")
    var onToggle: (() -> Void)?
    var onBulk: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bulk.action = { [weak self] in self?.onBulk?() }
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        addSubview(title)
        addSubview(bulk)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            title.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: bulk.leadingAnchor, constant: -4),
            bulk.trailingAnchor.constraint(equalTo: trailingAnchor),
            bulk.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(group: SourceControlModel.Group, count: Int, collapsed: Bool, busy: Bool) {
        title.stringValue = "\(group.title) (\(count))"
        chevron.image = (collapsed ? AppIcon.chevronRight : AppIcon.chevronDown).image(size: 12)
        bulk.setLabel(group.bulkTitle)
        bulk.isEnabled = !busy
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(group.title), \(count) files")
    }

    override func themeDidChange() {
        title.textColor = theme.fgMuted
        chevron.contentTintColor = theme.fgMuted
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onToggle?()
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }
}

extension TextGlyphButton {
    func setLabel(_ text: String) {
        (subviews.first as? NSTextField)?.stringValue = text
        toolTip = text
        setAccessibilityLabel(text)
    }
}

/// A changed file: colored status letter, name, folder, line counts, and
/// stage, unstage and discard buttons on hover.
final class ChangeFileCell: HoverView {
    private let letter = makeLabel("", font: AppFont.system(13, weight: .semibold))
    private let name = makeLabel("", font: AppFont.body)
    private let folder = makeLabel("", font: AppFont.body)
    private let added = makeLabel("", font: AppFont.footnote)
    private let removed = makeLabel("", font: AppFont.footnote)
    private let actions = NSStackView()
    private let stageButton = TextGlyphButton("+", tooltip: "Stage")
    private let unstageButton = TextGlyphButton("−", tooltip: "Unstage")
    private let discardButton = TextGlyphButton("↺", tooltip: "Discard")
    private var tone = SourceControlModel.Tone.modified
    var onOpen: (() -> Void)?
    var onStage: (() -> Void)?
    var onUnstage: (() -> Void)?
    var onDiscard: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        stageButton.action = { [weak self] in self?.onStage?() }
        unstageButton.action = { [weak self] in self?.onUnstage?() }
        discardButton.action = { [weak self] in self?.onDiscard?() }
        actions.orientation = .horizontal
        actions.spacing = 0
        actions.addArrangedSubview(stageButton)
        actions.addArrangedSubview(unstageButton)
        actions.addArrangedSubview(discardButton)
        actions.isHidden = true
        letter.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        folder.lineBreakMode = .byTruncatingHead
        name.setContentCompressionResistancePriority(.defaultHigh - 1, for: .horizontal)
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folder.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [letter, name, folder, added, removed, actions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(row)
        row.pinEdges(to: self, insets: NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 2))
        letter.widthAnchor.constraint(equalToConstant: 14).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(entry: GitFileStatus, group: SourceControlModel.Group, busy: Bool) {
        let path = entry.file.path.rawValue
        let code = SourceControlModel.letter(entry.file, in: group)
        tone = SourceControlModel.tone(code, in: group)
        letter.stringValue = String(code)
        name.stringValue = NativePath.basename(path)
        folder.stringValue = NativePath.parent(path)
        let stat = group == .staged ? entry.staged : entry.unstaged
        if stat.binary {
            added.stringValue = "Binary"
            removed.stringValue = ""
        } else {
            added.stringValue = stat.additions.map { "+\($0)" } ?? ""
            removed.stringValue = stat.deletions.map { "−\($0)" } ?? ""
        }
        added.isHidden = added.stringValue.isEmpty
        removed.isHidden = removed.stringValue.isEmpty
        stageButton.isHidden = group == .staged
        unstageButton.isHidden = group != .staged
        discardButton.isHidden = group == .staged || group == .conflicts
        for button in [stageButton, unstageButton, discardButton] { button.isEnabled = !busy }
        alphaValue = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(path), \(group.title)")
        themeDidChange()
    }

    override func themeDidChange() {
        switch tone {
        case .conflict: letter.textColor = theme.danger
        case .added: letter.textColor = theme.diffAdd
        case .deleted: letter.textColor = theme.diffRemove
        case .renamed: letter.textColor = theme.accent
        case .modified: letter.textColor = theme.warning
        }
        name.textColor = theme.fg
        folder.textColor = theme.fgMuted
        added.textColor = added.stringValue == "Binary" ? theme.fgMuted : theme.diffAdd
        removed.textColor = theme.diffRemove
        needsDisplay = true
    }

    override func hoverDidChange() {
        actions.isHidden = !isHovered
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        theme.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: Metrics.radiusSmall, yRadius: Metrics.radiusSmall).fill()
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?()
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }
}
