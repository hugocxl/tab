import AppKit
import TabCore
import TabProtocol

/// A small popover with one text field, for renaming a project or naming a
/// workspace: Return saves, Escape cancels, errors show under the field.
@MainActor
final class TextPrompt: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let field: InsetTextField
    private let error = makeLabel("", font: AppFont.footnote)
    private let submit: (String) -> String?
    private static var current: TextPrompt?

    /// Shows the prompt near `anchor` (or the window's top center). `submit`
    /// returns an error message, or `nil` when the value was taken.
    @discardableResult
    static func show(title: String, value: String, confirm: String, anchor: NSView?, in window: NSWindow?,
                     submit: @escaping (String) -> String?) -> TextPrompt? {
        guard let target = anchor ?? window?.contentView else { return nil }
        let prompt = TextPrompt(title: title, value: value, confirm: confirm, submit: submit)
        current = prompt
        let rect = anchor == nil ? NSRect(x: target.bounds.midX - 1, y: target.isFlipped ? 60 : target.bounds.height - 60, width: 2, height: 2)
            : target.bounds
        prompt.popover.show(relativeTo: rect, of: target, preferredEdge: .maxY)
        prompt.popover.contentViewController?.view.window?.makeFirstResponder(prompt.field.field)
        prompt.field.field.currentEditor()?.selectAll(nil)
        return prompt
    }

    private init(title: String, value: String, confirm: String, submit: @escaping (String) -> String?) {
        field = InsetTextField(value: value, label: title, width: 288)
        self.submit = submit
        super.init()
        let heading = makeLabel(title, font: AppFont.header)
        error.textColor = AppTheme.shared.danger
        error.isHidden = true
        let cancel = PillButton("Cancel") { [weak self] in self?.popover.close() }
        let save = PillButton(confirm, style: .primary) { [weak self] in self?.commit() }
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.spacing = 8
        let stack = NSStackView(views: [heading, field, error, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        buttons.widthAnchor.constraint(equalTo: field.widthAnchor).isActive = true
        let background = ThemedBackground(color: { $0.raised })
        background.addSubview(stack)
        stack.pinEdges(to: background)
        let controller = NSViewController()
        controller.view = background
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.appearance = AppTheme.shared.nsAppearance
        popover.delegate = self
        field.field.target = self
        field.field.action = #selector(commitAction)
    }

    @objc private func commitAction() { commit() }

    private func commit() {
        if let message = submit(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            error.stringValue = message
            error.isHidden = false
            return
        }
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }
}

/// New Worktree…: a name, a new branch from a base or an existing branch,
/// where its folder goes, and the setup hooks to run, as a sheet.
@MainActor
final class NewWorktreeDialog: NSObject {
    private unowned let model: AppModel
    private let parent: ProjectId
    private let panel: NSPanel
    private let name = InsetTextField(value: "", placeholder: "feature-name", label: "Name", width: 320)
    private let mode = SegmentedPill(["New branch", "Existing branch"], selected: 0)
    private let branch = InsetTextField(value: "", placeholder: "Branch name", label: "Branch name", width: 320)
    private let base = PopUp(items: [], selected: "", label: "Base branch")
    private let existing = PopUp(items: [], selected: "", label: "Existing branch")
    private let location = SegmentedPill(["Default", "Template", "Folder"], selected: 0)
    private let path = InsetTextField(value: "", placeholder: "", label: "Location", width: 320)
    private let chooseFolder = PillButton("Choose Folder…")
    private let locationNote = makeLabel("", font: AppFont.footnote)
    private let hooksStack = NSStackView()
    private let error = makeLabel("", font: AppFont.footnote)
    private let create = PillButton("Create", style: .primary)
    private var hooks: [(WorktreeHook, Switch)] = []
    private var branchEdited = false
    private static var open: NewWorktreeDialog?

    static func present(model: AppModel, parent: ProjectId, on window: NSWindow?) {
        guard let window, open == nil else { return }
        let dialog = NewWorktreeDialog(model: model, parent: parent)
        open = dialog
        window.beginSheet(dialog.panel) { _ in open = nil }
        dialog.load()
    }

    private init(model: AppModel, parent: ProjectId) {
        self.model = model
        self.parent = parent
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        panel.appearance = AppTheme.shared.nsAppearance
        let projectName = model.state.project(parent).map { model.title(of: $0) } ?? ""
        let title = makeLabel("New Worktree in \(projectName)", font: AppFont.title)
        let cancel = PillButton("Cancel") { [weak self] in self?.close() }
        create.action = { [weak self] in self?.submit() }
        chooseFolder.action = { [weak self] in self?.pickFolder() }
        name.onChange = { [weak self] text in
            guard let self, !self.branchEdited else { return }
            self.branch.stringValue = sanitizedComponent(text, fallback: "")
        }
        branch.onChange = { [weak self] _ in self?.branchEdited = true }
        mode.onChange = { [weak self] _ in self?.updateVisibility() }
        location.onChange = { [weak self] _ in self?.updateVisibility() }
        let saved = model.settings.worktrees.projects[parent] ?? WorktreeLocation()
        if !saved.pathTemplate.isEmpty {
            location.select(1)
            path.stringValue = saved.pathTemplate
        } else if !saved.parentPath.isEmpty {
            location.select(2)
            path.stringValue = saved.parentPath
        }
        error.textColor = AppTheme.shared.danger
        error.isHidden = true
        locationNote.textColor = AppTheme.shared.fgMuted
        hooksStack.orientation = .vertical
        hooksStack.alignment = .leading
        hooksStack.spacing = 6
        let buttons = NSStackView(views: [NSView(), cancel, create])
        buttons.spacing = 8
        let rows: [NSView] = [
            title, row("Name", name), row("Branch", mode), row("", branch), row("Base", base), row("", existing),
            row("Location", location), row("", path), row("", chooseFolder), row("", locationNote), hooksStack, error, buttons,
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        let background = ThemedBackground(color: { $0.bg })
        background.addSubview(stack)
        stack.pinEdges(to: background)
        panel.contentView = background
        panel.initialFirstResponder = name.field
        updateVisibility()
    }

    private func row(_ label: String, _ control: NSView) -> NSView {
        let text = makeLabel(label, font: AppFont.body, color: AppTheme.shared.fgMuted)
        text.alignment = .right
        text.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let stack = NSStackView(views: [text, control])
        stack.spacing = 12
        return stack
    }

    private func load() {
        Task {
            if let side = model.sideClient(for: parent), let branches = try? await side.gitBranches(parent) {
                let items = branches.map { PopUp.Item(id: $0.name, title: $0.name) }
                let defaultBranch = branches.first(where: \.isDefault)?.name ?? branches.first(where: \.current)?.name ?? ""
                base.setItems(items, selected: defaultBranch)
                let free = branches.filter { !$0.checkedOut }.map { PopUp.Item(id: $0.name, title: $0.name) }
                existing.setItems(free, selected: free.first?.id ?? "")
            }
            switch await model.worktreeHooks(parent: parent, teardown: false) {
            case .success(let list):
                hooks = list.map { hook in
                    let label = "\(hook.project ? "Project" : "Per-machine"): \(hook.name ?? hook.command)"
                    let toggle = Switch(isOn: false, label: label)
                    let text = makeLabel(label, font: AppFont.small, color: AppTheme.shared.fgMuted)
                    text.toolTip = hook.command
                    let line = NSStackView(views: [toggle, text])
                    line.spacing = 8
                    hooksStack.addArrangedSubview(line)
                    return (hook, toggle)
                }
                if !list.isEmpty {
                    hooksStack.insertArrangedSubview(makeLabel("Setup commands (review before enabling)", font: AppFont.footnoteMedium,
                                                               color: AppTheme.shared.fgMuted), at: 0)
                }
            case .failure(let failure):
                hooksStack.addArrangedSubview(makeLabel("Setup hooks could not be loaded: \(failure.message)", font: AppFont.footnote,
                                                        color: AppTheme.shared.warning))
            }
        }
    }

    private func updateVisibility() {
        let existingBranch = mode.selectedIndex == 1
        branch.superview?.isHidden = existingBranch
        base.superview?.isHidden = existingBranch
        existing.superview?.isHidden = !existingBranch
        let choice = location.selectedIndex
        path.superview?.isHidden = choice == 0
        let local = model.state.projectServer(parent)?.isLocal ?? true
        chooseFolder.superview?.isHidden = choice != 2 || !local
        path.field.placeholderString = choice == 1 ? WorktreeLocation.suggestedTemplate : "~/worktrees"
        let defaults = model.settings.worktrees.defaultLocation
        if choice == 0 {
            locationNote.stringValue = !defaults.pathTemplate.isEmpty ? "Global template: \(defaults.pathTemplate)"
                : !defaults.parentPath.isEmpty ? "Global folder: \(defaults.parentPath)" : TabDirs.defaultWorktreeFolder
        } else {
            locationNote.stringValue = ""
        }
        locationNote.superview?.isHidden = choice != 0
    }

    private func pickFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        guard open.runModal() == .OK, let url = open.url else { return }
        path.stringValue = url.path
    }

    private func fail(_ message: String) {
        error.stringValue = message
        error.isHidden = false
        create.isEnabled = true
        create.title = "Create"
    }

    private func submit() {
        let worktreeName = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !worktreeName.isEmpty else { return fail("Enter a name.") }
        let useExisting = mode.selectedIndex == 1
        let branchName = useExisting ? existing.selectedId : branch.stringValue.trimmingCharacters(in: .whitespaces)
        guard !branchName.isEmpty else { return fail(useExisting ? "Choose a branch." : "Enter a branch name.") }
        let text = path.stringValue.trimmingCharacters(in: .whitespaces)
        let choice = location.selectedIndex
        if choice != 0 && text.isEmpty { return fail(choice == 1 ? "Path template is required." : "Folder is required.") }
        let chosen = WorktreeLocation(pathTemplate: choice == 1 ? text : "", parentPath: choice == 2 ? text : "")
        let directory: String
        do {
            directory = try model.worktreeDirectory(parent: parent, location: chosen, name: worktreeName, branch: branchName)
        } catch {
            return fail(error.message)
        }
        model.saveWorktreeLocation(chosen, for: parent)
        let approved = hooks.filter { $0.1.isOn }.map(\.0)
        create.isEnabled = false
        create.title = "Creating…"
        let baseBranch = useExisting ? nil : (base.selectedId.isEmpty ? nil : base.selectedId)
        Task {
            if let message = await model.createWorktree(parent: parent, name: worktreeName, branch: branchName, base: baseBranch,
                                                        directory: directory, hooks: approved.isEmpty ? nil : approved) {
                fail(message)
            } else {
                close()
            }
        }
    }

    private func close() {
        panel.sheetParent?.endSheet(panel)
    }
}
