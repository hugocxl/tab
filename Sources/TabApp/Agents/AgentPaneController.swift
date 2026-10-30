import AppKit
import TabClient
import TabCore
import TabProtocol

/// A server-owned conversation. UI tasks never consume the connection's event stream.
@MainActor
final class AgentPaneController: NSObject, PaneContentController, NSTextViewDelegate {
    let session: SessionId
    let provider: TabCore.AgentChatProvider
    let project: ProjectId
    let surface = AgentPaneView()
    var view: NSView { surface }
    var title: String { "Agent" }
    var titleDidChange: (() -> Void)?

    private let request: (AgentChatRequest) async throws -> AgentChatSnapshot
    private var refreshTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var refreshPending = false
    private var created = false
    private var disposed = false
    private var selectionEdited = false
    private var submitting = false
    private var stopRequested = false
    private(set) var selection: AgentModelSelection
    private(set) var reasoningEffort: AgentReasoningEffort?
    private var menuState: PickerState?
    private struct PickerState: Equatable {
        var selection: AgentModelSelection
        var effort: AgentReasoningEffort?
        var lockedProvider: TabCore.AgentChatProvider?
    }
    private var connectionGeneration: UInt64 = 0
    private var needsAuthoritativeSnapshot = false
    private(set) var snapshot: AgentChatSnapshot?
    private(set) var errorMessage: String?

    convenience init(context: PaneContext) {
        self.init(context: context) { client, request in try await client.agentChat(request) }
    }

    /// Transport injection exercises catalog remapping without launching a provider process.
    convenience init(context: PaneContext,
                     send: @escaping (ServerAPI, AgentChatRequest) async throws -> AgentChatSnapshot) {
        guard case .agent(let session, let provider) = context.pane.content else {
            preconditionFailure("AgentPaneController requires an agent pane")
        }
        let model = context.model
        let pane = context.pane.id
        self.init(session: session, project: context.project.id, provider: provider) { [weak model] request in
            guard let model, let project = model.state.paneProject(pane),
                  let client = model.sideClient(for: project) else {
                throw AgentPaneError.offline
            }
            let routed: AgentChatRequest
            if case .create(let session, _, let provider) = request {
                routed = .create(session: session, project: project, provider: provider)
            } else {
                routed = request
            }
            return try await send(client, routed)
        }
        surface.theme = model.theme
        surface.themeDidChange()
        surface.onOpenFile = { [weak model] path, line in
            guard let model, let project = model.state.paneProject(pane) else { return }
            model.openEditor(project: project, path: path, line: line)
        }
    }

    /// Request injection keeps failure, reconnect and event races testable without a server.
    init(session: SessionId, project: ProjectId, provider: TabCore.AgentChatProvider,
         request: @escaping (AgentChatRequest) async throws -> AgentChatSnapshot) {
        self.session = session
        self.project = project
        self.provider = provider
        self.selection = AgentModelSelection(provider: provider, model: nil)
        self.request = request
        super.init()
        surface.composer.delegate = self
        surface.model.target = self
        surface.model.action = #selector(modelSelected)
        surface.effort.target = self
        surface.effort.action = #selector(effortSelected)
        surface.access.target = self
        surface.access.action = #selector(accessSelected)
        for mode in AgentAccessMode.allCases {
            surface.access.addItem(withTitle: mode.title)
            surface.access.lastItem?.representedObject = mode
            surface.access.lastItem?.toolTip = mode.tooltip
        }
        surface.send.onPress = { [weak self] in self?.send() }
        surface.stop.onPress = { [weak self] in self?.stop() }
        surface.retry.onPress = { [weak self] in self?.refresh() }
        surface.onApproval = { [weak self] id, allow in self?.approve(id, allow: allow) }
        updateControls()
    }

    func focusContent() { view.window?.makeFirstResponder(surface.composer) }
    func didShow() { refresh() }
    func didHide() {} // Keep the draft, transcript and scroll position when switching projects.

    func willClose() async -> Bool { true }

