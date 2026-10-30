import AppKit
import TabCore

/// Answers the palette's pages from the app's data.
@MainActor
protocol PaletteDataSource: AnyObject {
    func spec(for page: PalettePage) -> PageSpec
    func content(for page: PalettePage, query: String) -> PageContent
    /// The page was shown; start loading what it lists.
    func opened(_ page: PalettePage)
    func toggled(_ page: PalettePage, accessory: String, active: Bool)
    /// Tab on a page that completes: the new query, if any.
    func complete(_ page: PalettePage, query: String, item: String?) -> String?
    /// A ⌘K action or the secondary confirm ran on a row.
    func perform(_ page: PalettePage, item: String, action: String)
    /// A page's Run target ran from the root page; remember it as recent.
    func ran(_ page: PalettePage, item: String)
    func closed()
}

/// The command palette: a stack of pages over a clear click-catcher, in a
/// panel 740pt wide, at most 480pt tall and 72pt plus a fifth of the window
/// below its top.
@MainActor
final class PaletteController: NSObject, NSTextFieldDelegate {
    weak var source: PaletteDataSource?
    private weak var parent: NSWindow?
    private var root: PaletteRootView?
    private weak var previousResponder: NSResponder?
    private var stack: [PageState] = []
    private var panel: PalettePanelView?
    private var actions: ActionsState?

    /// The key that opens a row's actions, from the keymap.
    var actionsChord: KeyChord? = try? KeyChord("cmd-k")

    var isOpen: Bool { root != nil }
    var page: PalettePage? { stack.last?.spec.page }
    var query: String { stack.last?.query ?? "" }
    var depth: Int { stack.count }

    /// The page shown, for tests.
    var current: PageState? { stack.last }

    init(parent: NSWindow?) {
        self.parent = parent
    }

    // MARK: Opening

    /// Opens on `page` over the root page so Escape returns there, or closes
    /// the palette when it already shows `page`.
    func toggle(_ page: PalettePage) {
        if isOpen, self.page == page {
            close()
            return
        }
        open(page)
    }

    func open(_ page: PalettePage) {
        stack = []
        actions = nil
        pushState(.root)
        if page != .root { pushState(page) }
        if root == nil { showWindow() }
        reload(resetScroll: true)
    }

    /// Pushes `page`, optionally with a query typed in.
    func push(_ page: PalettePage, query: String? = nil) {
        guard isOpen else {
            open(page)
            if let query { setQuery(query) }
            return
        }
        actions = nil
        pushState(page)
        if let query { stack[stack.count - 1].query = query }
        reload(resetScroll: true)
    }

    private func pushState(_ page: PalettePage) {
        guard let source else { return }
        var state = PageState(spec: source.spec(for: page))
        state.setContent(source.content(for: page, query: ""))
        stack.append(state)
        source.opened(page)
        stack[stack.count - 1].setContent(source.content(for: page, query: ""))
    }

    /// Goes back a page; false on the root page.
    @discardableResult
    func pop() -> Bool {
        guard stack.count > 1 else { return false }
        actions = nil
        stack.removeLast()
        refresh()
        reload(resetScroll: false)
        return true
    }

    func close() {
        guard let root else { return }
        actions = nil
        root.removeFromSuperview()
        self.root = nil
        panel = nil
        stack = []
        source?.closed()
        parent?.makeFirstResponder(previousResponder)
        previousResponder = nil
    }

    /// Asks the source again for the current page's content.
    func refresh() {
        guard let source, let page else { return }
        let index = stack.count - 1
        stack[index].spec = specKeepingToggles(source.spec(for: page), stack[index].spec)
        stack[index].setContent(source.content(for: page, query: stack[index].query))
        reload(resetScroll: false)
    }

    /// Refreshes only when `page` shows.
    func refresh(_ page: PalettePage) {
        if self.page == page { refresh() }
    }

