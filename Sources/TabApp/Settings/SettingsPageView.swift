import AppKit
import TabCore

/// The back and forward pill of the page header.
final class NavigationPill: ThemedView {
    let back: IconButton
    let forward: IconButton

    init(back: @escaping () -> Void, forward: @escaping () -> Void) {
        self.back = IconButton(.chevronLeft, label: "Back", side: 26, action: back)
        self.forward = IconButton(.chevronRight, label: "Forward", side: 26, action: forward)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = hstack([self.back, self.forward], spacing: 2)
        addSubview(stack)
        stack.pinEdges(to: self, insets: NSEdgeInsets(top: 0, left: 1, bottom: 0, right: 1))
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        theme.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        theme.border.setFill()
        NSRect(x: (bounds.width / 2).rounded(), y: 5, width: 1, height: bounds.height - 10).fill()
    }
}

/// The right side of the Settings window: header with navigation, title and
/// "Edit in …", then the scrolling page and its footer.
@MainActor
final class SettingsPageView: ThemedView {
    let store: SettingsStore
    var category: SettingsCategory = .general
    var section: String?
    var expanded: SettingsCategory? = .general
    var query = ""
    var onNavigate: ((SettingsCategory) -> Void)?

    /// Transient editors on the page.
    var commandDraft: CustomCommand?
    var bindingDraft: BindingDraft?
    var codepointDraft: CodepointDraft?
    var profileName = ""
    /// The project whose pull request prompt the AI page edits.
    var promptProject: String?

    private(set) var navigation: NavigationPill!
    let titleLabel = makeLabel("", font: AppFont.title)
    private(set) var editLink: LinkButton?
    private let header = NSStackView()
    private let banners = NSStackView()
    let scroll = ScrollView()
    private let column = NSStackView()
    private(set) var lastBuild: SettingsPageBuilder?
    private(set) var fields: [String: InsetTextField] = [:]

    init(store: SettingsStore) {
        self.store = store
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        navigation = NavigationPill(
            back: { [weak self] in self?.step(-1) },
            forward: { [weak self] in self?.step(1) }
        )
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Metrics.gutter
        header.translatesAutoresizingMaskIntoConstraints = false
        banners.orientation = .vertical
        banners.alignment = .width
        banners.spacing = 4
        banners.translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.content.addSubview(column)
        for view in [header, banners, scroll] as [NSView] { addSubview(view) }
        let inset = Metrics.gutter * 2.5
        let width = column.widthAnchor.constraint(equalToConstant: 640)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            header.heightAnchor.constraint(equalToConstant: 30),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            banners.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7),
            banners.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            banners.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            scroll.topAnchor.constraint(equalTo: banners.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.topAnchor.constraint(equalTo: scroll.content.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: scroll.content.bottomAnchor, constant: -24),
            column.centerXAnchor.constraint(equalTo: scroll.content.centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.content.leadingAnchor, constant: inset),
            width,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.bg.cgColor
    }

    override func themeDidChange() {
        titleLabel.textColor = theme.fg
        needsDisplay = true
    }

    private func step(_ delta: Int) {
        let all = SettingsCategory.allCases
        guard let index = all.firstIndex(of: category), all.indices.contains(index + delta) else { return }
        onNavigate?(all[index + delta])
    }

    func resetScroll() {
        pendingScrollReset = true
    }

    private var pendingScrollReset = false

    /// Rebuilds the page from the store, keeping the scroll position and the
    /// field being edited.
    func reload() {
        let editing = fields.first { $0.value.isEditing }
        let editingText = editing?.value.stringValue
        let editingSelection = (editing?.value.field.currentEditor() as? NSTextView)?.selectedRange()
        let offset = pendingScrollReset ? 0 : scroll.scrollOffset
        pendingScrollReset = false

        rebuildHeader()
        rebuildBanners()
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let builder = SettingsPageBuilder(store: store, query: query, category: category, section: section)
        if builder.isSearching {
            for page in SettingsCategory.allCases { build(page, into: builder) }
        } else {
            build(category, into: builder)
        }
        let sections = builder.makeSections()
        var views = sections
        if sections.isEmpty && builder.isSearching {
            views.insert(NoteLabel("No settings match “\(query)”."), at: 0)
        }
        views.append(NoteLabel("Changes apply immediately. Press Return or leave a field to save text."))
        for view in views {
            column.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        lastBuild = builder
        fields = builder.fields

        scroll.scrollOffset = offset
        guard let (id, _) = editing, let field = fields[id], let window else { return }
        if let editingText { field.stringValue = editingText }
        window.makeFirstResponder(field.field)
        if let editingSelection, let editor = field.field.currentEditor() as? NSTextView,
           NSMaxRange(editingSelection) <= (editor.string as NSString).length
        {
            editor.setSelectedRange(editingSelection)
        }
    }

    private func rebuildHeader() {
        header.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let all = SettingsCategory.allCases
        let index = all.firstIndex(of: category) ?? 0
        navigation.back.isEnabled = index > 0
        navigation.forward.isEnabled = index < all.count - 1
        titleLabel.stringValue = query.isEmpty ? category.title : "Search"
        titleLabel.textColor = theme.fg
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        header.addArrangedSubview(navigation)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(spacer)
        editLink = nil
        if query.isEmpty, let file = category.configurationFile {
            let link = LinkButton("Edit in \(file)") { [weak self] in self?.store.openConfiguration(file) }
            link.theme = theme
            header.addArrangedSubview(link)
            editLink = link
        }
    }

    private func rebuildBanners() {
        banners.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for id in ["application", "configuration"] {
            guard let message = store.errors[id] else { continue }
            let note = NoteLabel(message, error: true)
            let dismiss = IconButton(.close, label: "Dismiss") { [weak self] in self?.store.dismissError(id) }
            banners.addArrangedSubview(hstack([note, dismiss]))
        }
    }

    private func build(_ page: SettingsCategory, into builder: SettingsPageBuilder) {
        switch page {
        case .general: buildGeneral(builder)
        case .appearance: buildAppearance(builder)
        case .terminal: buildTerminal(builder)
        case .keyboard: buildKeyboard(builder)
        case .commands: buildCommands(builder)
        case .browser: buildBrowser(builder)
        case .server: buildServer(builder)
        case .mobile: buildMobile(builder)
        case .ai: buildAI(builder)
        case .backup: buildBackup(builder)
        }
    }

    /// Asks before something that cannot be undone.
    func confirm(_ title: String, _ message: String, _ action: String, destructive: Bool = true, then run: @escaping () -> Void) {
        ConfirmSheet.present(on: window, title: title, message: message, confirm: action, destructive: destructive, theme: theme) { confirmed in
            if confirmed { run() }
        }
    }
}
