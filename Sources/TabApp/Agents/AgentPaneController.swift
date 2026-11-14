import AppKit
import TabClient
import TabCore
import TabProtocol
import UniformTypeIdentifiers

/// A server-owned conversation. UI tasks never consume the connection's event stream.
@MainActor
final class AgentPaneController: NSObject, PaneContentController, NSTextViewDelegate, NSMenuDelegate {
    let session: SessionId
    let provider: TabCore.AgentChatProvider
    let project: ProjectId
    let surface = AgentPaneView()
    var view: NSView { surface }
    var title: String {
        snapshot?.items.first(where: { $0.kind == .user && !$0.isProviderTurn })?.text
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
    private var reviewComments: [AgentReviewComment] = []
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
    var loadHistory: (() async throws -> AgentHistoryReply)?
    /// Continues one of them as the conversation with the given ID.
    var importHistory: ((AgentHistoryEntry, SessionId) async throws -> AgentChatSnapshot)?
    /// Shows a conversation this pane doesn't hold, beside it.
    var showConversation: ((AgentChatSnapshot) -> Void)?
    private var historyTask: Task<Void, Never>?
    private var historyPicker: AgentSearchPicker?
    private var queueEditor: AgentTextEditorSheet?
    var titleDidChange: (() -> Void)?

    private let request: (AgentChatRequest) async throws -> AgentChatSnapshot
    private let attachmentCache = AgentAttachmentCache()
    private var filePreview: AgentFilePreviewWindow?
    private var mediaPreview: AgentMediaPreviewWindow?
    private var toolDiffWindows: [String: (activity: AgentToolActivity, window: AgentCheckpointDiffWindow)] = [:]
    private(set) var checkpointWindows: [String: AgentCheckpointDiffWindow] = [:]
    var loadCheckpoint: AgentCheckpointDiffWindow.Fetch?
    /// Conversation requests that reply with something other than the snapshot.
    var conversationRequest: ((AgentConversationRequest) async throws -> AgentConversationReply)? {
        didSet { surface.onLoadEarlier = conversationRequest == nil ? nil : { [weak self] in self?.loadEarlier() } }
    }
    /// Archived items loaded above the retained ones, the archive position of the first,
    /// and the omitted count they were loaded against.
    private(set) var earlierItems: [AgentChatItem] = []
    private var earlierStart = 0
    private var earlierBasis: Int?
    private var earlierTask: Task<Void, Never>?
    /// The version of the Tab running this conversation's server, from its handshake.
    var serverVersion: (() -> String?)?
    /// This app's version, compared with the server's.
    var appVersion = Release.version
    /// This connection's server was found older than the app, and the pane said so.
    private var checkedServerVersion = false
    /// This connection's server can't answer incremental reads; it gets full ones.
    private var readSinceUnsupported = false
    private(set) var subagentWindows: [String: AgentSubagentStepsWindow] = [:]
    private var refreshTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var approvalToken: UUID?
    private var approvalInFlight: Bool { approvalToken != nil }
    private var stopTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    /// The failed turn whose attachments could no longer be read, and why, so Retry stays off.
    private var unretryable: (item: String, reason: String)?
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
    /// A failed request or lost connection; the next accepted snapshot clears it, and Refresh retries.
    private(set) var errorMessage: String?
    /// A composer message, such as a validation hint or `/status`, that snapshots leave alone.
    private(set) var notice: AgentComposerNotice?
    private var noticeExpiry: Task<Void, Never>?
    /// How long an informational notice stays before it goes away by itself.
    var infoNoticeLifetime: Duration = .seconds(8)
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
            return try await client.agentHistory(.init(project: project))
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
        if context.project.serverId == .local { localProjectRoot = context.project.directory.rawValue }
        surface.workspaceDescription = { [weak model] in
            guard let model, let id = owningProject(), let project = model.state.project(id), !project.home else { return nil }
            let branch = model.shownGit(id)?.summary?.branch
            return project.name + (branch.map { $0 == project.name ? "" : " on " + $0 } ?? "")
        }
        AgentConversationProjectActions.install(surface: surface, model: model, pane: pane, session: session)
        loadCheckpoint = { [weak model] request in
            guard let model, let project = owningProject(), let client = model.sideClient(for: project) else {
                throw AgentPaneError.offline
            }
            return try await client.agentCheckpoint(request)
        }
        keyDisplay = { [weak model] id in model?.settings.keymap.chord(id)?.display }
        surface.mediaLoader.remotePolicy = { [weak model] in model?.settings.agents.remoteImages ?? AgentSettings().remoteImages }
        serverVersion = { [weak model] in
            guard let model, let project = owningProject() else { return nil }
            return model.sideClient(for: project)?.server.build.version
        }
        conversationRequest = { [weak model] request in
            guard let model, let project = owningProject(), let client = model.sideClient(for: project) else {
                throw AgentPaneError.offline
            }
            return try await client.agentConversation(request)
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
            // Read the conversations side by side rather than one after another.
            let candidates = Array(Set(sessions).prefix(24))
            let snapshots = await withTaskGroup(of: (Int, AgentChatSnapshot?).self) { group in
                for (index, other) in candidates.enumerated() {
                    group.addTask { (index, try? await client.agentChat(.read(session: other))) }
                }
                var results = [AgentChatSnapshot?](repeating: nil, count: candidates.count)
                for await (index, snapshot) in group { results[index] = snapshot }
                return results
            }
            try Task.checkCancellation()
            var threads: [AgentMentionThread] = []
            for (other, snapshot) in zip(candidates, snapshots) {
                guard let snapshot, let first = snapshot.items.first(where: { $0.kind == .user }), !first.text.isEmpty else { continue }
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
        surface.subagents.onReveal = { [weak self] id in self?.surface.reveal(.item(id)) }
        surface.subagents.onOpen = { [weak self] agent in self?.openSubagentSteps(agent) }
        surface.onOpenSubagent = { [weak self] toolUseID in
            guard let self else { return }
            let agent = self.snapshot?.subagents?.first { $0.toolUseID == toolUseID }
                ?? AgentSubagent(id: toolUseID, toolUseID: toolUseID, description: "Agent", status: .completed)
            self.openSubagentSteps(agent)
        }
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
        surface.retryTurn.onPress = { [weak self] in self?.retryLastTurn() }
        surface.onEditPrompt = { [weak self] item in self?.editAsNewPrompt(item) }
        surface.onForkPrompt = { [weak self] item in self?.fork(before: item) }
        surface.onRevert = { [weak self] checkpoint, paths in self?.revertTurn(checkpoint, paths: paths) }
        surface.onShowFullOutput = { [weak self] item in self?.showFullOutput(item) }
        surface.onCopyConversation = { [weak self] in self?.copyConversation() }
        surface.newConversation.onPress = { [weak self] in self?.onNewConversation?() }
        surface.dismissNotice.onPress = { [weak self] in self?.dismissNotice() }
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
            controller.onOpenFile = { [weak self] path, line in self?.surface.onOpenFile?(path, line) }
            controller.reviewComments = self.reviewComments.filter { $0.checkpoint == id }
            controller.onReviewChange = { [weak self] comments in
                guard let self else { return }
                self.reviewComments.removeAll { $0.checkpoint == id }
                self.reviewComments += comments
                self.refreshReviewComments()
                self.saveDraft(immediate: true)
            }
            controller.onDraftReview = { [weak self] in
                guard let self, !self.disposed, !self.restoringDraft else { throw ModelError("The conversation draft is unavailable.") }
                let comments = self.reviewComments.filter { $0.checkpoint == id }
                guard !comments.isEmpty else { return }
                let text = AgentReviewComment.prompt(comments)
                let editor = self.surface.composer
                let separator = editor.string.isEmpty ? "" : "\n\n"
                guard editor.string.utf8.count + separator.utf8.count + text.utf8.count <= 256 * 1024 else {
                    throw ModelError("These comments would exceed the draft size limit. Shorten the draft or the comments first.")
                }
                editor.insertText(separator + text, replacementRange: NSRange(location: editor.textStorage?.length ?? 0, length: 0))
                self.reviewComments.removeAll { $0.checkpoint == id }
                self.refreshReviewComments()
                self.surface.refreshComposer()
                self.saveDraft(immediate: true)
                self.updateControls()
                self.surface.window?.makeKeyAndOrderFront(nil)
                self.focusContent()
            }
            self.checkpointWindows[key] = controller
            controller.showWindow(nil)
        }
        surface.onApproval = { [weak self] id, allow in
            guard let actions = self?.surface.actions else { return }
            // A stale button is ignored; real failures are shown by `approveAndWait`.
            Task { @MainActor in try? await actions.approve(requestID: id, allow: allow) }
        }
        surface.onApprovalChoice = { [weak self] id, choice in self?.choose(choice, approval: id) }
        surface.actions.onApprove = { [weak self] id, allow in
            guard let self else { throw CancellationError() }
            try await self.approveAndWait(id, allow: allow)
        }
        surface.actions.onInterrupt = { [weak self] in self?.stop() }
        surface.onActionError = { [weak self] message in self?.showComposerError(message) }
        surface.attach.onPress = { [weak self] in self?.chooseAttachments() }
        surface.composer.onAttachFiles = { [weak self] in self?.attachFiles($0) }
        surface.composer.onPasteLongText = { [weak self] text in self?.attachLongPaste(text) ?? false }
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
        voice.onChange = { [weak self] in
            guard let self else { return }
            // The time left counts down while listening, on the shared clock.
            if self.voice.state == .listening {
                AgentSecondTicker.shared.subscribe(self) { [weak self] in self?.updateControls() }
            } else { AgentSecondTicker.shared.unsubscribe(self) }
            self.updateControls()
        }
        voice.onError = { [weak self] in self?.showComposerError($0) }
        voice.onPartial = { [weak self] text in self?.placeDictation(text, final: false) }
        voice.onText = { [weak self] text in self?.placeDictation(text, final: true) }
        surface.microphone.onPress = { [weak self] in self?.voice.toggleDictation() }
        updateControls()
    }

    /// A shortcut's key from the keymap, for tooltips that name it.
    var keyDisplay: ((ShortcutId) -> String?)?

    /// Stops the agent from the keyboard, as the Stop button does, when the composer or
    /// the transcript has the keyboard, the agent works, and nothing else in the pane
    /// wants the key: the suggestion list, Find, the selection toolbar or an input method.
    /// False lets the key go on.
    func performKeyboardStop() -> Bool {
        guard let responder = surface.window?.firstResponder as? NSView,
              responder === surface.composer || responder === surface || responder.isDescendant(of: surface.transcriptScroll),
              surface.stop.isEnabled, surface.suggestions.isHidden, !surface.isFindOpen, surface.selectionToolbar.isHidden,
              !surface.composer.hasMarkedText(), (responder as? NSTextView)?.hasMarkedText() != true else { return false }
        try? surface.actions.interrupt()
        return true
    }

    /// Allows or denies the oldest pending approval from the keyboard.
    func performApprovalShortcut(allow: Bool) -> Bool {
        guard !disposed, !needsAuthoritativeSnapshot, !approvalInFlight, commandTask == nil,
              let pending = snapshot?.items.first(where: { $0.kind == .approval && !$0.isComplete && $0.questionnaire == nil }) else {
            return false
        }
        surface.onApproval?(pending.id, allow)
        return true
    }

    /// The prompt of the conversation's last turn when it failed or was stopped, which
    /// Retry sends again. A turn the agent began itself has no prompt to send.
    var retryableTurnItem: AgentChatItem? {
        guard let snapshot, snapshot.status == .idle || snapshot.status == .failed, !hasActiveQueue,
              let turn = snapshot.turns?.last, turn.completedAt != nil,
              turn.outcome == .failed || turn.outcome == .interrupted,
              let item = snapshot.items.last(where: { $0.id == turn.userItemID }),
              item.kind == .user, !item.isProviderTurn else { return nil }
        return item
    }

    /// Sends the failed or stopped turn's prompt again through the normal submit path, as
    /// a new prompt with its own identity, attachments and all.
    func retryLastTurn() {
        guard !disposed, retryTask == nil, commandTask == nil, created, canSend, let item = retryableTurnItem else { return }
        let descriptors = item.attachments ?? []
        let fetch = surface.fetchAttachment
        retryTask = Task { [weak self] in
            var attachments: [AgentChatAttachment] = []
            do {
                for descriptor in descriptors {
                    guard let fetch else { throw ModelError("Its attachments can't be read here.") }
                    let data = try await fetch(item.id, descriptor)
                    attachments.append(AgentChatAttachment(name: descriptor.name, mimeType: descriptor.mimeType, data: data))
                }
            } catch {
                guard let self, !Task.isCancelled, !self.disposed else { return }
                self.retryTask = nil
                self.unretryable = (item.id, "Can't retry: an attachment of that message is no longer available (\(error.localizedDescription)).")
                self.updateControls()
                return
            }
            guard let self, !Task.isCancelled, !self.disposed else { return }
            self.retryTask = nil
            let prompt = AgentPrompt(text: item.text, model: self.selection.model, effort: self.reasoningEffort,
                                     provider: self.selection.provider, planMode: self.snapshot?.planMode == true,
                                     attachments: attachments)
            self.composerCoordinator.dismiss()
            self.surface.scrollToEnd()
            self.run(.submit(session: self.session, prompt: prompt))
        }
        updateControls()
    }

    /// Asks before a destructive action; nil asks with a sheet on the pane's window.
    var confirmDestructive: ((_ title: String, _ message: String, _ confirm: String) async -> Bool)?

    private func confirm(_ title: String, _ message: String, _ action: String) async -> Bool {
        if let confirmDestructive { return await confirmDestructive(title, message, action) }
        guard let window = surface.window else { return false }
        let alert = NSAlert()
        alert.window.appearance = surface.theme.nsAppearance
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    /// Puts a turn's files back as they were before it, all of them or `paths`, after the
    /// user confirms. Files changed since the turn need a second, explicit confirmation.
    func revertTurn(_ checkpoint: AgentTurnCheckpoint, paths: [String]?) {
        guard !disposed, let request = conversationRequest else { return }
        let session = session
        let count = paths?.count ?? checkpoint.totalFiles
        let files = count == 1 ? (paths?.first.map { "“\(($0 as NSString).lastPathComponent)”" } ?? "1 file") : "\(count) files"
        Task { [weak self] in
            guard let self, await self.confirm("Revert \(files)?",
                "Puts \(count == 1 ? "it" : "them") back as \(count == 1 ? "it was" : "they were") before this turn. Nothing else in the project changes.",
                "Revert") else { return }
            do {
                var reply = try await Self.revertReply(request, .revert(session: session, checkpoint: checkpoint.id, paths: paths, force: false))
                if !reply.conflicts.isEmpty {
                    let list = reply.conflicts.prefix(8).joined(separator: "\n") + (reply.conflicts.count > 8 ? "\n…" : "")
                    guard !self.disposed, await self.confirm(
                        reply.conflicts.count == 1 ? "1 file changed after this turn" : "\(reply.conflicts.count) files changed after this turn",
                        "\(list)\n\nReverting discards those later changes too.", "Revert Anyway") else { return }
                    reply = try await Self.revertReply(request, .revert(session: session, checkpoint: checkpoint.id, paths: paths, force: true))
                }
                guard !self.disposed else { return }
                self.showNotice(reply.reverted.count == 1 ? "Reverted 1 file." : "Reverted \(reply.reverted.count) files.", kind: .info)
            } catch let error as ClientError where error.serverCode == .unsupported {
                self.showNotice("This server can't revert a turn's changes. Update Tab on it, then restart it.", kind: .warning)
            } catch {
                guard !self.disposed else { return }
                self.showNotice("Couldn't revert: " + error.localizedDescription, kind: .warning)
            }
        }
    }

    private static func revertReply(_ request: (AgentConversationRequest) async throws -> AgentConversationReply,
                                    _ body: AgentConversationRequest) async throws -> AgentRevertReply {
        guard case .revert(let reply) = try await request(body) else { throw ModelError("The server sent an unexpected reply.") }
        return reply
    }

    /// Runs the provider's `/compact` as a prompt of its own, leaving the draft alone.
    func compactConversation() {
        guard !disposed, commandTask == nil, created, canSend, composerCoordinator.providerCommands.contains("compact") else { return }
        let prompt = AgentPrompt(text: "/compact", model: selection.model, effort: reasoningEffort,
                                 provider: selection.provider, planMode: snapshot?.planMode == true)
        run(.submit(session: session, prompt: prompt))
    }

    /// The conversation as Markdown: each message under who said it, tool calls as one line each.
    static func markdown(_ snapshot: AgentChatSnapshot) -> String {
        let agent = snapshot.provider.name
        return snapshot.items.compactMap { item -> String? in
            switch item.kind {
            case .user where item.isProviderTurn: return "_\(item.text)_"
            case .user: return "**You**\n\n" + item.text
            case .assistant: return "**\(agent)**\n\n" + item.text
            case .tool:
                guard let tool = item.tool else { return nil }
                let operation = tool.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return "> " + (tool.name ?? item.text) + (operation.isEmpty ? "" : " · `\(operation.replacingOccurrences(of: "`", with: "'"))`")
            case .notice: return "> " + item.text
            case .approval: return nil
            }
        }.joined(separator: "\n\n") + "\n"
    }

    func copyConversation() {
        guard let snapshot, !snapshot.items.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.markdown(snapshot), forType: .string)
        showNotice("Copied the conversation as Markdown.", kind: .info)
    }

    /// The snapshot with any loaded earlier items above its own.
    private func displayed(_ result: AgentChatSnapshot) -> AgentChatSnapshot {
        // More items were dropped since the pages loaded, so they no longer join up.
        if earlierBasis != nil, earlierBasis != result.omittedItems {
            earlierItems = []; earlierBasis = nil; earlierStart = 0
        }
        guard !earlierItems.isEmpty else { return result }
        var shown = result
        let retained = Set(result.items.map(\.id))
        shown.items = earlierItems.filter { !retained.contains($0.id) } + result.items
        shown.omittedItems = max(0, (result.omittedItems ?? 0) - earlierItems.count)
        return shown
    }

    /// Loads the page of archived items before those shown.
    func loadEarlier() {
        guard !disposed, earlierTask == nil, let request = conversationRequest, let snapshot else { return }
        let session = session
        let before = earlierItems.isEmpty ? nil : earlierStart
        let basis = snapshot.omittedItems
        earlierTask = Task { [weak self] in
            defer { self?.earlierTask = nil }
            do {
                guard case .earlier(let page) = try await request(.earlier(session: session, before: before, limit: AgentEarlierItems.maxItems)) else {
                    throw ModelError("The server sent an unexpected reply.")
                }
                guard let self, !self.disposed, self.snapshot?.omittedItems == basis else { return }
                guard !page.items.isEmpty else {
                    self.surface.onLoadEarlier = nil
                    self.showNotice("The earlier messages of this conversation weren't kept.", kind: .info)
                    if let current = self.snapshot { self.surface.render(self.displayed(current)) }
                    return
                }
                self.earlierItems = page.items + self.earlierItems
                self.earlierStart = page.start
                self.earlierBasis = basis
                if page.start == 0 { self.surface.onLoadEarlier = nil }
                if let current = self.snapshot { self.surface.render(self.displayed(current)) }
            } catch let error as ClientError where error.serverCode == .unsupported {
                self?.surface.onLoadEarlier = nil
                self?.showNotice("This server can't show earlier messages. Update Tab on it, then restart it.", kind: .warning)
            } catch is CancellationError {
            } catch { self?.showComposerError(error.localizedDescription) }
        }
    }

    /// Opens a tool's whole output, which the server keeps beyond the transcript's part.
    func showFullOutput(_ item: String) {
        guard !disposed, let request = conversationRequest else { return }
        let session = session
        let name = (snapshot?.items.first { $0.id == item }?.tool).map { AgentToolPresentation.displayName($0) + " output.txt" } ?? "Output.txt"
        let bytes = snapshot?.items.first { $0.id == item }?.tool?.fullOutputBytes ?? 0
        let descriptor = AgentChatAttachmentDescriptor(id: "output", name: name, mimeType: "text/plain", byteCount: bytes)
        mediaPreview?.close(); filePreview?.close()
        let preview = AgentFilePreviewWindow(item: item, attachment: descriptor, fetch: { item, _ in
            do {
                guard case .toolOutput(let output) = try await request(.toolOutput(session: session, item: item)) else {
                    throw ModelError("The server sent an unexpected reply.")
                }
                return Data(output.text.utf8)
            } catch let error as ClientError where error.serverCode == .unsupported {
                throw ModelError("This server can't show a tool's whole output. Update Tab on it, then restart it.")
            }
        }, theme: surface.theme)
        filePreview = preview
        preview.showWindow(nil)
    }

    /// Opens a new conversation beside this one with what came before `item`.
    func fork(before item: AgentChatItem) {
        guard !disposed, let request = conversationRequest else { return }
        let body = AgentConversationRequest.fork(session: SessionId(), from: session, project: nil, at: item.id)
        Task { [weak self] in
            do {
                guard case .forked(let snapshot) = try await request(body) else { throw ModelError("The server sent an unexpected reply.") }
                guard let self, !self.disposed else { return }
                self.showConversation?(snapshot)
            } catch let error as ClientError where error.serverCode == .unsupported {
                self?.showNotice("This server can't fork from an earlier message. Update Tab on it, then restart it.", kind: .warning)
            } catch {
                self?.showNotice("Couldn't fork: " + error.localizedDescription, kind: .warning)
            }
        }
    }

    /// Puts a sent message's text in the composer to edit and send as a new prompt. It
    /// never rewinds the conversation, and adds to a draft rather than replacing it.
    func editAsNewPrompt(_ item: AgentChatItem) {
        guard !disposed, !restoringDraft, item.kind == .user, !item.text.isEmpty else { return }
        let editor = surface.composer
        let separator = editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
        if separator.isEmpty { editor.string = "" }
        editor.insertText(separator + item.text, replacementRange: NSRange(location: editor.textStorage?.length ?? 0, length: 0))
        lastSubmission = nil
        surface.refreshComposer()
        saveDraft()
        updateControls()
        focusContent()
    }

    /// Says once per connection when the server runs an older Tab than this app: `tabd`
    /// outlives app updates, so newer agent features stay missing until it restarts.
    private func noteOlderServer() {
        guard !checkedServerVersion, let server = serverVersion?() else { return }
        checkedServerVersion = true
        guard let text = Self.olderServerNotice(server: server, app: appVersion) else { return }
        showNotice(text, kind: .warning)
    }

    /// The notice for a server running `server` under an app running `app`, or nil when
    /// the server is as new as the app.
    static func olderServerNotice(server: String, app: String) -> String? {
        guard ReleaseVersion.isNewer(app, than: server) else { return nil }
        // Running agents arrived in 0.93.0; name them when that is what is missing.
        let missing = ReleaseVersion.isNewer("0.93.0", than: server) ? "running agents" : "an agent's steps and finished agents"
        return "This server runs Tab \(server), older than this app (\(app)). Newer agent features, such as \(missing), "
            + "won't appear until it restarts. Restarting the server ends its running terminals and agents."
    }

    /// Opens an agent's own steps in a window of their own, or brings it forward.
    func openSubagentSteps(_ agent: AgentSubagent) {
        guard !disposed, let toolUseID = agent.toolUseID, let request = conversationRequest else { return }
        if let existing = subagentWindows[toolUseID] { existing.update(agent); existing.showWindow(nil); return }
        let session = session
        let window = AgentSubagentStepsWindow(subagent: agent, toolUseID: toolUseID, theme: surface.theme) { id in
            do {
                guard case .subagentSteps(let steps) = try await request(.subagentSteps(session: session, toolUseID: id)) else {
                    throw ModelError("The server sent an unexpected reply.")
                }
                return steps
            } catch let error as ClientError where error.serverCode == .unsupported {
                throw ModelError("This server can't show an agent's steps. Update Tab on it, then restart it.")
            }
        }
        window.onClose = { [weak self] in self?.subagentWindows.removeValue(forKey: toolUseID) }
        subagentWindows[toolUseID] = window
        window.showWindow(nil)
    }

    private func refreshReviewComments() {
        for controller in checkpointWindows.values {
            controller.reviewComments = reviewComments.filter { $0.checkpoint == controller.checkpointID }
        }
    }

    func focusContent() {
        view.window?.makeFirstResponder(surface.composer)
    }
    func didShow() { refresh() }
    func didHide() { voice.stop() } // Keep the draft and scroll position when switching projects.

    func willClose() async -> Bool {
        guard submitting || snapshot?.status == .working || snapshot?.status == .waiting || snapshot?.queuedPrompts?.isEmpty == false || snapshot?.subagents?.contains(where: { $0.status == .running }) == true else { return true }
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
        historyPicker?.close()
        queueEditor?.close()
        surface.closeOutline()
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
        for window in Array(subagentWindows.values) { window.close() }
        subagentWindows.removeAll()
        disposed = true
        approvalToken = nil
        refreshTask?.cancel()
        commandTask?.cancel()
        stopTask?.cancel()
        historyTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
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
        noticeExpiry?.cancel()
    }

    func connectionChanged() {
        guard !disposed else { return }
        connectionGeneration &+= 1
        checkedServerVersion = false
        readSinceUnsupported = false
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
                    var itemsUnchanged = false
                    let result: AgentChatSnapshot
                    if let (delta, unchanged) = try await self.readSince() {
                        result = delta
                        itemsUnchanged = unchanged
                    } else {
                        result = try await self.request(self.created
                            ? .read(session: self.session)
                            : .create(session: self.session, project: self.project, provider: self.provider))
                    }
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
                    self.accept(result, generation: generation, authoritative: true, itemsUnchanged: itemsUnchanged)

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
            self?.dismissNotice()
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

    func approve(_ id: String, allow: Bool, always: Bool = false, reason: String? = nil) {
        guard !disposed, !needsAuthoritativeSnapshot, !approvalInFlight, commandTask == nil, snapshot?.items.contains(where: {
            $0.id == id && $0.kind == .approval && !$0.isComplete
        }) == true else { return }
        run(.approve(session: session, request: id, allow: allow, always: always ? true : nil, reason: reason))
    }

    /// Asks for a denial's reason in a sheet; nil when the user cancels.
    var askDenialReason: ((String) async -> String?)?

    func choose(_ choice: AgentApprovalChoice, approval id: String) {
        switch choice {
        case .allowAlways: approve(id, allow: true, always: true)
        case .denyWithReason:
            let tool = snapshot?.items.first { $0.id == id }?.text ?? "this tool"
            Task { [weak self] in
                guard let self, let reason = await self.denialReason(tool), !self.disposed else { return }
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                self.approve(id, allow: false, reason: trimmed.isEmpty ? nil : trimmed)
            }
        }
    }

    private func denialReason(_ tool: String) async -> String? {
        if let askDenialReason { return await askDenialReason(tool) }
        guard let window = surface.window else { return nil }
        let alert = NSAlert()
        alert.window.appearance = surface.theme.nsAppearance
        alert.messageText = "Deny \(tool)?"
        alert.informativeText = "Tell the agent why, so it can try another way."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Reason"
        alert.accessoryView = field
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn ? field.stringValue : nil) }
        }
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

    /// A paste this long goes in as a text file, so the draft stays readable and editable.
    static let longPasteCharacters = 10_000
    static let longPasteLines = 200

    func attachLongPaste(_ text: String) -> Bool {
        let lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        guard !disposed, text.count >= Self.longPasteCharacters || lines >= Self.longPasteLines else { return false }
        addAttachments([AgentDraftAttachment(name: "Pasted text (\(lines) lines).txt", mimeType: "text/plain", data: Data(text.utf8))])
        showNotice("The long paste was attached as a text file.", kind: .info)
        return true
    }

    /// The project's folder when it's on this Mac, so its files can be named rather than copied.
    var localProjectRoot: String?

    func attachFiles(_ urls: [URL]) {
        guard !disposed, !urls.isEmpty else { return }
        let split = Self.splitProjectFiles(urls, root: localProjectRoot)
        if !split.mentions.isEmpty {
            // The agent reads a project file itself; naming it keeps the prompt small and current.
            let composer = surface.composer
            let text = split.mentions.map { $0.contains(where: \.isWhitespace) ? "@\"\($0)\"" : "@" + $0 }.joined(separator: " ")
            let range = composer.selectedRange()
            let before = range.location > 0 ? (composer.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) : ""
            composer.insertText((before.isEmpty || before == " " || before == "\n" ? "" : " ") + text + " ", replacementRange: range)
            saveDraft()
            updateControls()
        }
        let attach = split.attachments
        guard !attach.isEmpty else { return }
        prepareAttachments { try await AgentAttachmentImporter.load(urls: attach) }
    }

    /// Files inside `root` that aren't images become `@path` mentions; the rest are attached.
    static func splitProjectFiles(_ urls: [URL], root: String?) -> (mentions: [String], attachments: [URL]) {
        guard let root, root != "/" else { return ([], urls) }
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        var mentions: [String] = [], attachments: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            let image = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            if path.hasPrefix(base + "/"), !image, exists, !directory.boolValue {
                mentions.append(String(path.dropFirst(base.count + 1)))
            } else { attachments.append(url) }
        }
        return (mentions, attachments)
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
        dismissNotice()
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
        showNotice(message, kind: .warning)
    }

