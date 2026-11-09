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
    var title: String {
        snapshot?.items.first(where: { $0.kind == .user })?.text
            .split(whereSeparator: \.isNewline).first.map { String($0.prefix(160)) } ?? "Agent"
    }
    /// The provider's logo, as a terminal running the same agent shows it.
    var icon: NSImage? {
        AgentLogo.image(for: selection.provider == .claude ? .claude : .codex, lightBackground: AppTheme.shared.palette.isLight)
    }
    /// Keeps the pane's saved title in step with the conversation, for the
    /// tab title, sidebar filter and palette.
    var onTitleChange: ((String) -> Void)?
    private let voice = AgentVoice()
    private var draftStore: AgentDraftStore?
    private var draftRestoreTask: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private var draftRevision: UInt64 = 0
    private var restoringDraft = false
    private var lastSubmission: AgentPrompt?
    private var questionDrafts: [String: [String: [String]]] = [:]
    private var initialPreferences: AgentComposerPreferences?
    private var savePreferences: ((AgentComposerPreferences?) -> Void)?
    private func persistSelection(access: AgentAccessMode? = nil) {
        savePreferences?(.init(provider: selection.provider, model: selection.model,
                               effort: reasoningEffort, access: access ?? snapshot?.accessMode))
    }
    var confirmClose: (() async -> Bool)?
    var onNewConversation: (() -> Void)?
    /// Conversations Claude Code and Codex saved for this folder outside Tab.
    var loadHistory: (() async throws -> [AgentHistoryEntry])?
    /// Continues one of them as the conversation with the given ID.
    var importHistory: ((AgentHistoryEntry, SessionId) async throws -> AgentChatSnapshot)?
    /// Shows a conversation this pane doesn't hold, beside it.
    var showConversation: ((AgentChatSnapshot) -> Void)?
    private var historyTask: Task<Void, Never>?
    var titleDidChange: (() -> Void)?

    private let request: (AgentChatRequest) async throws -> AgentChatSnapshot
    private let attachmentCache = AgentAttachmentCache()
    private var filePreview: AgentFilePreviewWindow?
    private var mediaPreview: AgentMediaPreviewWindow?
    private var toolDiffWindows: [String: (activity: AgentToolActivity, window: AgentCheckpointDiffWindow)] = [:]
    private var checkpointWindows: [String: AgentCheckpointDiffWindow] = [:]
    var loadCheckpoint: AgentCheckpointDiffWindow.Fetch?
    private var refreshTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var approvalToken: UUID?
    private var approvalInFlight: Bool { approvalToken != nil }
    private var stopTask: Task<Void, Never>?
    private var refreshPending = false
    private var created = false
    private var disposed = false
    private var selectionEdited = false
    private var submitting = false
    private var stopRequested = false
    private(set) var selection: AgentModelSelection {
        didSet { if selection.provider != oldValue.provider { onProviderChange?() } }
    }
    /// Tells the sidebar, whose card shows the provider's logo, that the
    /// composer switched providers.
    var onProviderChange: (() -> Void)?
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
    private var authoritativeProject: ProjectId?
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

    @MainActor
    private final class ProjectRoute {
        var project: ProjectId?
    }

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
        let route = ProjectRoute()
        self.init(session: session, project: context.project.id, provider: provider) { [weak model] request in
            guard let model, let project = route.project ?? model.state.paneProject(pane),
                  let client = model.sideClient(for: project) else {
                throw AgentPaneError.offline
            }
            let routed: AgentChatRequest
            if case .create(let session, _, let provider) = request {
                routed = .create(session: session, project: project, provider: provider)
            } else {
                routed = request
            }
            let result = try await send(client, routed)
            guard result.session == session, result.project == project else {
                throw ModelError("The conversation reply does not match its owning session and project.")
            }
            route.project = project
            return result
        }
        confirmClose = { [weak model] in
            guard let model, model.settings.window.confirmRunningProcess else { return true }
            return await model.presenter?.confirm(
                title: "Close this agent pane?",
                message: "Closing this pane stops its current work and cancels any queued prompts.",
                confirm: "Close",
                destructive: true
            ) ?? true
        }
        configureDraftStore(model.dirs.root.appendingPathComponent("agent-drafts/" + pane.description + ".json"))
        onProviderChange = { [weak model] in model?.notify(.activity) }
        restorePreferences(defaults: model.state.agentComposerDefaults, draft: model.state.agentComposerDrafts[pane]) { [weak model] preferences in
            model?.edit { $0.setAgentComposerDraft(preferences, for: pane) }
        }
        let owningProject: () -> ProjectId? = { [weak self, weak model] in
            self?.authoritativeProject ?? route.project ?? model?.state.paneProject(pane)
        }
        onTitleChange = { [weak model] title in
            guard let model, let current = model.state.pane(pane), current.title != title else { return }
            model.edit { try $0.setPaneTitle(pane, title) }
        }
        onNewConversation = { [weak model] in
            guard let model, let project = owningProject() else { return }
            model.newAgent(in: project)
        }
        loadHistory = { [weak model] in
            guard let model, let project = owningProject(), let client = model.sideClient(for: project) else {
                throw AgentPaneError.offline
            }
            return try await client.agentHistory(.init(project: project)).entries
        }
        importHistory = { [weak model] entry, target in
            guard let model, let project = owningProject(), let client = model.sideClient(for: project) else {
                throw AgentPaneError.offline
            }
            return try await client.importAgentHistory(.init(session: target, project: project, provider: entry.provider,
                                                             providerSession: entry.providerSession))
        }
        showConversation = { [weak model] snapshot in
            model?.show(AppPane(kind: .agent, session: snapshot.session, project: snapshot.project,
                                provider: snapshot.provider, beside: session, placement: .pane))
        }
        surface.workspaceRoot = context.project.directory.rawValue
        AgentConversationProjectActions.install(surface: surface, model: model, pane: pane, session: session)
        loadCheckpoint = { [weak model] request in
            guard let model, let project = owningProject(), let client = model.sideClient(for: project) else {
                throw AgentPaneError.offline
            }
            return try await client.agentCheckpoint(request)
        }
        attachmentCache.fetch = { [weak model] item, attachment in
            guard let model, let project = owningProject(), let client = model.sideClient(for: project) else { throw AgentPaneError.offline }
            let reply = try await client.agentAttachment(.init(session: session, item: item, attachment: attachment.id))
            guard reply.attachment.descriptor == attachment else { throw ModelError("The attachment does not match this message.") }
            return reply.attachment.data
        }
        surface.fetchAttachment = { [weak self] item, attachment in
            guard let self else { throw AgentPaneError.offline }
            return try await self.attachmentCache.data(item: item, attachment: attachment)
        }
        surface.onOpenAttachment = { [weak self] item, attachment, download in
            guard let self, let fetch = self.surface.fetchAttachment else { return }
            if download {
                Task { [weak self] in
                    do {
                        let data = try await fetch(item, attachment)
                        guard let self, !self.disposed else { return }
                        AgentFilePreviewWindow.save(data, name: attachment.name, window: self.view.window) { [weak self] error in self?.showError(error) }
                    } catch { if self?.disposed == false { self?.showError(error) } }
                }
            } else {
                self.mediaPreview?.close(); self.filePreview?.close()
                let preview = AgentFilePreviewWindow(item: item, attachment: attachment, fetch: fetch, theme: self.surface.theme)
                self.filePreview = preview; preview.showWindow(nil)
            }
        }
        surface.onPreviewAttachments = { [weak self] item, attachments, index in
            guard let self, let fetch = self.surface.fetchAttachment else { return }
            self.mediaPreview?.close()
            self.filePreview?.close()
            let preview = AgentMediaPreviewWindow(item: item, attachments: attachments, index: index, fetch: fetch, theme: self.surface.theme)
            self.mediaPreview = preview
            preview.present(in: self.view.window)
        }
        surface.theme = model.theme
        surface.themeDidChange()
        surface.onRunShellCommand = { [weak model] command in
            guard let model, let project = owningProject(), let target = model.state.project(project) else { return }
            model.newTerminal(in: project, command: command, directory: target.directory)
        }
        surface.onOpenFile = { [weak model] path, line in
            guard let model, let project = owningProject() else { return }
            model.openEditor(project: project, path: path, line: line)
        }
        composerCoordinator.loadFiles = { [weak model] in
            guard let model, let project = model.state.paneProject(pane), let client = model.sideClient(for: project) else {
                throw AgentPaneError.offline
            }
            return try await client.searchFiles(project).paths
        }
        composerCoordinator.loadThreads = { [weak model, weak self] in
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
            for thread in threads { self?.surface.linkServices.threadTitles[thread.id] = thread.title }
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

    func restorePreferences(defaults: AgentComposerPreferences?, draft: AgentComposerPreferences?,
                            save: @escaping (AgentComposerPreferences?) -> Void) {
        initialPreferences = draft ?? defaults
        savePreferences = save
        if let draft {
            selection = AgentModelSelection(provider: draft.provider, model: draft.model)
            reasoningEffort = draft.effort
            selectionEdited = true
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
        surface.citationEnvironmentId = project.description
        surface.citationThreadId = session.description
        surface.composer.delegate = self
        surface.model.target = self
        surface.model.action = #selector(modelSelected(_:))
        surface.effort.target = self
        surface.effort.action = #selector(effortSelected)
        surface.promptQueue.onEdit = { [weak self] prompt in self?.editQueued(prompt) }
        surface.promptQueue.onRemove = { [weak self] prompt in self?.run(.removeQueued(session: self?.session ?? SessionId(), id: prompt.id, expectedRevision: prompt.revision)) }
        surface.promptQueue.onDeliver = { [weak self] prompt in self?.deliverQueued(prompt) }
        surface.promptQueue.onMove = { [weak self] prompt, before in
            guard let self else { return }
            self.run(.moveQueued(session: self.session, id: prompt.id, beforeID: before, expectedRevision: prompt.revision))
        }
        surface.promptQueue.onResume = { [weak self] in
            guard let self else { return }
            self.run(.resumeQueue(session: self.session))
        }
        surface.questions.onAnswer = { [weak self] id, answers, cancelled in
            guard let self, self.commandTask == nil else { return }
            self.run(.answer(session: self.session, request: id, answers: answers, cancelled: cancelled))
        }
        surface.questions.onChange = { [weak self] in self?.saveDraft() }
        surface.plan.onPress = { [weak self] in self?.togglePlanMode() }
        surface.send.onPress = { [weak self] in self?.send() }
        surface.stop.onPress = { [weak self] in try? self?.surface.actions.interrupt() }
        surface.retry.onPress = { [weak self] in self?.refresh() }
        surface.onOpenToolDiff = { [weak self] id, activity in
            guard let self else { return }
            if let existing = self.toolDiffWindows[id], existing.activity == activity { existing.window.showWindow(nil); return }
            self.toolDiffWindows[id]?.window.close()
            let controller = AgentToolDiff.makeWindow(session: self.session, activity: activity, theme: self.surface.theme)
            controller.onClose = { [weak self, weak controller] in
                if self?.toolDiffWindows[id]?.window === controller { self?.toolDiffWindows.removeValue(forKey: id) }
            }
            self.toolDiffWindows[id] = (activity, controller)
            controller.showWindow(nil)
        }
        surface.onOpenCheckpoint = { [weak self] id, path in
            guard let self, let fetch = self.loadCheckpoint else { return }
            let key = id + "\0" + (path ?? "")
            if let existing = self.checkpointWindows[key] { existing.showWindow(nil); return }
            let controller = AgentCheckpointDiffWindow(session: self.session, checkpoint: id, path: path,
                theme: self.surface.theme, fetch: fetch)
            controller.onClose = { [weak self] in self?.checkpointWindows.removeValue(forKey: key) }
            self.checkpointWindows[key] = controller
            controller.showWindow(nil)
        }
        surface.onApproval = { [weak self] id, allow in
            guard let actions = self?.surface.actions else { return }
            // A stale button is ignored; real failures are shown by `approveAndWait`.
            Task { @MainActor in try? await actions.approve(requestID: id, allow: allow) }
        }
        surface.actions.onApprove = { [weak self] id, allow in
            guard let self else { throw CancellationError() }
            try await self.approveAndWait(id, allow: allow)
        }
        surface.actions.onInterrupt = { [weak self] in self?.stop() }
        surface.onActionError = { [weak self] message in self?.showComposerError(message) }
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
        voice.onChange = { [weak self] in self?.updateControls() }
        voice.onError = { [weak self] in self?.showComposerError($0) }
        voice.onText = { [weak self] text in
            guard let self, !self.disposed else { return }
            let separator = self.surface.composer.string.isEmpty ? "" : " "
            self.surface.composer.insertText(separator + text, replacementRange: NSRange(location: self.surface.composer.textStorage?.length ?? 0, length: 0))
            self.saveDraft(); self.updateControls()
        }
        surface.microphone.onPress = { [weak self] in self?.voice.toggleDictation() }
        surface.waveform.onPress = { [weak self] in
            guard let self else { return }
            self.voice.toggleReading(self.snapshot?.items.last { $0.kind == .assistant && $0.isComplete }?.text ?? "")
        }
        updateControls()
    }

    func focusContent() {
        view.window?.makeFirstResponder(surface.composer)
    }
    func didShow() { refresh() }
    func didHide() { voice.stop() } // Keep the draft and scroll position when switching projects.

    func willClose() async -> Bool {
        guard submitting || snapshot?.status == .working || snapshot?.status == .waiting || snapshot?.queuedPrompts?.isEmpty == false else { return true }
        return await confirmClose?() ?? true
    }

    /// Called only after every pane in the closing group has approved its close.
    func commitClose() async -> Bool {
        // Don't strand an unused pane when the server is offline or predates agent panes.
        // An in-flight create must finish before close, or it could create an orphan later.
        while !created, let pending = refreshTask { await pending.value }
        guard created else { return true }
        do {
            try await flushDraft()
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
        voice.stop()
        saveDraft(immediate: true)
        attachmentCache.cancel()
        filePreview?.close()
        filePreview = nil
        mediaPreview?.close()
        mediaPreview = nil
        for controller in Array(checkpointWindows.values) { controller.close() }
        checkpointWindows.removeAll()
        for entry in Array(toolDiffWindows.values) { entry.window.close() }
        toolDiffWindows.removeAll()
        disposed = true
        approvalToken = nil
        refreshTask?.cancel()
        commandTask?.cancel()
        stopTask?.cancel()
        historyTask?.cancel()
        refreshTask = nil
        commandTask = nil
        stopTask = nil
        historyTask = nil
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
        approvalToken = nil
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
                    let firstSnapshot = !self.created
                    if firstSnapshot, result.items.isEmpty, result.providerSession == nil, result.revision <= 1,
                       let defaults = self.initialPreferences {
                        if !self.selectionEdited {
                            self.selection = AgentModelSelection(provider: defaults.provider, model: defaults.model)
                            self.reasoningEffort = defaults.effort
                            self.selectionEdited = true
                            self.persistSelection(access: defaults.access)
                        }
                    }
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

    func togglePlanMode() {
        guard !surface.composer.hasMarkedText(), !disposed, created, commandTask == nil, !needsAuthoritativeSnapshot else { return }
        guard snapshot?.status == .idle || snapshot?.status == .failed else {
            showComposerError("Stop the current response before changing plan mode.")
            return
        }
        run(.setPlan(session: session, enabled: snapshot?.planMode != true)) { [weak self] in
            self?.lastSubmission = nil; self?.saveDraft()
        }
    }

    func send() {
        guard !approvalInFlight else { return }
        if composerCoordinator.performTypedAction() { return }
        let sentDraft = NSAttributedString(attributedString: surface.composer.attributedString())
        let text = AgentComposerCitation.prompt(from: sentDraft)
        guard !disposed, commandTask == nil, created, canSend,
              preparingAttachments == 0,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty else { return }
        let commandText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = AgentComposerCoordinator.commandName(in: commandText)
        // A lone `/name` is meant as a command; `/tmp is full` or a path is an ordinary prompt.
        if selection.provider == .codex, let command, commandText == "/" + command, !command.hasPrefix("skill:"),
           !composerCoordinator.providerCommands.contains(command) {
            showComposerError("This Codex command is not supported in agent panes. Use / to choose an available command.")
            return
        }
        if snapshot?.status == .working, let command, composerCoordinator.providerCommands.contains(command) {
            showComposerError("Run provider commands after the current response finishes.")
            return
        }
        let attachments = draftAttachments.map { AgentChatAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, data: $0.data) }
        let sentIDs = Set(attachments.map(\.id))
        composerCoordinator.dismiss()
        surface.scrollToEnd()
        var prompt = AgentPrompt(text: text, model: selection.model, effort: reasoningEffort,
                                 provider: selection.provider, planMode: snapshot?.planMode == true, attachments: attachments)
        // A reconnect may update the displayed model or mode after acceptance.
        // Keep the original delivery identity until the user edits the payload or settings.
        if let previous = lastSubmission, previous.text == text, previous.attachments == attachments {
            prompt = previous
        }
        lastSubmission = prompt
        run(.submit(session: session, prompt: prompt)) { [weak self] in
            self?.lastSubmission = nil
            self?.saveDraft()
            self?.selectionEdited = false
            self?.savePreferences?(nil)
            self?.draftAttachments.removeAll { sentIDs.contains($0.id) }
            self?.updateAttachments()
            // Don't lose edits typed while the request was in flight, or a failed send.
            guard let self, self.surface.composer.attributedString().isEqual(to: sentDraft) else { return }
            self.surface.composer.string = ""
            self.surface.refreshComposer()
            self.saveDraft()
        }
    }

    func approve(_ id: String, allow: Bool) {
        guard !disposed, !needsAuthoritativeSnapshot, !approvalInFlight, commandTask == nil, snapshot?.items.contains(where: {
            $0.id == id && $0.kind == .approval && !$0.isComplete
        }) == true else { return }
        run(.approve(session: session, request: id, allow: allow))
    }

    /// The web action is acknowledged only after the server accepts it. Keeping
    /// this await in the bridge task also propagates page disposal cancellation.
    private func approveAndWait(_ id: String, allow: Bool) async throws {
        try Task.checkCancellation()
        guard !disposed, !needsAuthoritativeSnapshot, !approvalInFlight, commandTask == nil,
              snapshot?.items.contains(where: { $0.id == id && $0.kind == .approval && !$0.isComplete }) == true else {
            throw ModelError("This approval is no longer available.")
        }
        let generation = connectionGeneration
        let token = UUID()
        approvalToken = token
        updateControls()
        defer {
            if approvalToken == token { approvalToken = nil; updateControls() }
        }
        do {
            let result = try await request(.approve(session: session, request: id, allow: allow))
            try Task.checkCancellation()
            guard !disposed, generation == connectionGeneration, result.session == session,
                  result.project == (authoritativeProject ?? project) else { throw CancellationError() }
            accept(result, generation: generation)
        } catch {
            if !Task.isCancelled, !disposed, generation == connectionGeneration { showError(error) }
            throw error
        }
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
        saveDraft()
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
        case "skills": composerCoordinator.browseSkills(); return
        case "status":
            showComposerError("\(selection.provider.name) · \(effectiveModel ?? "Provider default") · \(reasoningEffort?.title ?? "Auto") · \((snapshot?.accessMode ?? .standard).title)")
            return
        case "new", "clear-conversation": onNewConversation?(); return
        case "resume": showHistory(); return
        case "model": control = surface.model
        case "effort": control = surface.effort
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

    private func showHistory() {
        guard !disposed, historyTask == nil, let loadHistory else { return }
        errorMessage = nil
        historyTask = Task { [weak self] in
            defer {
                self?.historyTask = nil
                self?.updateControls()
            }
            do {
                let entries = try await loadHistory()
                guard let self, !Task.isCancelled, !self.disposed else { return }
                self.presentHistory(entries)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, !self.disposed else { return }
                self.showHistoryError(error, doing: "list past conversations")
            }
        }
        updateControls()
    }

    private func presentHistory(_ entries: [AgentHistoryEntry]) {
        guard !entries.isEmpty else {
            showComposerError("Claude Code and Codex have no other conversations saved for this folder.")
            return
        }
        let menu = NSMenu()
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        for provider in TabCore.AgentChatProvider.allCases {
            let group = entries.filter { $0.provider == provider }
            guard !group.isEmpty else { continue }
            menu.addItem(NSMenuItem.sectionHeader(title: provider.name))
            for entry in group.prefix(40) {
                let title = entry.title.count > 80 ? entry.title.prefix(79) + "…" : entry.title
                let item = NSMenuItem(title: String(title), action: #selector(historySelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry
                let when = formatter.localizedString(for: entry.updatedAt, relativeTo: Date())
                if #available(macOS 14.4, *) { item.subtitle = when }
                item.toolTip = entry.title + "\n" + when
                menu.addItem(item)
            }
        }
        let anchor = surface.composerScroll
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.isFlipped ? 0 : anchor.bounds.height), in: anchor)
    }

    @objc private func historySelected(_ sender: NSMenuItem) {
        guard !disposed, historyTask == nil, let entry = sender.representedObject as? AgentHistoryEntry,
              let importHistory else { return }
        // An unused pane takes the conversation over; otherwise it opens beside this one.
        let unused = created && !submitting && commandTask == nil && snapshot.map {
            $0.items.isEmpty && $0.providerSession == nil && $0.status == .idle
        } == true
        let target = unused ? session : SessionId()
        let generation = connectionGeneration
        errorMessage = nil
        historyTask = Task { [weak self] in
            defer {
                self?.historyTask = nil
                self?.updateControls()
            }
            do {
                let result = try await importHistory(entry, target)
                guard let self, !Task.isCancelled, !self.disposed else { return }
                if result.session == self.session {
                    self.selectionEdited = false
                    self.accept(result, generation: generation, authoritative: true)
                } else {
                    self.showConversation?(result)
                }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, !self.disposed else { return }
                self.showHistoryError(error, doing: "continue that conversation")
            }
        }
        updateControls()
    }

    private func showHistoryError(_ error: Error, doing action: String) {
        if (error as? ClientError)?.serverCode == .unsupported {
            showComposerError("This server can't \(action). Update Tab on it first.")
        } else {
            showComposerError("Couldn't \(action): \(error.localizedDescription)")
        }
    }

    func stop() {
        guard !disposed, !needsAuthoritativeSnapshot, stopTask == nil,
              submitting || snapshot?.status == .working || snapshot?.status == .waiting || hasActiveQueue else { return }
        guard snapshot?.status == .working || snapshot?.status == .waiting || hasActiveQueue else {
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
        guard !approvalInFlight, commandTask == nil, !disposed else { return }
        let generation = connectionGeneration
        if case .send = command { submitting = true }
        if case .submit = command { submitting = true }
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
                if case .submit = command { try await self.flushDraft() }
                let result = try await self.request(command)
                guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                if case .submit = command { onSuccess?() }
                else if result.status != .failed { onSuccess?() }
                self.accept(result, generation: generation)
            } catch {
                guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                self.showError(error)
            }
        }
        updateControls()
    }

    private func accept(_ result: AgentChatSnapshot, generation: UInt64, authoritative: Bool = false) {
        guard !disposed, generation == connectionGeneration, result.session == session,
              authoritativeProject == nil || result.project == authoritativeProject else { return }
        if needsAuthoritativeSnapshot {
            guard authoritative else { return }
            needsAuthoritativeSnapshot = false
        } else {
            guard result.revision >= (snapshot?.revision ?? 0) else { return }
        }
        snapshot = result
        // Home may remap during bootstrap. Bind the first authoritative session
        // owner, then reject foreign-project replies for this controller's life.
        authoritativeProject = result.project
        surface.citationEnvironmentId = result.project.description
        errorMessage = nil
        if !selectionEdited || (result.providerSession != nil && selection.provider != result.provider) {
            selection = AgentModelSelection(provider: result.provider, model: result.model)
            reasoningEffort = result.reasoningEffort
            selectionEdited = false
        }
        surface.render(result)
        if authoritative { surface.actions.project?.refreshProjectMetadata() }
        updateControls()
        if stopRequested && (result.status == .working || result.status == .waiting || hasActiveQueue) { stop() }
        titleDidChange?()
        onTitleChange?(title)
    }

    private func showError(_ error: Error) {
        if (error as? ClientError)?.serverCode == .unsupported {
            errorMessage = "This server does not support that action. Update Tab on the server, then reconnect. Your draft is retained."
        } else { errorMessage = error.localizedDescription }
        updateControls()
    }

    private var hasActiveQueue: Bool {
        snapshot?.queuePaused != true && snapshot?.queuedPrompts?.isEmpty == false
    }

    private var canSend: Bool {
        guard !needsAuthoritativeSnapshot, let snapshot else { return false }
        return !restoringDraft && (snapshot.status == .idle || snapshot.status == .failed || snapshot.status == .working || snapshot.status == .waiting)
    }

    private func updateControls() {
        composerCoordinator.providerCommands = selection.provider == .codex
            ? ["compact", "review"] : (snapshot?.provider == .claude ? (snapshot?.commands ?? []) : [])
        let interactionsEnabled = !disposed && !needsAuthoritativeSnapshot && commandTask == nil && !approvalInFlight
        surface.promptQueue.update(snapshot?.queuedPrompts ?? [], paused: snapshot?.queuePaused == true, enabled: interactionsEnabled)
        surface.questions.update(snapshot?.items.first { $0.questionnaire != nil && !$0.isComplete }, enabled: interactionsEnabled)
        surface.questions.restore(questionDrafts)
        surface.plan.isHidden = snapshot?.planMode != true
        surface.composer.planning = snapshot?.planMode == true
        surface.composer.isEditable = !disposed && !restoringDraft
        surface.attach.isEnabled = !disposed && !restoringDraft
        surface.microphone.isEnabled = !disposed && !restoringDraft && snapshot?.status != .closed
        surface.microphone.toolTip = voice.state == .idle || voice.state == .speaking ? "Dictate a message on this Mac" : "Finish dictation"
        surface.waveform.isEnabled = !disposed && (voice.state == .speaking || snapshot?.items.contains { $0.kind == .assistant && $0.isComplete } == true)
        surface.waveform.toolTip = voice.state == .speaking ? "Stop reading aloud" : "Read latest response aloud"
        surface.microphone.contentTintColor = voice.state == .listening || voice.state == .authorizing ? surface.theme.accent : surface.theme.fgMuted
        surface.waveform.contentTintColor = voice.state == .speaking ? surface.theme.accent : surface.theme.fgMuted
        surface.send.isEnabled = !approvalInFlight && !disposed && created && commandTask == nil && canSend &&
            preparingAttachments == 0 && (!surface.composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty)
        surface.stop.isEnabled = !disposed && !needsAuthoritativeSnapshot && stopTask == nil && !stopRequested &&
            (submitting || snapshot?.status == .working || snapshot?.status == .waiting || hasActiveQueue)
        let busy = submitting || snapshot?.status == .working || snapshot?.status == .waiting || hasActiveQueue
        surface.send.isHidden = false
        surface.send.toolTip = busy
            ? "Queue this prompt for the next response"
            : "Send message"
        surface.stop.isHidden = !busy
        surface.model.isEnabled = canEditSelection && !needsAuthoritativeSnapshot
        surface.effort.isEnabled = surface.model.isEnabled && !supportedEfforts.isEmpty
        surface.contextIndicator.update(usedTokens: snapshot?.contextUsage?.usedTokens,
                                        contextWindow: snapshot?.contextUsage?.contextWindow)
        surface.setActivity(status: snapshot?.status ?? .idle, submitting: submitting)
        updateSelectionMenus()
        surface.setApprovalsEnabled(!approvalInFlight && commandTask == nil && !disposed && !needsAuthoritativeSnapshot)
        surface.feedback.stringValue = errorMessage ?? statusText
        surface.feedback.toolTip = surface.feedback.stringValue
        surface.feedback.setAccessibilityValue(surface.feedback.stringValue)
        surface.retry.isHidden = errorMessage == nil
        surface.refreshComposer()
        surface.needsLayout = true
    }

    private var statusText: String {
        if voice.state == .authorizing { return "Waiting for microphone and speech permission…" }
        if voice.state == .listening { return "Listening… Click the microphone to finish and review your message." }
        if voice.state == .speaking { return "Reading response aloud… Click the waveform to stop." }
        if preparingAttachments > 0 { return "Preparing attachments…" }
        if historyTask != nil { return "Looking through past conversations…" }
        if needsAuthoritativeSnapshot { return "Reconnecting… Your transcript and draft are kept here." }
        if submitting { return "" }
        switch snapshot?.status {
        case .working, .waiting: return ""
        case .closed: return "This conversation has ended. Open a new agent pane to continue."
        case .failed: return "Turn failed · Change the model or try again"
        case .idle: return ""
        case nil: return "Connecting…"
        }
    }

    func textDidChange(_ notification: Notification) {
        saveDraft()
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
        lastSubmission = nil; saveDraft()
        composerCoordinator.invalidate()
        if let effort = reasoningEffort, !supportedEfforts.contains(effort) { reasoningEffort = nil }
        selectionEdited = true
        persistSelection()
        titleDidChange?()
        updateControls()
    }

    func selectEffort(_ effort: AgentReasoningEffort?) {
        guard surface.effort.isEnabled else { return }
        if let effort, !supportedEfforts.contains(effort) { return }
        reasoningEffort = effort
        lastSubmission = nil; saveDraft()
        selectionEdited = true
        persistSelection()
        titleDidChange?()
        updateControls()
    }

    @objc private func modelSelected(_ sender: Any?) {
        guard let item = (sender as? NSMenuItem) ?? surface.model.selectedItem else { return }
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
            let heading = NSMenuItem(title: provider.name, action: nil, keyEquivalent: "")
            let models = NSMenu(title: provider.name)
            models.autoenablesItems = false
            heading.submenu = models
            heading.state = selection.provider == provider ? .on : .off
            menuLogos[menu.items.count] = provider == .claude ? .claude : .codex
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
                models.addItem(status)
            }
            for choice in choices {
                let item = NSMenuItem(title: modelTitle(choice), action: nil, keyEquivalent: "")
                item.representedObject = choice
                item.target = self
                item.action = #selector(modelSelected(_:))
                let current = selectedModelDescriptor.map { AgentModelSelection(provider: selection.provider, model: $0.id) } ?? displayedSelection
                item.state = choice == current ? .on : .off
                let reported = descriptor(for: choice) != nil
                item.isEnabled = reported && (canChangeProvider || provider == snapshot?.provider)
                item.toolTip = !reported ? "Current model is not listed in the provider catalog."
                    : item.isEnabled ? choice.model : "Open a new agent pane to use another provider."
                models.addItem(item)
            }
        }
        menu.addItem(.separator())
        let refreshModels = NSMenuItem(title: "Refresh models…", action: nil, keyEquivalent: "")
        refreshModels.representedObject = "refresh-models"
        menu.addItem(refreshModels)
        surface.model.menu = menu
        surface.model.menuLogos = menuLogos
        surface.model.providerLogo = selection.provider == .claude ? .claude : .codex
        surface.model.select(nil)
        surface.model.displayedTitle = modelTitle(displayedSelection)
        surface.model.icon = selection.provider == .claude ? .sparkles : .cpu
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
        surface.effort.icon = .brain
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

extension AgentPaneController {
    private func configureDraftStore(_ url: URL) {
        let store = AgentDraftStore(url: url)
        draftStore = store; restoringDraft = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.restoringDraft = false; self.updateControls() }
            do {
                guard let draft = try await store.read(), !self.disposed else { return }
                self.surface.composer.textStorage?.setAttributedString(draft.attributed(theme: self.surface.theme))
                self.lastSubmission = draft.submission
                self.questionDrafts = draft.answers
                var attachments: [AgentDraftAttachment] = []
                for item in draft.attachments {
                    let thumbnail = item.mimeType.hasPrefix("image/") ? await AgentAttachmentImporter.previewImage(data: item.data, pixels: 160) : nil
                    attachments.append(.init(id: item.id, name: item.name, mimeType: item.mimeType, data: item.data, thumbnail: thumbnail))
                }
                guard !self.disposed else { return }
                self.draftAttachments = attachments
                self.updateAttachments()
                self.surface.refreshComposer()
            } catch { self.showComposerError(error.localizedDescription) }
        }
    }

    private func captureDraft() -> AgentSavedDraft {
        questionDrafts.merge(surface.questions.savedAnswers) { _, latest in latest }
        if let snapshot {
            let pending = Set(snapshot.items.filter { !$0.isComplete && $0.questionnaire != nil }.map(\.id))
            questionDrafts = questionDrafts.filter { pending.contains($0.key) }
        }
        return AgentSavedDraft(text: surface.composer.attributedString(), attachments: draftAttachments,
                               submission: lastSubmission, answers: questionDrafts)
    }
    private func saveDraft(immediate: Bool = false) {
        guard !restoringDraft, let store = draftStore else { return }
        draftSaveTask?.cancel()
        let draft = captureDraft()
        draftRevision &+= 1
        let revision = draftRevision
        draftSaveTask = Task { [weak self] in
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(200)) }
                try Task.checkCancellation()
                try await store.write(draft, revision: revision)
            } catch is CancellationError {} catch {
                self?.showComposerError("Could not save this draft: " + error.localizedDescription)
            }
        }
    }
    func flushDraft() async throws {
        voice.stop()
        await draftRestoreTask?.value
        guard let store = draftStore else { return }
        draftSaveTask?.cancel()
        draftRevision &+= 1
        try await store.write(captureDraft(), revision: draftRevision)
    }

    private func editQueued(_ prompt: AgentQueuedPrompt) {
        guard commandTask == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Edit queued prompt"
        alert.window.appearance = surface.theme.nsAppearance
        alert.informativeText = prompt.state == .uncertain
            ? "The earlier delivery may have reached the agent. Editing does not send it again. Attachments stay with the prompt."
            : "Attachments stay with this prompt. Saving does not send it immediately."
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 110))
        let field = NSTextField(string: prompt.text)
        field.frame = NSRect(x: 0, y: 38, width: 440, height: 72)
        field.cell?.wraps = true; field.cell?.isScrollable = false
        let settings = NSButton(checkboxWithTitle: "Use current model, reasoning effort and plan mode", target: nil, action: nil)
        settings.frame = NSRect(x: 0, y: 0, width: 440, height: 28)
        content.addSubview(field); content.addSubview(settings)
        alert.accessoryView = content
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(.editQueued(session: session, id: prompt.id, text: field.stringValue, expectedRevision: prompt.revision,
                        settings: settings.state == .on ? .init(model: effectiveModel, effort: reasoningEffort, planMode: snapshot?.planMode == true) : nil))
    }
    private func deliverQueued(_ prompt: AgentQueuedPrompt) {
        guard commandTask == nil else { return }
        if prompt.state == .uncertain || prompt.state == .failed {
            let alert = NSAlert()
            alert.window.appearance = surface.theme.nsAppearance
            alert.messageText = "Send this prompt again?"
            alert.informativeText = "The previous delivery may have reached the agent. Review the conversation first; sending again can repeat its actions."
            alert.addButton(withTitle: "Send again"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        run(.deliverQueued(session: session, id: prompt.id, expectedRevision: prompt.revision))
    }
}
