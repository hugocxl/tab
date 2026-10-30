import AppKit
import TabClient
import TabCore
import TabProtocol

/// A server-owned conversation. UI tasks never consume the connection's event stream.
@MainActor
final class AgentPaneController: NSObject, PaneContentController, NSTextViewDelegate, NSMenuDelegate {
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
        var resolvedModel: String?
    }
    private var connectionGeneration: UInt64 = 0
    private var needsAuthoritativeSnapshot = false
    private(set) var snapshot: AgentChatSnapshot?
    private(set) var errorMessage: String?
    private(set) var draftAttachments: [AgentDraftAttachment] = []
    private var attachmentTask: Task<Void, Never>?
    private var preparingAttachments = 0
    private var attachmentPreview: NSPopover?
    private lazy var composerCoordinator = AgentComposerCoordinator(surface: surface)
    var loadModelCatalog: ((TabProtocol.AgentChatProvider, Bool) async throws -> [AgentModelDescriptor])?
    private var modelCatalogs: [TabProtocol.AgentChatProvider: [AgentModelDescriptor]] = [:]
    private var modelCatalogTask: Task<Void, Never>?
    private var modelCatalogLoadedAt = Date.distantPast
    private var unavailableModelCatalogs = Set<TabProtocol.AgentChatProvider>()
    private var modelMenuOpen = false

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
        composerCoordinator.loadFiles = { [weak model] in
            guard let model, let project = model.state.paneProject(pane), let client = model.sideClient(for: project) else {
                throw AgentPaneError.offline
            }
            return try await client.searchFiles(project).paths
        }
        composerCoordinator.loadThreads = { [weak model] in
            guard let model, let projectID = model.state.paneProject(pane),
                  let project = model.state.project(projectID), let client = model.sideClient(for: projectID) else {
                throw AgentPaneError.offline
            }
            let sessions = project.tabs.flatMap(\.panes).compactMap { pane -> SessionId? in
                if case .agent(let other, _) = pane.content, other != session { return other }
                return nil
            }
            var threads: [AgentMentionThread] = []
            for other in Set(sessions).prefix(24) {
                try Task.checkCancellation()
                guard let snapshot = try? await client.agentChat(.read(session: other)),
                      let first = snapshot.items.first(where: { $0.kind == .user }), !first.text.isEmpty else { continue }
                let messages = snapshot.items.filter { $0.kind == .user || $0.kind == .assistant }.suffix(30)
                let context = messages.map { "\($0.kind == .user ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n\n")
                threads.append(AgentMentionThread(id: "\(other)", title: String(first.text.prefix(90)),
                                                   context: String(context.suffix(24_000))))
            }
            return threads
        }
        composerCoordinator.loadSkills = { [weak model, weak self] in
            guard let self, let model, let project = model.state.paneProject(pane),
                  let client = model.sideClient(for: project),
                  let provider = TabProtocol.AgentChatProvider(rawValue: self.selection.provider.rawValue) else { throw AgentPaneError.offline }
            return try await client.agentComposerContext(.init(project: project, provider: provider)).skills
        }
        loadModelCatalog = { [weak model] provider, forceRefresh in
            guard let model, let project = model.state.paneProject(pane), let client = model.sideClient(for: project) else {
                throw AgentPaneError.offline
            }
            return try await client.agentModelCatalog(.init(project: project, provider: provider, forceRefresh: forceRefresh)).models
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
        surface.attach.onPress = { [weak self] in self?.chooseAttachments() }
        surface.composer.onAttachFiles = { [weak self] in self?.attachFiles($0) }
        surface.composer.onAttachImage = { [weak self] data, mime in self?.attachImage(data, mimeType: mime) }
        surface.attachmentStrip.onRemove = { [weak self] id in
            guard let self else { return }
            self.draftAttachments.removeAll { $0.id == id }
            self.updateAttachments()
        }
        surface.attachmentStrip.onPreview = { [weak self] in self?.previewAttachment($0) }
        composerCoordinator.onAction = { [weak self] in self?.performComposerAction($0) }
        composerCoordinator.onContext = { [weak self] name, content in
            self?.addAttachments([AgentDraftAttachment(name: name, mimeType: "text/plain", data: Data(content.utf8))])
        }
        composerCoordinator.onError = { [weak self] in self?.showComposerError($0) }
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
        attachmentTask?.cancel()
        attachmentPreview?.close()
        composerCoordinator.invalidate()
        modelCatalogTask?.cancel()
    }

    func connectionChanged() {
        guard !disposed else { return }
        connectionGeneration &+= 1
        modelCatalogTask?.cancel()
        modelCatalogTask = nil
        modelCatalogLoadedAt = .distantPast
        modelCatalogs = [:]
        unavailableModelCatalogs = []
        menuState = nil
        composerCoordinator.invalidate()
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
        refreshModelCatalog()
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
        if composerCoordinator.performTypedAction() { return }
        let text = surface.composer.string
        guard !disposed, commandTask == nil, created, canSend,
              preparingAttachments == 0,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty else { return }
        let attachments = draftAttachments.map { AgentChatAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, data: $0.data) }
        let sentIDs = Set(attachments.map(\.id))
        composerCoordinator.dismiss()
        surface.scrollToEnd()
        run(.send(session: session, text: text, model: selection.model,
                  reasoningEffort: reasoningEffort, provider: selection.provider,
                  attachments: attachments.isEmpty ? nil : attachments)) { [weak self] in
            self?.selectionEdited = false
            self?.draftAttachments.removeAll { sentIDs.contains($0.id) }
            self?.updateAttachments()
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

    private func chooseAttachments() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Attach files"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.attachFiles(panel.urls) }
        }
    }

    func attachFiles(_ urls: [URL]) {
        guard !disposed, !urls.isEmpty else { return }
        prepareAttachments { try await AgentAttachmentImporter.load(urls: urls) }
    }

    private func prepareAttachments(_ load: @escaping @Sendable () async throws -> [AgentDraftAttachment]) {
        let previous = attachmentTask
        preparingAttachments += 1
        updateControls()
        attachmentTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                self.preparingAttachments -= 1
                if self.preparingAttachments == 0 { self.attachmentTask = nil }
                self.updateControls()
            }
            do {
                try Task.checkCancellation()
                guard !self.disposed else { return }
                let loaded = try await load()
                try Task.checkCancellation()
                guard !self.disposed else { return }
                self.addAttachments(loaded)
            } catch is CancellationError { }
            catch { self.showComposerError(error.localizedDescription) }
        }
    }

    private func attachImage(_ data: Data, mimeType: String) {
        guard !disposed else { return }
        prepareAttachments {
            try await Task.detached(priority: .userInitiated) {
                [try AgentAttachmentImporter.fromImage(data: data, mimeType: mimeType)]
            }.value
        }
    }

    private func addAttachments(_ attachments: [AgentDraftAttachment]) {
        let additions = attachments.filter { candidate in
            !draftAttachments.contains { $0.name == candidate.name && $0.data == candidate.data }
        }
        guard draftAttachments.count + additions.count <= AgentChatAttachment.maxCount,
              (draftAttachments + additions).reduce(0, { $0 + $1.data.count }) <= AgentChatAttachment.maxTotalBytes else {
            showComposerError("Attach up to \(AgentChatAttachment.maxCount) files, totaling at most \(AgentChatAttachment.maxTotalBytes / 1024 / 1024) MB.")
            return
        }
        draftAttachments += additions
        errorMessage = nil
        updateAttachments()
    }

    private func updateAttachments() {
        surface.attachmentStrip.update(draftAttachments, theme: surface.theme)
        surface.needsLayout = true
        updateControls()
    }

    private func previewAttachment(_ id: String) {
        guard let attachment = draftAttachments.first(where: { $0.id == id }), view.window != nil else { return }
        let content = NSViewController()
        let background = ThemedBackground(color: { $0.floating })
        background.theme = surface.theme
        background.frame = NSRect(x: 0, y: 0, width: 480, height: 340)
        content.view = background
        let title = makeLabel(attachment.name, font: AppFont.small)
        title.textColor = surface.theme.fg
        title.frame = NSRect(x: 16, y: 12, width: 448, height: 22)
        title.lineBreakMode = .byTruncatingMiddle
        background.addSubview(title)
        if let image = attachment.thumbnail {
            let preview = NSImageView(frame: NSRect(x: 16, y: 44, width: 448, height: 280))
            preview.image = image
            preview.imageScaling = .scaleProportionallyUpOrDown
            preview.setAccessibilityLabel(attachment.name)
            background.addSubview(preview)
            Task { [weak preview] in
                if let image = await AgentAttachmentImporter.previewImage(data: attachment.data) { preview?.image = image }
            }
        } else {
            let scroll = NSScrollView(frame: NSRect(x: 16, y: 44, width: 448, height: 280))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.drawsBackground = false
            text.textColor = surface.theme.fg
            text.font = AppFont.mono(12)
            if let source = String(data: attachment.data, encoding: .utf8) {
                text.string = String(source.prefix(32_000)) + (source.count > 32_000 ? "\n[Preview shortened]" : "")
            } else {
                text.string = "\(attachment.name)\n\(attachment.mimeType)\n\(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))"
            }
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text
            background.addSubview(scroll)
        }
        attachmentPreview?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        attachmentPreview = popover
        popover.show(relativeTo: surface.attachmentStrip.bounds, of: surface.attachmentStrip, preferredEdge: .minY)
    }

    private func showComposerError(_ message: String) {
        errorMessage = message
        updateControls()
    }

    private func performComposerAction(_ action: String) {
        let control: NSControl?
        switch action {
        case "model": control = surface.model
        case "effort": control = surface.effort
        case "access": control = surface.access
        case "attach": chooseAttachments(); return
        case "stop": stop(); return
        case "clear":
            surface.composer.string = ""
            draftAttachments = []
            updateAttachments()
            surface.refreshComposer()
            return
        default: return
        }
        guard let control, control.isEnabled else {
            showComposerError("This setting is unavailable while the agent is working or reconnecting.")
            return
        }
        control.performClick(nil)
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
            preparingAttachments == 0 && (!surface.composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty)
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
        surface.access.symbol = mode == .fullAccess ? "lock.open" : mode == .ask ? "hand.raised" : "shield.lefthalf.filled"
        surface.access.toolTip = mode.tooltip
        surface.contextIndicator.update(usedTokens: snapshot?.contextUsage?.usedTokens,
                                        contextWindow: snapshot?.contextUsage?.contextWindow)
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
        if preparingAttachments > 0 { return "Preparing attachments…" }
        if needsAuthoritativeSnapshot { return "Reconnecting… Your transcript and draft are kept here." }
        if submitting { return "" }
        switch snapshot?.status {
        case .working, .waiting: return ""
        case .closed: return "This conversation has ended. Open a new Agent Tab to continue."
        case .failed: return "Turn failed · Change the model or try again"
        case .idle: return ""
        case nil: return "Connecting…"
        }
    }

    func textDidChange(_ notification: Notification) {
        updateControls()
        composerCoordinator.changed()
    }

    func textViewDidChangeSelection(_ notification: Notification) { composerCoordinator.changed() }

    private var supportedEfforts: [AgentReasoningEffort] {
        if let descriptor = selectedModelDescriptor { return descriptor.reasoningEfforts }
        return reasoningEffort.map { [$0] } ?? []
    }

    private var selectedModelDescriptor: AgentModelDescriptor? {
        descriptor(for: AgentModelSelection(provider: selection.provider, model: effectiveModel))
    }

    private func descriptor(for choice: AgentModelSelection) -> AgentModelDescriptor? {
        guard let model = choice.model else { return nil }
        let models = modelCatalogs[choice.provider] ?? []
        return models.first { $0.id == model } ?? models.first { $0.resolvedModel == model }
    }

    private func modelTitle(_ choice: AgentModelSelection) -> String {
        descriptor(for: choice)?.title ?? choice.title
    }

    private func refreshModelCatalog(force: Bool = false) {
        guard modelCatalogTask == nil, force || Date().timeIntervalSince(modelCatalogLoadedAt) > 60,
              let loadModelCatalog else { return }
        modelCatalogLoadedAt = Date()
        let generation = connectionGeneration
        modelCatalogTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.connectionGeneration { self.modelCatalogTask = nil } }
            for provider in TabProtocol.AgentChatProvider.allCases {
                do {
                    let models = try await loadModelCatalog(provider, force)
                    guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                    self.modelCatalogs[provider] = models
                    self.unavailableModelCatalogs.remove(provider)
                    self.menuState = nil
                    self.updateControls()
                } catch {
                    guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                    self.unavailableModelCatalogs.insert(provider)
                    self.menuState = nil
                    self.updateControls()
                }
            }
        }
    }

    private var effectiveModel: String? {
        selection.model ?? (selection.provider == snapshot?.provider ? snapshot?.resolvedModel : nil)
            ?? modelCatalogs[selection.provider]?.first(where: \.isDefault)?.id
    }

    /// Provider conversations cannot be resumed by a different provider.
    private var canChangeProvider: Bool { snapshot?.providerSession == nil }

    private var canEditSelection: Bool {
        !disposed && commandTask == nil && snapshot != nil &&
            snapshot?.status != .working && snapshot?.status != .waiting && snapshot?.status != .closed
    }

    func selectModel(provider: TabCore.AgentChatProvider, model: String?) {
        // A picker opened while idle can finish during reconnection. Keep that
        // choice as a local draft until an authoritative snapshot arrives.
        guard canEditSelection,
              canChangeProvider || provider == snapshot?.provider else { return }
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        selection = AgentModelSelection(provider: provider, model: trimmed?.isEmpty == false ? trimmed : nil)
        composerCoordinator.invalidate()
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
        } else if item.representedObject as? String == "refresh-models" {
            modelCatalogLoadedAt = .distantPast
            menuState = nil
            refreshModelCatalog(force: true)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === surface.model.menu else { return }
        modelMenuOpen = true
        refreshModelCatalog()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === surface.model.menu else { return }
        modelMenuOpen = false
        // Native selection dispatch follows menuDidClose; keep its represented object alive until then.
        Task { [weak self] in
            await Task.yield()
            self?.menuState = nil
            self?.updateControls()
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
        guard !modelMenuOpen else { return }
        let state = PickerState(selection: selection, effort: reasoningEffort,
                                lockedProvider: canChangeProvider ? nil : snapshot?.provider,
                                resolvedModel: effectiveModel)
        guard menuState != state else { return }
        menuState = state
        let displayedSelection = AgentModelSelection(provider: selection.provider, model: effectiveModel)
        let menu = NSMenu()
        menu.delegate = self
        var menuLogos: [Int: AgentProvider] = [:]
        menu.autoenablesItems = false
        for provider in TabCore.AgentChatProvider.allCases {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let heading = NSMenuItem(title: provider.name, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            var choices = (modelCatalogs[provider] ?? []).map { AgentModelSelection(provider: provider, model: $0.id) }
            let shownModel = descriptor(for: displayedSelection)
            if displayedSelection.provider == provider && displayedSelection.model != nil && shownModel == nil {
                choices.append(displayedSelection)
            }
            if choices.isEmpty {
                let title = unavailableModelCatalogs.contains(provider) ? "Models unavailable" : modelCatalogs[provider] == nil ? "Loading models…" : "No models reported"
                let status = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                status.isEnabled = false
                status.indentationLevel = 1
                menu.addItem(status)
            }
            for choice in choices {
                let item = NSMenuItem(title: modelTitle(choice), action: nil, keyEquivalent: "")
                item.representedObject = choice
                menuLogos[menu.items.count] = provider == .claude ? .claude : .codex
                item.indentationLevel = 1
                let reported = descriptor(for: choice) != nil
                item.isEnabled = reported && (canChangeProvider || provider == snapshot?.provider)
                item.toolTip = !reported ? "Current model is not listed in the provider catalog."
                    : item.isEnabled ? choice.model : "Open a new Agent Tab to use another provider."
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let refreshModels = NSMenuItem(title: "Refresh models…", action: nil, keyEquivalent: "")
        refreshModels.representedObject = "refresh-models"
        menu.addItem(refreshModels)
        surface.model.menu = menu
        surface.model.menuLogos = menuLogos
        surface.model.providerLogo = selection.provider == .claude ? .claude : .codex
        let currentChoice = selectedModelDescriptor.map { AgentModelSelection(provider: selection.provider, model: $0.id) } ?? displayedSelection
        surface.model.select(menu.items.first { ($0.representedObject as? AgentModelSelection) == currentChoice })
        surface.model.displayedTitle = modelTitle(displayedSelection)
        surface.model.symbol = selection.provider == .claude ? "sparkle" : "cpu"
        surface.model.toolTip = "Model · \(selection.provider.name). Changes apply to the next message."

        surface.effort.removeAllItems()
        surface.effort.addItem(withTitle: selectedModelDescriptor?.reasoningEfforts.isEmpty == true ? "Off" : "Auto")
        surface.effort.item(at: 0)?.toolTip = "Use the provider's configured reasoning level"
        for value in supportedEfforts {
            surface.effort.addItem(withTitle: value.title)
            surface.effort.lastItem?.representedObject = value
        }
        if let reasoningEffort {
            surface.effort.select(surface.effort.itemArray.first {
                ($0.representedObject as? AgentReasoningEffort) == reasoningEffort
            })
        } else { surface.effort.selectItem(at: 0) }
        surface.effort.symbol = "brain"
        surface.effort.defaultValueTitle = selectedModelDescriptor?.defaultReasoningEffort?.title
        surface.effort.toolTip = "Reasoning effort for the next message"
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if composerCoordinator.handle(commandSelector) { return true }
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