    /// Replaces the composer's notice. An informational one leaves by itself after
    /// `infoNoticeLifetime`, through a one-shot task rather than a timer.
    func showNotice(_ text: String, kind: AgentComposerNotice.Kind) {
        let shown = AgentComposerNotice(text: text, kind: kind)
        notice = shown
        noticeExpiry?.cancel()
        noticeExpiry = nil
        if kind == .info {
            let lifetime = infoNoticeLifetime
            noticeExpiry = Task { [weak self] in
                do { try await Task.sleep(for: lifetime) } catch { return }
                guard let self, self.notice == shown else { return }
                self.noticeExpiry = nil
                self.dismissNotice()
            }
        }
        updateControls()
    }

    func dismissNotice() {
        noticeExpiry?.cancel()
        noticeExpiry = nil
        guard notice != nil else { return }
        notice = nil
        updateControls()
    }

    private func performComposerAction(_ action: String) {
        let control: NSControl?
        switch action {
        case "skills": composerCoordinator.browseSkills(); return
        case "status":
            showNotice("\(selection.provider.name) · \(effectiveModel ?? "Provider default") · \(reasoningEffort?.title ?? "Auto") · \((snapshot?.accessMode ?? .standard).title)", kind: .info)
            return
        case "new", "clear-conversation": onNewConversation?(); return
        case "resume": showHistory(); return
        case "outline": surface.showOutline(); return
        case "plan": togglePlanMode(); return
        case "copy": copyConversation(); return
        case "previous-prompt": surface.navigatePrompt(previous: true); return
        case "next-prompt": surface.navigatePrompt(previous: false); return
        case "model", "effort": control = surface.modelPicker
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

    func showHistory() {
        guard !disposed, historyTask == nil, let loadHistory else { return }
        errorMessage = nil
        dismissNotice()
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

    private func presentHistory(_ reply: AgentHistoryReply) {
        historyPicker?.close()
        let picker = AgentSearchPicker(title: "Continue conversation", placeholder: "Search titles or providers…", theme: surface.theme)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        picker.update(reply.entries.map { entry in
            .init(id: entry.id, title: entry.title, detail: entry.provider.name + " · " + formatter.localizedString(for: entry.updatedAt, relativeTo: Date()))
        }, note: reply.truncated ? "Showing the newest 200 conversations. Older results were omitted by the server."
            : reply.entries.isEmpty ? "No other saved conversations in this folder." : "Conversations saved for this folder")
        picker.onSelect = { [weak self] id in
            guard let entry = reply.entries.first(where: { $0.id == id }) else { return }
            self?.resumeHistory(entry)
        }
        picker.onClose = { [weak self] in self?.historyPicker = nil }
        historyPicker = picker
        picker.present(in: surface.window)
    }

    private func resumeHistory(_ entry: AgentHistoryEntry) {
        guard !disposed, historyTask == nil, let importHistory else { return }
        // An unused pane takes the conversation over; otherwise it opens beside this one.
        let unused = created && !submitting && commandTask == nil && snapshot.map {
            $0.items.isEmpty && $0.providerSession == nil && $0.status == .idle
        } == true
        let target = unused ? session : SessionId()
        let generation = connectionGeneration
        errorMessage = nil
        dismissNotice()
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

    /// The conversation from only what changed since the snapshot this pane holds, or nil
    /// when a full read is needed: nothing held yet, a reconnect, a server that predates
    /// incremental reads, or a reply that doesn't fit what this pane holds.
    private func readSince() async throws -> (AgentChatSnapshot, itemsUnchanged: Bool)? {
        guard created, !needsAuthoritativeSnapshot, !readSinceUnsupported, let base = snapshot,
              let conversationRequest else { return nil }
        let reply: AgentConversationReply
        do {
            reply = try await conversationRequest(.readSince(session: session, revision: base.revision))
        } catch let error as ClientError where error.serverCode == .unsupported {
            readSinceUnsupported = true
            return nil
        }
        guard case .delta(let delta) = reply, let applied = delta.applied(to: base),
              (try? applied.validate()) != nil else { return nil }
        return (applied, delta.snapshot.items.isEmpty && delta.itemIDs.count == base.items.count
                    && zip(delta.itemIDs, base.items).allSatisfy { $0 == $1.id })
    }

    private func accept(_ result: AgentChatSnapshot, generation: UInt64, authoritative: Bool = false, itemsUnchanged: Bool = false) {
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
        surface.render(displayed(result), itemsUnchanged: itemsUnchanged)
        for (toolUseID, window) in subagentWindows {
            if let agent = result.subagents?.first(where: { $0.toolUseID == toolUseID }) { window.update(agent) }
        }
        if authoritative {
            surface.actions.project?.refreshProjectMetadata()
            noteOlderServer()
        }
        updateControls()
        if stopRequested && (result.status == .working || result.status == .waiting || hasActiveQueue) { stop() }
        titleDidChange?()
        onTitleChange?(title)
    }

    private func showError(_ error: Error) {
        // Refreshing can't fix an old server, and the next snapshot shouldn't hide that.
        if (error as? ClientError)?.serverCode == .unsupported {
            showNotice("This server does not support that action. Update Tab on the server, then reconnect. Your draft is retained.", kind: .warning)
            return
        }
        errorMessage = error.localizedDescription
        updateControls()
    }

    private var hasActiveQueue: Bool { snapshot?.hasActiveQueue == true }

    /// Where Up and Down are in the sent prompts, newest first, and the text they put in
    /// the composer; editing that text ends the walk.
    private var recall: (index: Int, text: String)?

    /// Up in an empty composer brings back the previous prompt, and again the one before;
    /// Down walks forward and past the newest clears the composer. False lets the key go on.
    func recallPrompt(older: Bool) -> Bool {
        let composer = surface.composer
        let walking = recall.map { composer.string == $0.text } ?? false
        guard walking || (older && composer.string.isEmpty && draftAttachments.isEmpty) else { recall = nil; return false }
        let prompts = (snapshot?.items ?? []).reversed().filter { $0.kind == .user && !$0.isProviderTurn && !$0.text.isEmpty }.map(\.text)
        let next = (recall?.index ?? -1) + (older ? 1 : -1)
        if next < 0 {
            recall = nil
            composer.string = ""
        } else {
            guard prompts.indices.contains(next) else { return true }
            recall = (next, prompts[next])
            composer.string = prompts[next]
            composer.setSelectedRange(NSRange(location: (prompts[next] as NSString).length, length: 0))
        }
        surface.refreshComposer()
        saveDraft()
        updateControls()
        return true
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
        surface.subagents.update(snapshot?.subagents ?? [])
        surface.questions.update(snapshot?.items.first { $0.questionnaire != nil && !$0.isComplete }, enabled: interactionsEnabled)
        surface.questions.restore(questionDrafts)
        // Plan mode is always reachable: the chip turns it on as well as off.
        let planning = snapshot?.planMode == true
        surface.plan.isHidden = snapshot == nil || snapshot?.status == .closed
        surface.plan.active = planning
        surface.plan.setAccessibilityLabel(planning ? "Disable plan mode" : "Enable plan mode")
        surface.plan.toolTip = (planning ? "Plan mode is on" : "Plan mode: plan before changing anything")
            + (keyDisplay?(.toggleAgentPlan).map { " · \($0) to toggle" } ?? "")
        surface.composer.planning = snapshot?.planMode == true
        surface.composer.isEditable = !disposed && !restoringDraft
        surface.attach.isEnabled = !disposed && !restoringDraft
        surface.microphone.isEnabled = !disposed && !restoringDraft && snapshot?.status != .closed
        surface.microphone.toolTip = voice.state == .idle ? "Dictate a message on this Mac" : "Finish dictation"
        surface.dictating = voice.state != .idle
        surface.send.isEnabled = canSendDraft
        surface.stop.isEnabled = !disposed && !needsAuthoritativeSnapshot && stopTask == nil && !stopRequested &&
            (submitting || snapshot?.status == .working || snapshot?.status == .waiting || hasActiveQueue)
        surface.stop.toolTip = "Stop this turn" + (keyDisplay?(.stopAgent).map { " (\($0))" } ?? "")
        let busy = submitting || snapshot?.status == .working || snapshot?.status == .waiting || hasActiveQueue
        surface.send.toolTip = busy
            ? "Queue this prompt for the next response"
            : "Send message"
        surface.model.isEnabled = canEditSelection && !needsAuthoritativeSnapshot
        surface.effort.isEnabled = surface.model.isEnabled && !supportedEfforts.isEmpty
        surface.contextIndicator.update(usedTokens: snapshot?.contextUsage?.usedTokens,
                                        contextWindow: snapshot?.contextUsage?.contextWindow)
        let canCompact = composerCoordinator.providerCommands.contains("compact") && snapshot?.status == .idle && commandTask == nil
        surface.contextIndicator.onCompact = canCompact ? { [weak self] in self?.compactConversation() } : nil
        surface.setActivity(status: snapshot?.status ?? .idle, submitting: submitting)
        updateSelectionMenus()
        surface.setApprovalsEnabled(!approvalInFlight && commandTask == nil && !disposed && !needsAuthoritativeSnapshot)
        surface.feedback.stringValue = errorMessage ?? notice?.text ?? statusText
        surface.feedback.toolTip = surface.feedback.stringValue
        surface.feedback.setAccessibilityValue(surface.feedback.stringValue)
        surface.retry.isHidden = errorMessage == nil
        surface.dismissNotice.isHidden = errorMessage != nil || notice == nil
        let retryable = retryableTurnItem
        surface.retryTurn.isHidden = errorMessage != nil || notice != nil || retryable == nil
        let blockedRetry = retryable.flatMap { item in unretryable?.item == item.id ? unretryable?.reason : nil }
        surface.retryTurn.isEnabled = retryTask == nil && commandTask == nil && canSend && blockedRetry == nil
        surface.retryTurn.toolTip = blockedRetry ?? "Send that prompt again as a new message"
        surface.newConversation.isHidden = errorMessage != nil || notice != nil || snapshot?.status != .closed || onNewConversation == nil
        surface.refreshComposer()
        surface.needsLayout = true
    }

    /// Where the words being dictated sit in the composer, replaced as recognition refines them.
    private var dictation: (range: NSRange, text: String)?

    /// Shows dictated words in the composer as they're recognized, then keeps the final ones.
    func placeDictation(_ text: String, final: Bool) {
        guard !disposed else { return }
        let composer = surface.composer
        let length = composer.textStorage?.length ?? 0
        let range: NSRange
        let replacement: String
        if let dictation, NSMaxRange(dictation.range) <= length,
           (composer.string as NSString).substring(with: dictation.range) == dictation.text {
            range = dictation.range
            replacement = (dictation.text.hasPrefix(" ") ? " " : "") + text
        } else {
            // A first result, or the user changed the composer meanwhile: add at the end.
            range = NSRange(location: length, length: 0)
            replacement = (composer.string.isEmpty || composer.string.hasSuffix(" ") || composer.string.hasSuffix("\n") ? "" : " ") + text
        }
        composer.insertText(replacement, replacementRange: range)
        dictation = final ? nil : (NSRange(location: range.location, length: (replacement as NSString).length), replacement)
        saveDraft()
        updateControls()
    }

    private var statusText: String {
        if voice.state == .authorizing { return "Waiting for microphone and speech permission…" }
        if voice.state == .listening {
            let left = max(0, Int((voice.stopsAt?.timeIntervalSinceNow ?? 0).rounded(.up)))
            return "Listening… \(left) s left. Click the microphone to finish and review your message."
        }
        if preparingAttachments > 0 { return "Preparing attachments…" }
        if historyTask != nil { return "Looking through past conversations…" }
        if needsAuthoritativeSnapshot { return "Reconnecting… Your transcript and draft are kept here." }
        if submitting { return "" }
        switch snapshot?.status {
        case .working, .waiting: return ""
        case .closed: return "This conversation has ended."
        // A turn cut short by a server restart says so in the conversation; it didn't fail.
        case .failed: return snapshot?.turns?.last?.outcome == .interrupted ? "Interrupted" : "Turn failed · Change the model or try again"
        case .idle: return retryableTurnItem != nil ? "Stopped" : ""
        case nil: return "Connecting…"
        }
    }

    private var canSendDraft: Bool {
        !approvalInFlight && !disposed && created && commandTask == nil && canSend && preparingAttachments == 0
            && (!surface.composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty)
    }

    func textDidChange(_ notification: Notification) {
        saveDraft()
        // A keystroke changes only what depends on the draft; the conversation's own
        // controls wait for the conversation to change.
        surface.send.isEnabled = canSendDraft
        surface.refreshComposer()
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
    /// While a turn runs, its provider may name its conversation at any moment.
    private var canChangeProvider: Bool {
        snapshot?.providerSession == nil && snapshot?.status != .working && snapshot?.status != .waiting
    }

    /// The model and effort can change at any time: a choice made while the agent works
    /// applies to the next prompt, including one sent to the queue now.
    private var canEditSelection: Bool {
        !disposed && commandTask == nil && snapshot != nil && snapshot?.status != .closed
    }

    /// Agents still running in Claude's process, which a model or effort change ends.
    private var runningSubagents: Int { snapshot?.subagents?.filter { $0.status == .running }.count ?? 0 }

    /// Asks before a choice that restarts Claude while it runs agents; nil asks with a sheet.
    var confirmAgentRestart: ((Int) async -> Bool)?

    private func confirmingRestart(_ apply: @escaping () -> Void) {
        let running = runningSubagents
        guard running > 0, snapshot?.provider == .claude, snapshot?.providerSession != nil else { apply(); return }
        Task { [weak self] in
            guard let self else { return }
            let confirmed = await (self.confirmAgentRestart ?? self.presentRestartConfirmation)(running)
            guard confirmed, !self.disposed else { self.menuState = nil; self.updateControls(); return }
            apply()
        }
    }

    private func presentRestartConfirmation(_ running: Int) async -> Bool {
        guard let window = surface.window else { return true }
        let alert = NSAlert()
        alert.window.appearance = surface.theme.nsAppearance
        alert.messageText = running == 1 ? "Stop the running agent?" : "Stop \(running) running agents?"
        alert.informativeText = "Claude restarts with the new model or reasoning effort on your next message, which stops the agents it is running in the background."
        alert.addButton(withTitle: "Change and Stop Agents")
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    func selectModel(provider: TabCore.AgentChatProvider, model: String?) {
        // A picker opened while idle can finish during reconnection. Keep that
        // choice as a local draft until an authoritative snapshot arrives.
        guard canEditSelection,
              canChangeProvider || provider == snapshot?.provider else { return }
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = AgentModelSelection(provider: provider, model: trimmed?.isEmpty == false ? trimmed : nil)
        guard chosen != selection else { return applyModel(chosen) }
        confirmingRestart { [weak self] in self?.applyModel(chosen) }
    }

    private func applyModel(_ chosen: AgentModelSelection) {
        selection = chosen
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
        guard effort != reasoningEffort else { return applyEffort(effort) }
        confirmingRestart { [weak self] in self?.applyEffort(effort) }
    }

    private func applyEffort(_ effort: AgentReasoningEffort?) {
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
        let pagesUp = [#selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:))].contains(commandSelector)
        let pagesDown = [#selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:))].contains(commandSelector)
        if pagesUp || pagesDown {
            surface.scrollTranscriptPage(up: pagesUp)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) || commandSelector == #selector(NSResponder.moveDown(_:)),
           !textView.hasMarkedText(), recallPrompt(older: commandSelector == #selector(NSResponder.moveUp(_:))) { return true }
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        guard !textView.hasMarkedText() else { return false }
        if NSEvent.modifierFlags.contains(.shift) { return false }
        send()
        return true
    }
}

/// A composer message with its own lifetime: snapshots leave it alone, the user can
/// dismiss it, and an informational one goes away by itself.
struct AgentComposerNotice: Equatable {
    enum Kind: Equatable { case warning, info }
    var text: String
    var kind: Kind
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
                self.reviewComments = draft.reviewComments ?? []
                self.refreshReviewComments()
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
                               submission: lastSubmission, answers: questionDrafts, reviewComments: reviewComments)
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
        guard commandTask == nil, queueEditor == nil, let window = surface.window else { return }
        let editor = AgentTextEditorSheet(title: "Edit queued prompt",
            detail: prompt.state == .uncertain
                ? "The earlier delivery may have reached the agent. Editing does not send it again. Attachments stay with the prompt."
                : "Attachments stay with this prompt. Saving does not send it immediately.",
            text: prompt.text, theme: surface.theme, showsSettings: true)
        queueEditor = editor
        editor.present(in: window) { [weak self] response, text, useSettings in
            guard let self else { return }
            self.queueEditor = nil
            guard response == .alertFirstButtonReturn, !self.disposed else { return }
            self.run(.editQueued(session: self.session, id: prompt.id, text: text, expectedRevision: prompt.revision,
                settings: useSettings ? .init(model: self.effectiveModel, effort: self.reasoningEffort, planMode: self.snapshot?.planMode == true) : nil))
        }
    }
    private func deliverQueued(_ prompt: AgentQueuedPrompt) {
        guard commandTask == nil else { return }
        guard prompt.state == .uncertain || prompt.state == .failed else {
            run(.deliverQueued(session: session, id: prompt.id, expectedRevision: prompt.revision))
            return
        }
        // A sheet on the pane's window, so other windows stay usable while it asks.
        Task { [weak self] in
            guard let self, await self.confirm("Send this prompt again?",
                "The previous delivery may have reached the agent. Review the conversation first; sending again can repeat its actions.",
                "Send Again"), !self.disposed else { return }
            self.run(.deliverQueued(session: self.session, id: prompt.id, expectedRevision: prompt.revision))
        }
    }
}
