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
                title: "Close this agent tab?",
                message: "The agent is still running. Closing the tab stops its current work.",
                confirm: "Close",
                destructive: true
            ) ?? true
        }
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
        surface.access.target = self
        surface.access.action = #selector(accessSelected)
        for mode in AgentAccessMode.allCases {
            surface.access.addItem(withTitle: mode.title)
            surface.access.lastItem?.representedObject = mode
            surface.access.lastItem?.toolTip = mode.tooltip
        }
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
        updateControls()
    }

    func focusContent() {
        view.window?.makeFirstResponder(surface.composer)
    }
    func didShow() { refresh() }
    func didHide() {} // Keep the draft, transcript and scroll position when switching projects.

    func willClose() async -> Bool {
        guard submitting || snapshot?.status == .working || snapshot?.status == .waiting else { return true }
        return await confirmClose?() ?? true
    }

    /// Called only after every pane in the closing group has approved its close.
    func commitClose() async -> Bool {
        // Don't strand an unused pane when the server is offline or predates agent panes.
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
                    if firstSnapshot, result.items.isEmpty, result.providerSession == nil, result.revision <= 1,
                       let access = self.initialPreferences?.access, access != result.accessMode {
                        self.run(.setAccess(session: self.session, mode: access))
                    }
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
        guard !approvalInFlight else { return }
        if composerCoordinator.performTypedAction() { return }
        let text = AgentComposerCitation.prompt(from: surface.composer.attributedString())
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
        run(.send(session: session, text: text, model: selection.model,
                  reasoningEffort: reasoningEffort, provider: selection.provider,
                  attachments: attachments.isEmpty ? nil : attachments)) { [weak self] in
            self?.selectionEdited = false
            self?.savePreferences?(nil)
            self?.draftAttachments.removeAll { sentIDs.contains($0.id) }
            self?.updateAttachments()
            // Don't lose edits typed while the request was in flight, or a failed send.
            guard let self, self.surface.composer.string == text else { return }
            self.surface.composer.string = ""
            self.surface.refreshComposer()
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
        guard !approvalInFlight else { return }
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
        if stopRequested && (result.status == .working || result.status == .waiting) { stop() }
        titleDidChange?()
        onTitleChange?(title)
    }

    private func showError(_ error: Error) {
        errorMessage = "\(error.localizedDescription) Your draft is saved here. Retry to reconnect."
        updateControls()
    }

    private var canSend: Bool {
        guard !needsAuthoritativeSnapshot, let snapshot else { return false }
        return snapshot.status == .idle || snapshot.status == .failed || snapshot.status == .working
    }

    private func updateControls() {
        composerCoordinator.providerCommands = selection.provider == .codex
            ? ["compact", "review"] : (snapshot?.provider == .claude ? (snapshot?.commands ?? []) : [])
        surface.composer.isEditable = !disposed
        surface.attach.isEnabled = !disposed
        surface.send.isEnabled = !approvalInFlight && !disposed && created && commandTask == nil && canSend &&
            preparingAttachments == 0 && (!surface.composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty)
        surface.stop.isEnabled = !disposed && !needsAuthoritativeSnapshot && stopTask == nil && !stopRequested &&
            (submitting || snapshot?.status == .working || snapshot?.status == .waiting)
        let busy = submitting || snapshot?.status == .working || snapshot?.status == .waiting
        surface.send.isHidden = false
        surface.send.toolTip = busy
            ? (selection.provider == .codex ? "Send instructions to the active response" : "Queue a follow-up message")
            : "Send message"
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
        surface.setApprovalsEnabled(!approvalInFlight && commandTask == nil && !disposed && !needsAuthoritativeSnapshot)
        surface.feedback.stringValue = errorMessage ?? statusText
        surface.feedback.toolTip = surface.feedback.stringValue
        surface.feedback.setAccessibilityValue(surface.feedback.stringValue)
        surface.retry.isHidden = errorMessage == nil
        surface.refreshComposer()
        surface.needsLayout = true
    }

    private var statusText: String {
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
        persistSelection()
        titleDidChange?()
        updateControls()
    }

    func selectEffort(_ effort: AgentReasoningEffort?) {
        guard surface.effort.isEnabled else { return }
        if let effort, !supportedEfforts.contains(effort) { return }
        reasoningEffort = effort
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

    func selectAccess(_ mode: AgentAccessMode) {
        guard surface.access.isEnabled else { return }
        run(.setAccess(session: session, mode: mode)) { [weak self] in self?.persistSelection(access: mode) }
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