    /// Called only after every pane in the closing group has approved its close.
    func commitClose() async -> Bool {
        // Don't strand an unused pane when the server is offline or predates Agent Tabs.
        // An in-flight create must finish before close, or it could create an orphan later.
        while !created, let pending = refreshTask { await pending.value }
        guard created else { return true }
        do {
            _ = try await request(.close(session: session))
            return true
        } catch {
            if (error as? ClientError)?.serverCode == .unknownSession ||
                (error as? ErrorReply)?.code == .unknownSession ||
                (error as? ErrorCode) == .unknownSession { return true }
            showError(error)
            return false
        }
    }

    func dispose() {
        disposed = true
        refreshTask?.cancel()
        commandTask?.cancel()
        stopTask?.cancel()
        refreshTask = nil
        commandTask = nil
        stopTask = nil
        submitting = false
        stopRequested = false
    }

    func connectionChanged() {
        guard !disposed else { return }
        connectionGeneration &+= 1
        needsAuthoritativeSnapshot = true
        refreshTask?.cancel()
        commandTask?.cancel()
        stopTask?.cancel()
        refreshTask = nil
        commandTask = nil
        stopTask = nil
        submitting = false
        stopRequested = false
        // Keep the displayed transcript and draft until the new connection returns its
        // authoritative checkpoint, which may predate the previous daemon's last event.
        updateControls()
        refresh()
    }

    func sessionChanged(session: SessionId, revision: UInt64) {
        guard session == self.session,
              needsAuthoritativeSnapshot || revision > (snapshot?.revision ?? 0) else { return }
        refresh()
    }