    private func specKeepingToggles(_ fresh: PageSpec, _ old: PageSpec) -> PageSpec {
        var spec = fresh
        spec.accessories = fresh.accessories.map { accessory in
            guard case let .toggle(id, label, _) = accessory,
                  let previous = old.accessories.first(where: { if case .toggle(id, _, _) = $0 { return true }; return false }),
                  case let .toggle(_, _, active) = previous else { return accessory }
            return .toggle(id: id, label: label, active: active)
        }
        return spec
    }

    func setQuery(_ query: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].queryChanged(query)
        panel?.header.field.stringValue = query
        refresh()
    }

    // MARK: Window

    private func showWindow() {
        guard let parent, let content = parent.contentView else { return }
        previousResponder = parent.firstResponder
        let root = PaletteRootView()
        root.onDismiss = { [weak self] in self?.close() }
        let panel = PalettePanelView()
        panel.header.field.delegate = self
        panel.header.back.action = { [weak self] in self?.pop() }
        panel.footer.primary.action = { [weak self] in self?.confirm() }
        panel.footer.actions.action = { [weak self] in self?.toggleActions() }
        panel.list.onClick = { [weak self] row in self?.click(row) }
        root.addSubview(panel)
        root.panel = panel
        root.frame = content.bounds
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        content.addSubview(root)
        parent.makeFirstResponder(panel.header.field)
        self.root = root
        self.panel = panel
    }

    /// Follows the main window when it moves or resizes.
    func parentFrameChanged() {
        layoutPanel()
    }

    private func reload(resetScroll: Bool) {
        guard let panel, let state = stack.last else { return }
        panel.header.configure(spec: state.spec, query: state.query, pushed: stack.count > 1, controller: self)
        panel.list.state = state
        panel.list.reloadRows()
        panel.message = state.showsRows ? nil : state.message
        let selected = state.selectedItem.flatMap { $0.disabled ? nil : $0 }
        panel.footer.configure(primary: selected?.primaryTitle, actionsEnabled: selected != nil)
        if let row = state.selectedRow { panel.list.reveal(row, top: resetScroll) }
        panel.actionsPanel = actions.map { state in
            let view = ActionsPanelView(state: state)
            view.controller = self
            return view
        }
        layoutPanel()
    }

    private func layoutPanel() {
        guard let panel, let root, let state = stack.last else { return }
        let top = PaletteLayout.offset(windowHeight: root.bounds.height)
        let height = min(state.height, max(root.bounds.height - top - 8, 120))
        let width = min(PaletteLayout.width, root.bounds.width - 16)
        panel.frame = NSRect(x: ((root.bounds.width - width) / 2).rounded(), y: top, width: width, height: height)
        panel.needsLayout = true
    }

    // MARK: Text field

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, !stack.isEmpty else { return }
        stack[stack.count - 1].queryChanged(field.stringValue)
        actions = nil
        refresh()
        if let row = stack.last?.selectedRow { panel?.list.reveal(row, top: true) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): confirm()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        case #selector(NSResponder.insertTab(_:)): tab()
        case #selector(NSResponder.insertBacktab(_:)): move(-1)
        case #selector(NSResponder.deleteBackward(_:)):
            guard actions == nil, stack.count > 1, query.isEmpty else { return false }
            pop()
        default: return false
        }
        return true
    }

    /// Keys with Command or Control that the field doesn't see as commands.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let chord = KeyChord(event: event) else { return false }
        switch chord.rawValue {
        case "cmd-enter", "alt-enter":
            secondaryConfirm()
        case "ctrl-n":
            move(1)
        case "ctrl-p":
            move(-1)
        case "alt-left":
            actions = nil
            pop()
        case "up" where actions != nil:
            moveAction(-1)
        case "down" where actions != nil:
            moveAction(1)
        case "enter" where actions != nil:
            confirmAction()
        case "escape" where actions != nil:
            actions = nil
            reload(resetScroll: false)
        default:
            guard chord == actionsChord else { return false }
            toggleActions()
        }
        return true
    }

    // MARK: Selection and running

    private func move(_ delta: Int) {
        if actions != nil {
            moveAction(delta)
            return
        }
        guard !stack.isEmpty, stack[stack.count - 1].moveSelection(delta) else { return }
        reload(resetScroll: false)
    }

    private func click(_ row: Int) {
        guard let state = stack.last, state.rows.indices.contains(row), let item = state.rowItem(state.rows[row]),
              !item.disabled else { return }
        stack[stack.count - 1].select(item.id)
        reload(resetScroll: false)
        run(item)
    }

    func confirm() {
        if actions != nil {
            confirmAction()
            return
        }
        guard let item = stack.last?.selectedItem, !item.disabled else { return }
        run(item)
    }

    private func run(_ item: PaletteItem) {
        guard let page else { return }
        switch item.target {
        case .run(let handler):
            if stack.count == 1 { source?.ran(page, item: item.id) }
            close()
            handler()
        case .apply(let handler):
            handler()
            refresh()
        case .page(let target):
            if stack.count == 1 { source?.ran(page, item: item.id) }
            push(target)
        }
    }

    private func secondaryConfirm() {
        guard actions == nil, let page, let item = stack.last?.selectedItem, !item.disabled else { return }
        guard item.actions.count > 1 else {
            run(item)
            return
        }
        source?.perform(page, item: item.id, action: item.actions[1].id)
        refresh()
    }

    private func tab() {
        guard let state = stack.last else { return }
        guard actions == nil, state.spec.completesOnTab else {
            move(1)
            return
        }
        if let completed = source?.complete(state.spec.page, query: state.query, item: state.selected) {
            setQuery(completed)
            if let editor = panel?.header.field.currentEditor() {
                editor.selectedRange = NSRange(location: (completed as NSString).length, length: 0)
            }
        }
    }

    func dismiss() {
        if actions != nil {
            actions = nil
            reload(resetScroll: false)
            return
        }
        if pop() { return }
        close()
    }

    func toggleAccessory(_ id: String) {
        guard let page, !stack.isEmpty else { return }
        var active = false
        stack[stack.count - 1].spec.accessories = stack[stack.count - 1].spec.accessories.map { accessory in
            guard case let .toggle(candidate, label, current) = accessory, candidate == id else { return accessory }
            active = !current
            return .toggle(id: candidate, label: label, active: !current)
        }
        source?.toggled(page, accessory: id, active: active)
        refresh()
    }

    // MARK: Actions panel

    private func toggleActions() {
        if actions != nil {
            actions = nil
        } else if let item = stack.last?.selectedItem, !item.disabled {
            let entries = item.actions.isEmpty ? [PaletteItemAction("", item.primaryTitle)] : item.actions
            actions = ActionsState(item: item.id, actions: entries)
        }
        reload(resetScroll: false)
    }

    private func moveAction(_ delta: Int) {
        guard var state = actions, !state.actions.isEmpty else { return }
        state.selected = ((state.selected + delta) % state.actions.count + state.actions.count) % state.actions.count
        state.armed = false
        actions = state
        reload(resetScroll: false)
    }

    private func confirmAction() {
        guard var state = actions, state.actions.indices.contains(state.selected), let page else { return }
        let action = state.actions[state.selected]
        if action.destructive && !state.armed {
            state.armed = true
            actions = state
            reload(resetScroll: false)
            return
        }
        if !action.keepOpen { actions = nil }
        if action.id.isEmpty, let item = stack.last?.item(state.item) {
            run(item)
            return
        }
        source?.perform(page, item: state.item, action: action.id)
        if isOpen { refresh() }
    }

    func clickAction(_ index: Int) {
        guard var state = actions, state.actions.indices.contains(index) else { return }
        state.selected = index
        actions = state
        confirmAction()
    }
}

/// The open ⌘K panel: the row's actions and which one is chosen.
struct ActionsState {
    var item: String
    var actions: [PaletteItemAction]
    var selected = 0
    /// A destructive action waits for a second Return.
    var armed = false
}

/// The clear layer over the window; a click outside the panel closes the
/// palette.
final class PaletteRootView: NSView {
    var onDismiss: (() -> Void)?
    weak var panel: PalettePanelView?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let panel, panel.frame.contains(point) { return }
        onDismiss?()
    }
}