    /// Collapse bursts to at most one snapshot request per 80ms, including events during reads.
    /// This is a one-shot event debounce, not a polling timer.
    func refresh() {
        guard !disposed else { return }
        refreshPending = true
        guard refreshTask == nil else { return }
        let generation = connectionGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.connectionGeneration { self.refreshTask = nil } }
            while self.refreshPending && !Task.isCancelled && generation == self.connectionGeneration {
                do {
                    try await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled, generation == self.connectionGeneration else { return }
                    self.refreshPending = false
                    let result = try await self.request(self.created
                        ? .read(session: self.session)
                        : .create(session: self.session, project: self.project, provider: self.provider))
                    guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                    self.created = true
                    self.accept(result, generation: generation, authoritative: true)
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                    self.showError(error)
                    // One retry may already have been requested by a reconnect event.
                }
            }
        }
    }

    func send() {
        let text = surface.composer.string
        guard !disposed, commandTask == nil, created, canSend,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        surface.scrollToEnd()
        run(.send(session: session, text: text, model: selection.model,
                  reasoningEffort: reasoningEffort, provider: selection.provider)) { [weak self] in
            self?.selectionEdited = false
            // Don't lose edits typed while the request was in flight, or a failed send.
            guard let self, self.surface.composer.string == text else { return }
            self.surface.composer.string = ""
            self.surface.refreshComposer()
        }
    }

    func approve(_ id: String, allow: Bool) {
        guard !disposed, !needsAuthoritativeSnapshot, commandTask == nil, snapshot?.items.contains(where: {
            $0.id == id && $0.kind == .approval && !$0.isComplete
        }) == true else { return }
        run(.approve(session: session, request: id, allow: allow))
    }

    func stop() {
        guard !disposed, !needsAuthoritativeSnapshot, stopTask == nil,
              submitting || snapshot?.status == .working || snapshot?.status == .waiting else { return }
        guard snapshot?.status == .working || snapshot?.status == .waiting else {
            // Do not interrupt ahead of the send's server acceptance. Revision events
            // expose acceptance even while provider initialization still holds the reply.
            stopRequested = true
            refresh()
            updateControls()
            return
        }
        stopRequested = false
        let generation = connectionGeneration
        stopTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.connectionGeneration {
                    self.stopTask = nil
                    self.updateControls()
                }
            }
            do {
                let result = try await self.request(.interrupt(session: self.session))
                guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                self.accept(result, generation: generation)
            } catch {
                guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                self.showError(error)
            }
        }
        updateControls()
    }

    private func run(_ command: AgentChatRequest, onSuccess: (() -> Void)? = nil) {
        let generation = connectionGeneration
        if case .send = command { submitting = true }
        commandTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.connectionGeneration {
                    self.commandTask = nil
                    self.submitting = false
                    if self.snapshot?.status != .working && self.snapshot?.status != .waiting {
                        self.stopRequested = false
                    }
                    self.updateControls()
                }
            }
            do {
                let result = try await self.request(command)
                guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                if result.status != .failed { onSuccess?() }
                self.accept(result, generation: generation)
            } catch {
                guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                self.showError(error)
            }
        }
        updateControls()
    }

    private func accept(_ result: AgentChatSnapshot, generation: UInt64, authoritative: Bool = false) {
        guard !disposed, generation == connectionGeneration, result.session == session else { return }
        if needsAuthoritativeSnapshot {
            guard authoritative else { return }
            needsAuthoritativeSnapshot = false
        } else {
            guard result.revision >= (snapshot?.revision ?? 0) else { return }
        }
        snapshot = result
        errorMessage = nil
        if !selectionEdited || (result.providerSession != nil && selection.provider != result.provider) {
            selection = AgentModelSelection(provider: result.provider, model: result.model)
            reasoningEffort = result.reasoningEffort
            selectionEdited = false
        }
        surface.render(result)
        updateControls()
        if stopRequested && (result.status == .working || result.status == .waiting) { stop() }
        titleDidChange?()
    }

    private func showError(_ error: Error) {
        errorMessage = "\(error.localizedDescription) Your draft is saved here. Retry to reconnect."
        updateControls()
    }

    private var canSend: Bool {
        guard !needsAuthoritativeSnapshot, let snapshot else { return false }
        return snapshot.status == .idle || snapshot.status == .failed
    }

    private func updateControls() {
        surface.send.isEnabled = !disposed && created && commandTask == nil && canSend &&
            !surface.composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        surface.stop.isEnabled = !disposed && !needsAuthoritativeSnapshot && stopTask == nil && !stopRequested &&
            (submitting || snapshot?.status == .working || snapshot?.status == .waiting)
        let busy = submitting || snapshot?.status == .working || snapshot?.status == .waiting
        surface.send.isHidden = busy
        surface.stop.isHidden = !busy
        surface.model.isEnabled = canEditSelection && !needsAuthoritativeSnapshot
        surface.effort.isEnabled = surface.model.isEnabled && !supportedEfforts.isEmpty
        surface.access.isEnabled = !disposed && created && !needsAuthoritativeSnapshot && commandTask == nil && snapshot?.status != .closed
        let mode = snapshot?.accessMode ?? .standard
        surface.access.select(surface.access.itemArray.first { ($0.representedObject as? AgentAccessMode) == mode })
        surface.access.toolTip = mode.tooltip
        surface.setActivity(status: snapshot?.status ?? .idle, submitting: submitting)
        updateSelectionMenus()
        surface.setApprovalsEnabled(commandTask == nil && !disposed && !needsAuthoritativeSnapshot)
        surface.feedback.stringValue = errorMessage ?? statusText
        surface.feedback.toolTip = surface.feedback.stringValue
        surface.feedback.setAccessibilityValue(surface.feedback.stringValue)
        surface.retry.isHidden = errorMessage == nil
        surface.refreshComposer()
        surface.needsLayout = true
    }

    private var statusText: String {
        if needsAuthoritativeSnapshot { return "Reconnecting… Your transcript and draft are kept here." }
        if submitting { return "" }
        switch snapshot?.status {
        case .working, .waiting: return ""
        case .closed: return "This conversation has ended. Open a new Agent Tab to continue."
        case .failed: return "Turn failed · Change the model or try again"
        case .idle: return "Return to send · Shift-Return for a new line"
        case nil: return "Connecting…"
        }
    }

    func textDidChange(_ notification: Notification) { updateControls() }

    private var supportedEfforts: [AgentReasoningEffort] {
        AgentReasoningEffort.supported(provider: selection.provider, model: selection.model)
    }

    /// Provider conversations cannot be resumed by a different provider.
    private var canChangeProvider: Bool { snapshot?.providerSession == nil }

    private var canEditSelection: Bool {
        !disposed && commandTask == nil && snapshot != nil &&
            snapshot?.status != .working && snapshot?.status != .waiting && snapshot?.status != .closed
    }

    func selectModel(provider: TabCore.AgentChatProvider, model: String?) {
        // A custom-model sheet opened while idle can finish during reconnection.
        // Keep that choice as a local draft until an authoritative snapshot arrives.
        guard canEditSelection,
              canChangeProvider || provider == snapshot?.provider else { return }
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        selection = AgentModelSelection(provider: provider, model: trimmed?.isEmpty == false ? trimmed : nil)
        if let effort = reasoningEffort, !supportedEfforts.contains(effort) { reasoningEffort = nil }
        selectionEdited = true
        updateControls()
    }

    func selectEffort(_ effort: AgentReasoningEffort?) {
        guard surface.effort.isEnabled else { return }
        if let effort, !supportedEfforts.contains(effort) { return }
        reasoningEffort = effort
        selectionEdited = true
        updateControls()
    }

    @objc private func modelSelected() {
        guard let item = surface.model.selectedItem else { return }
        if let value = item.representedObject as? AgentModelSelection {
            selectModel(provider: value.provider, model: value.model)
        } else if let provider = item.representedObject as? TabCore.AgentChatProvider {
            showCustomModel(for: provider)
        }
    }

    @objc private func effortSelected() {
        selectEffort(surface.effort.selectedItem?.representedObject as? AgentReasoningEffort)
    }

    func selectAccess(_ mode: AgentAccessMode) {
        guard surface.access.isEnabled else { return }
        run(.setAccess(session: session, mode: mode))
    }

    @objc private func accessSelected() {
        guard let mode = surface.access.selectedItem?.representedObject as? AgentAccessMode else { return }
        selectAccess(mode)
    }

    private func updateSelectionMenus() {
        let state = PickerState(selection: selection, effort: reasoningEffort,
                                lockedProvider: canChangeProvider ? nil : snapshot?.provider)
        guard menuState != state else { return }
        menuState = state
        let menu = NSMenu()
        menu.autoenablesItems = false
        for provider in TabCore.AgentChatProvider.allCases {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let heading = NSMenuItem(title: provider.name, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            var choices = [AgentModelSelection(provider: provider, model: nil)]
            choices += AgentModelSelection.presets.map(\.selection).filter { $0.provider == provider }
            if selection.provider == provider && !choices.contains(selection) { choices.append(selection) }
            for choice in choices {
                let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
                item.representedObject = choice
                item.indentationLevel = 1
                item.isEnabled = canChangeProvider || provider == snapshot?.provider
                item.toolTip = item.isEnabled ? choice.model : "Open a new Agent Tab to use another provider."
                menu.addItem(item)
            }
            let custom = NSMenuItem(title: "Custom model…", action: nil, keyEquivalent: "")
            custom.representedObject = provider
            custom.indentationLevel = 1
            custom.isEnabled = canChangeProvider || provider == snapshot?.provider
            menu.addItem(custom)
        }
        surface.model.menu = menu
        surface.model.select(menu.items.first { ($0.representedObject as? AgentModelSelection) == selection })
        surface.model.toolTip = "Model · \(selection.provider.name). Changes apply to the next message."

        surface.effort.removeAllItems()
        surface.effort.addItem(withTitle: supportedEfforts.isEmpty ? "No effort setting" : "Default effort")
        for value in supportedEfforts {
            surface.effort.addItem(withTitle: value.title)
            surface.effort.lastItem?.representedObject = value
        }
        if let reasoningEffort {
            surface.effort.select(surface.effort.itemArray.first {
                ($0.representedObject as? AgentReasoningEffort) == reasoningEffort
            })
        } else { surface.effort.selectItem(at: 0) }
        surface.effort.toolTip = "Reasoning effort for the next message"
    }

    private func showCustomModel(for provider: TabCore.AgentChatProvider) {
        menuState = nil
        updateSelectionMenus()
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Custom \(provider.name) model"
        alert.informativeText = "Enter a model ID supported by your provider account."
        let field = NSTextField(string: selection.provider == provider ? selection.model ?? "" : "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.placeholderString = provider == .claude ? "claude-opus-5-5" : "gpt-6.1-sol"
        alert.accessoryView = field
        alert.addButton(withTitle: "Use Model")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.selectModel(provider: provider, model: field.stringValue)
        }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        guard !textView.hasMarkedText() else { return false }
        if NSEvent.modifierFlags.contains(.shift) { return false }
        send()
        return true
    }
}

private enum AgentPaneError: LocalizedError {
    case offline
    var errorDescription: String? { "The project server is offline." }
}
