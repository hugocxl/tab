import AppKit
import Combine
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
        snapshot?.items.first(where: { $0.kind == .user && !$0.isAutomaticTurn })?.text
            .split(whereSeparator: \.isNewline).first.map { String($0.prefix(160)) } ?? "Agent"
    }
    /// The provider's logo, as a terminal running the same agent shows it.
    var icon: NSImage? {
        AgentLogo.image(for: selection.provider.activityProvider, lightBackground: AppTheme.shared.palette.isLight)
    }
    /// Keeps the pane's saved title in step with the conversation, for the
    /// tab title, sidebar filter and palette.
    var onTitleChange: ((String) -> Void)?
    private let voice = AgentVoice()
    private var draftStore: AgentDraftStore?
    /// Imports, stashed drafts, queued-prompt edits and Send Now, kept apart from the conversation.
    let composerWork = AgentComposerWork()
    private var draftRestoreTask: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private var draftRevision: UInt64 = 0
    private(set) var restoringDraft = false
    var lastSubmission: AgentPrompt?
    var reviewComments: [AgentReviewComment] = []
    private var questionDrafts: [String: [String: [String]]] = [:]
    private var initialPreferences: AgentComposerPreferences?
    private var savePreferences: ((AgentComposerPreferences?) -> Void)?
    private func persistSelection(access: AgentAccessMode? = nil) {
        savePreferences?(.init(provider: selection.provider, providerID: selection.providerID, model: selection.model,
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
    private var exportTask: Task<Void, Never>?
    private var helpPicker: AgentSearchPicker?
    private var discoveredCommands: [TabCore.AgentChatProvider: [AgentCommandDescriptor]] = [:]
    private var historyTask: Task<Void, Never>?
    private var historyPicker: AgentSearchPicker?
    var titleDidChange: (() -> Void)?

    let request: (AgentChatRequest) async throws -> AgentChatSnapshot
    private let attachmentCache = AgentAttachmentCache()
    private var filePreview: AgentFilePreviewWindow?
    private var mediaPreview: AgentMediaPreviewWindow?
    private var toolDiffWindows: [String: (activity: AgentToolActivity, window: AgentCheckpointDiffWindow)] = [:]
    private(set) var checkpointWindows: [String: AgentCheckpointDiffWindow] = [:]
    var loadCheckpoint: AgentCheckpointDiffWindow.Fetch?
    /// Conversation requests that reply with something other than the snapshot.
    var conversationRequest: ((AgentConversationRequest) async throws -> AgentConversationReply)? {
        didSet { updateEarlierLoader(); connectArchiveFind() }
    }
    /// Archived items loaded above the retained ones; see `AgentEarlierTimeline`.
    private(set) var earlier = AgentEarlierTimeline()
    var earlierItems: [AgentChatItem] { earlier.items }
    /// The server can't page its archive: it predates paging, or kept nothing.
    private var earlierUnavailable = false
    private(set) var earlierTask: Task<Void, Never>?
    /// Find's search of the server's archive, and loading an archived match to show it.
    var archiveSearchTask: Task<Void, Never>?
    var archiveRevealTask: Task<Void, Never>?
    /// Speaks approvals, failures and finished turns to VoiceOver.
    let announcer = AgentConversationAnnouncer()
    /// This connection's server can't answer incremental reads; it gets full ones.
    private var readSinceUnsupported = false
    private(set) var subagentWindows: [String: AgentSubagentStepsWindow] = [:]
    private var refreshTask: Task<Void, Never>?
    private(set) var commandTask: Task<Void, Never>?
    private var helpTask: Task<Void, Never>?
    private var approvalToken: UUID?
    private var approvalInFlight: Bool { approvalToken != nil }
    private var stopTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var rewindTask: Task<Void, Never>?
    /// The failed turn whose attachments could no longer be read, and why, so Retry stays off.
    private var unretryable: (item: String, reason: String)?
    private var refreshPending = false
    private(set) var created = false
    private(set) var disposed = false
    private var selectionEdited = false
    /// A message is on its way to the server, so the sidebar shows the pane working
    /// before the server says so.
    private(set) var submitting = false {
        didSet { if submitting != oldValue { onSubmittingChange?() } }
    }
    var onSubmittingChange: (() -> Void)?
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
        var handsOff: Bool
        var resolvedModel: String?
        var providers: [AgentProviderConfig]
        var health: [String: AgentProviderHealth]
    }
    private(set) var connectionGeneration: UInt64 = 0
    private(set) var needsAuthoritativeSnapshot = false
    private(set) var snapshot: AgentChatSnapshot?
    private var authoritativeProject: ProjectId?
    /// A failed request or lost connection; the next accepted snapshot clears it, and Refresh retries.
    private(set) var errorMessage: String?
    /// A composer message, such as a validation hint or `/status`, that snapshots leave alone.
    private(set) var notice: AgentComposerNotice?
    private var noticeExpiry: Task<Void, Never>?
    /// How long an informational notice stays before it goes away by itself.
    var infoNoticeLifetime: Duration = .seconds(8)
    var draftAttachments: [AgentDraftAttachment] = []
    var attachmentTask: Task<Void, Never>?
    var preparingAttachments = 0
    private var attachmentPreview: NSPopover?
    private lazy var composerCoordinator = AgentComposerCoordinator(surface: surface)
    /// A provider's models as its menu offers them: the user's order, hidden ones left out.
    var loadModelCatalog: ((AgentProviderConfig, Bool) async throws -> AgentModelCatalogReply)?
    /// The server's providers with their last checks; servers that predate provider settings throw, leaving the built-in ones.
    var loadProviders: (() async throws -> AgentProvidersState)?
    /// Runs a command, such as a provider's sign-in, in a new terminal beside the pane.
    var openTerminal: ((String) -> Void)?
    /// Opens Settings › Agents on the pane's computer so the user can add or configure providers.
    var openAgentSettings: (() -> Void)?
    /// Opens Settings › Agents on the pane's computer with the Add Provider dialog.
    var addAgentProvider: (() -> Void)?
    /// Opens a provider's page in Settings › Agents on the pane's computer, to install or update its CLI.
    var openProviderSettings: ((String) -> Void)?
    /// The remote computer the pane runs on, by name; nil on this Mac.
    var computerName: (() -> String?)?
    /// The providers the model menu offers, from the server's settings.
    private var providers: [AgentProviderConfig] = []
    /// Whether the server's provider list has been loaded at least once.
    private var providersLoaded = false
    /// Observes app settings changes so provider edits in Settings › Agents refresh this pane.
    private var settingsObserver: AnyCancellable?
    /// What each provider's last check found, by provider ID.
    private var providerHealth: [String: AgentProviderHealth] = [:]
    /// The unavailable provider and reason the composer last warned about, so it warns once.
    private var announcedUnavailable: String?
    /// Each provider's models, by provider ID.
    private var modelCatalogs: [String: [AgentModelDescriptor]] = [:]
    private var modelCatalogTask: Task<Void, Never>?
    private var modelCatalogTaskID = UUID()
    private var modelCatalogLoadedAt = Date.distantPast
    private var unavailableModelCatalogs = Set<String>()
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
            if case .create(let session, _, let provider, _) = request {
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
                message: "Closing this pane stops its current work and cancels queued prompts. Prompts that may have reached the agent stay for review, and you can reopen the conversation from Continue Conversation.",
                confirm: "Close",
                destructive: true
            ) ?? true
        }
        configureDraftStore(model.dirs.root.appendingPathComponent("agent-drafts/" + pane.description + ".json"))
        onProviderChange = { [weak model] in model?.notify(.activity) }
        onSubmittingChange = { [weak model] in model?.notify(.activity) }
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
                                                             providerSession: entry.providerSession, providerID: entry.providerID))
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
            let generation = self.connectionGeneration
            let catalog = try await client.agentComposerContext(.init(project: project, provider: provider, forceRefresh: true))
            guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration,
                  self.selection.provider.rawValue == provider.rawValue else { throw CancellationError() }
            if let commands = catalog.commands { self.discoveredCommands[self.selection.provider] = commands; self.updateControls() }
            if catalog.truncated { self.showNotice("Some skills were omitted because of discovery or size limits. Provider commands remain available in /help.", kind: .warning) }
            else if let notice = catalog.discoveryNotice { self.showNotice(notice, kind: .warning) }
            return catalog.skills
        }
        loadModelCatalog = { [weak model] provider, forceRefresh in
            guard let model, let project = model.state.paneProject(pane), let client = model.sideClient(for: project) else {
                throw AgentPaneError.offline
            }
            return try await client.agentModelCatalog(.init(project: project, provider: provider.kind, forceRefresh: forceRefresh,
                                                            providerID: provider.id))
        }
        loadProviders = { [weak model] in
            guard let model, let project = model.state.paneProject(pane), let client = model.sideClient(for: project) else {
                throw AgentPaneError.offline
            }
            return try await client.agentProviders()
        }
        openTerminal = { [weak model] command in
            guard let model, let project = model.state.paneProject(pane) else { return }
            model.newTerminal(in: project, command: command)
        }
        let server = { [weak model] in model?.state.paneServer(pane) ?? .local }
        openAgentSettings = { [weak model] in
            model?.showAgentProvidersAction?(server(), nil)
        }
        addAgentProvider = { [weak model] in
            model?.addAgentProviderAction?(server())
        }
        openProviderSettings = { [weak model] provider in
            model?.showAgentProvidersAction?(server(), provider)
        }
        computerName = { [weak model] in model?.serverName(server()) }
        settingsObserver = model.changes.sink { [weak self] changes in
            guard changes.contains(.settings) else { return }
            self?.modelCatalogLoadedAt = .distantPast
            self?.refreshModelCatalog(force: false)
        }
    }

    func restorePreferences(defaults: AgentComposerPreferences?, draft: AgentComposerPreferences?,
                            save: @escaping (AgentComposerPreferences?) -> Void) {
        initialPreferences = draft ?? defaults
        savePreferences = save
        if let draft {
            selection = AgentModelSelection(provider: draft.provider, providerID: draft.providerID, model: draft.model)
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
        surface.configureProviders.onPress = { [weak self] in self?.setUpProviders() }
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
        surface.questions.onDecision = { [weak self] id, decision in
            guard let self, self.commandTask == nil else { return }
            self.decide(id, decision: decision)
        }
        surface.questions.onChange = { [weak self] in self?.saveDraft() }
        surface.plan.onPress = { [weak self] in self?.togglePlanMode() }
        surface.send.onPress = { [weak self] in self?.send() }
        surface.stop.onPress = { [weak self] in try? self?.surface.actions.interrupt() }
        surface.retry.onPress = { [weak self] in self?.refresh() }
        surface.retryTurn.onPress = { [weak self] in self?.retryLastTurn() }
        surface.resumeAtReset.onPress = { [weak self] in self?.toggleResumeAtReset() }
        surface.onEditPrompt = { [weak self] item in self?.chooseEdit(item) }
        surface.onRetryCheckpoint = { [weak self] turn in self?.retryCheckpoint(turn) }
        surface.onForkPrompt = { [weak self] item in self?.fork(before: item) }
        surface.onRevert = { [weak self] checkpoint, paths in self?.revertTurn(checkpoint, paths: paths) }
        surface.onShowFullOutput = { [weak self] item in self?.showFullOutput(item) }
        surface.onCopyConversation = { [weak self] in self?.copyConversation() }
        surface.newConversation.onPress = { [weak self] in self?.onNewConversation?() }
        surface.dismissNotice.onPress = { [weak self] in self?.dismissNoticePressed() }
        surface.composer.extraMenuItems = { [weak self] in self?.composerMenuItems() ?? [] }
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
        composerCoordinator.onCommand = { [weak self] in self?.executeLocalCommand($0) }
        composerCoordinator.onSubmit = { [weak self] in self?.send() }
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
    /// the transcript has the keyboard, the agent works, Stop shows (a draft must be sent
    /// or cleared first), and nothing else in the pane
    /// wants the key: the suggestion list, Find, the selection toolbar or an input method.
    /// False lets the key go on.
    func performKeyboardStop() -> Bool {
        guard let responder = surface.window?.firstResponder as? NSView,
              responder === surface.composer || responder === surface || responder.isDescendant(of: surface.transcriptScroll),
              surface.stop.isEnabled, !surface.stop.isHidden, surface.suggestions.isHidden, !surface.isFindOpen, surface.selectionToolbar.isHidden,
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
        if let request = pending.approval, !request.decisions.isEmpty {
            // Only when the request offers exactly that action; the key does nothing otherwise.
            guard let decision = AgentApprovalPresentation.shortcutDecision(request, allow: allow) else { return false }
            decide(pending.id, decision: decision.id)
            return true
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
              item.kind == .user, !item.isAutomaticTurn else { return nil }
        return item
    }

    /// Sends the failed or stopped turn's prompt again through the normal submit path, as
    /// a new prompt with its own identity, attachments and all. With `at`, the server holds
    /// it until then. When a retry is already scheduled, Retry sends that one now instead,
    /// so the prompt goes once.
    func retryLastTurn(at date: Date? = nil) {
        if date == nil, let scheduled = snapshot?.scheduledRetry {
            guard !disposed, commandTask == nil else { return }
            run(.deliverQueued(session: session, id: scheduled.id, expectedRevision: scheduled.revision))
            return
        }
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
                                     provider: self.selection.provider, providerID: self.selection.providerKey, planMode: self.snapshot?.planMode == true,
                                     attachments: attachments)
            self.composerCoordinator.dismiss()
            self.surface.scrollToEnd()
            if let date { self.run(.schedule(session: self.session, prompt: prompt, at: date)) }
            else { self.run(.submit(session: self.session, prompt: prompt)) }
        }
        updateControls()
    }

    /// The usage limit the last turn stopped at, while Retry can send its prompt again.
    var rateLimitStop: AgentRateLimitStop? {
        guard retryableTurnItem != nil, let turn = snapshot?.turns?.last, turn.outcome == .failed else { return nil }
        return turn.rateLimit
    }

    /// Resume at Reset schedules the retry; once scheduled, the same button cancels it.
    func toggleResumeAtReset() {
        if let scheduled = snapshot?.scheduledRetry {
            guard !disposed, commandTask == nil else { return }
            run(.removeQueued(session: session, id: scheduled.id, expectedRevision: scheduled.revision))
            return
        }
        guard let resets = rateLimitStop?.resetsAt, resets > Date() else { return }
        retryLastTurn(at: resets)
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
        if let reason = AgentRevertAvailability.reason(snapshot, submitting: submitting) {
            showNotice("Revert is unavailable. " + reason, kind: .warning)
            return
        }
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
                self.showNotice(AgentRevertAvailability.outcome(reply), kind: .info)
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
                                 provider: selection.provider, providerID: selection.providerKey, planMode: snapshot?.planMode == true)
        run(.submit(session: session, prompt: prompt))
    }

    /// The conversation as Markdown: each message under who said it, tool calls as one line each.
    static func markdown(_ snapshot: AgentChatSnapshot) -> String {
        let agent = snapshot.provider.name
        return snapshot.items.compactMap { item -> String? in
            switch item.kind {
            case .user where item.isAutomaticTurn: return "_\(item.text)_"
            case .user: return "**You**\n\n" + item.text + (item.attachments ?? []).map { "\n\nAttachment: " + $0.name }.joined()
            case .assistant: return "**\(agent)**\n\n" + item.text
            case .tool:
                guard let tool = item.tool else { return "> " + item.text + (item.detail.map { "\n\n" + $0 } ?? "") }
                let operation = tool.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return "> " + (tool.name ?? item.text) + (operation.isEmpty ? "" : " · `\(operation.replacingOccurrences(of: "`", with: "'"))`")
            case .notice: return "> " + item.text
            case .approval: return nil
            }
        }.joined(separator: "\n\n") + "\n"
    }

    func copyConversation() { exportConversation(saveFile: false) }

    private func exportConversation(saveFile: Bool, onSuccess: (() -> Void)? = nil) {
        guard exportTask == nil, let source = snapshot, !source.items.isEmpty else {
            showNotice("There are no messages to export.", kind: .info); return
        }
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { self.exportTask = nil }
            do {
                var earlier: [AgentChatItem] = []
                if (source.omittedItems ?? 0) > 0 {
                    guard let request = self.conversationRequest else { throw ModelError("Update the server to export earlier messages.") }
                    var before: Int?
                    repeat {
                        try Task.checkCancellation()
                        guard case .earlier(let page) = try await request(.earlier(session: self.session, before: before, limit: AgentEarlierItems.maxItems)) else {
                            throw ModelError("The server sent an unexpected archive reply.")
                        }
                        if let before, page.start >= before { throw ModelError("The history archive did not advance.") }
                        earlier = page.items + earlier
                        before = page.start
                    } while before != 0
                }
                guard !self.disposed, self.snapshot?.resetID == source.resetID else { return }
                var complete = source
                let retained = Set(source.items.map(\.id))
                complete.items = earlier.filter { !retained.contains($0.id) } + source.items
                var markdown = Self.markdown(complete)
                let missing = max(0, (source.omittedItems ?? 0) - earlier.count)
                if missing > 0 { markdown = "> \(missing) older messages were not retained by the server and cannot be exported.\n\n" + markdown }
                if saveFile {
                    guard let window = self.surface.window else { throw ModelError("Open this conversation in a window to save it.") }
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "Conversation.md"
                    let accepted = await withCheckedContinuation { continuation in
                        panel.beginSheetModal(for: window) { continuation.resume(returning: $0 == .OK) }
                    }
                    guard accepted, let url = panel.url else { return }
                    let data = Data(markdown.utf8)
                    try await Task.detached { try data.write(to: url, options: .atomic) }.value
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                }
                onSuccess?()
                self.showNotice(missing > 0 ? "Exported retained messages; the export identifies unavailable older history."
                    : saveFile ? "Saved the conversation as Markdown." : "Copied the complete conversation as Markdown.", kind: .info)
            } catch is CancellationError {} catch { self.showComposerError(error.localizedDescription) }
        }
    }

    /// The snapshot with any loaded earlier items above its own. Items the server trimmed
    /// since the pages loaded stay in place; a gap left by a reconnect is filled.
    /// `unchangedLead` counts the leading items that are those the previous result began with.
    private func displayed(_ result: AgentChatSnapshot) -> (snapshot: AgentChatSnapshot, unchangedLead: Int) {
        let shown = earlier.observe(result.items, turns: result.turns ?? [], omitted: result.omittedItems ?? 0, resetID: result.resetID)
        if earlier.needsGapFill, earlierTask == nil { loadEarlier() }
        updateEarlierLoader()
        guard earlier.isLoaded else { return (result, 0) }
        var snapshot = result
        snapshot.items = shown.items.items
        snapshot.omittedItems = shown.items.omitted
        if result.turns != nil || !shown.turns.isEmpty { snapshot.turns = shown.turns }
        return (snapshot, shown.unchangedLead)
    }

    /// Offers Show Earlier while the archive has more to load, or a gap to fill.
    private func updateEarlierLoader() {
        let available = conversationRequest != nil && !earlierUnavailable && (!earlier.isLoaded || earlier.canLoadMore)
        guard available != (surface.onLoadEarlier != nil) else { return }
        surface.onLoadEarlier = available ? { [weak self] in self?.loadEarlier() } : nil
    }

    /// Loads the page of archived items before those shown, or first fills a gap between
    /// them and the retained items. A page that arrives after the conversation trimmed
    /// more still applies: archive positions don't move until the conversation is cleared.
    func loadEarlier() {
        guard !disposed, earlierTask == nil, let request = conversationRequest, let snapshot else { return }
        let session = session
        let resetID = snapshot.resetID
        let gap = earlier.needsGapFill
        let before = earlier.olderCursor
        let omitted = snapshot.omittedItems ?? 0
        earlierTask = Task { [weak self] in
            defer {
                self?.earlierTask = nil
                // A gap opened while this page loaded; a failed fill waits for Show Earlier.
                if !gap, let self, !self.disposed, self.earlier.needsGapFill { self.loadEarlier() }
            }
            do {
                func page(before: Int?) async throws -> AgentEarlierItems {
                    guard case .earlier(let page) = try await request(.earlier(session: session, before: before, limit: AgentEarlierItems.maxItems)) else {
                        throw ModelError("The server sent an unexpected reply.")
                    }
                    try Task.checkCancellation()
                    return page
                }
                var pages: [AgentEarlierItems] = []
                if gap {
                    pages = [try await page(before: nil)]
                    while let last = pages.last, self?.earlier.gapReached(last) == false, pages.count < 64 {
                        pages.append(try await page(before: last.start))
                    }
                } else {
                    pages = [try await page(before: before)]
                }
                guard let self, !self.disposed else { return }
                if gap {
                    self.earlier.fillGap(pages, resetID: resetID)
                } else if let result = pages.first {
                    guard !result.items.isEmpty else {
                        self.earlierUnavailable = true
                        self.updateEarlierLoader()
                        self.showNotice("The earlier messages of this conversation weren't kept.", kind: .info)
                        return
                    }
                    guard self.earlier.accept(result, before: before, resetID: resetID, omittedWhenRequested: omitted) else { return }
                }
                if let current = self.snapshot { self.surface.render(self.displayed(current).snapshot) }
            } catch let error as ClientError where error.serverCode == .unsupported {
                self?.earlierUnavailable = true
                self?.updateEarlierLoader()
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

    /// Puts a sent message's text and attachments in the composer to edit and send as a new
    /// prompt. It never rewinds the conversation, and adds to a draft rather than replacing
    /// it. The text arrives at once; attachments as the server returns them, and any it no
    /// longer has are named.
    func editAsNewPrompt(_ item: AgentChatItem) {
        guard !disposed, !restoringDraft, item.kind == .user, !item.text.isEmpty || item.attachments?.isEmpty == false else { return }
        appendToDraft(item.text)
        guard item.attachments?.isEmpty == false else { return }
        let fetch = surface.fetchAttachment
        preparingAttachments += 1
        updateControls()
        Task { [weak self] in
            let restored = await AgentRestoredPrompt.load(item, fetch: fetch)
            guard let self else { return }
            self.preparingAttachments -= 1
            guard !self.disposed else { return }
            self.addRestoredAttachments(restored)
        }
    }

    private func appendToDraft(_ text: String) {
        guard !text.isEmpty else { return }
        let editor = surface.composer
        let separator = editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
        if separator.isEmpty { editor.string = "" }
        editor.insertText(separator + text, replacementRange: NSRange(location: editor.textStorage?.length ?? 0, length: 0))
        lastSubmission = nil
        surface.refreshComposer()
        saveDraft()
        updateControls()
        focusContent()
    }

    private func addRestoredAttachments(_ restored: AgentRestoredPrompt) {
        if !restored.attachments.isEmpty {
            lastSubmission = nil
            addAttachments(restored.attachments)
        } else { updateControls() }
        if let missing = restored.missingNotice { showNotice(missing, kind: .warning) }
    }

    /// Asks the user what an edit of a sent message should do; nil shows a menu at the pointer.
    var chooseEditMode: ((AgentChatItem, _ rewindUnavailable: String?) async -> AgentEditMode?)?
    /// Asks how to edit from here; nil asks with a sheet on the pane's window.
    var chooseRewind: ((AgentRewindPlan) async -> AgentRewindChoice?)?

    /// The pencil on a sent message: Edit as New Prompt, or, where the conversation can be
    /// rewound to it, Edit from Here.
    func chooseEdit(_ item: AgentChatItem) {
        guard !disposed, item.kind == .user else { return }
        let rewindUnavailable: String?
        switch rewindPlan(item) {
        case .success: rewindUnavailable = nil
        case .failure(let unavailable): rewindUnavailable = unavailable.reason
        }
        if let chooseEditMode {
            Task { [weak self] in
                switch await chooseEditMode(item, rewindUnavailable) {
                case .asNewPrompt: self?.editAsNewPrompt(item)
                case .fromHere: self?.editFromHere(item)
                case nil: break
                }
            }
            return
        }
        let menu = NSMenu()
        let asNew = NSMenuItem(title: "Edit as New Prompt", action: #selector(editMenuChosen(_:)), keyEquivalent: "")
        asNew.target = self
        asNew.representedObject = AgentEditMenuChoice(item: item, rewind: false)
        asNew.toolTip = "Put this message in the composer; the conversation stays as it is"
        menu.addItem(asNew)
        let fromHere = NSMenuItem(title: "Edit from Here…", action: rewindUnavailable == nil ? #selector(editMenuChosen(_:)) : nil, keyEquivalent: "")
        fromHere.target = self
        fromHere.representedObject = AgentEditMenuChoice(item: item, rewind: true)
        fromHere.isEnabled = rewindUnavailable == nil
        fromHere.toolTip = rewindUnavailable ?? "Go back to before this message and edit it; the whole conversation is kept in history"
        menu.addItem(fromHere)
        if let rewindUnavailable {
            let reason = NSMenuItem(title: rewindUnavailable, action: nil, keyEquivalent: "")
            reason.isEnabled = false
            menu.addItem(reason)
        }
        guard let window = surface.window else { editAsNewPrompt(item); return }
        let point = surface.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: surface)
    }

    @objc private func editMenuChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? AgentEditMenuChoice else { return }
        if choice.rewind { editFromHere(choice.item) } else { editAsNewPrompt(choice.item) }
    }

    private func rewindPlan(_ item: AgentChatItem) -> Result<AgentRewindPlan, AgentRewindUnavailable> {
        guard let snapshot else { return .failure(.init("The conversation isn't loaded yet.")) }
        guard conversationRequest != nil else { return .failure(.init("This connection can't rewind a conversation.")) }
        guard commandTask == nil, !submitting else { return .failure(.init("Wait for the current request to finish.")) }
        return AgentRewindPlan.make(snapshot, item: item)
    }

    /// Edit from Here: after the user sees which turns go and chooses whether to keep or
    /// restore their files, the server archives the whole conversation, puts files back if
    /// asked and rewinds it to before `item`; then the message joins the draft. Nothing
    /// changes until the server has done all of it, and a draft already there is kept.
    func editFromHere(_ item: AgentChatItem) {
        guard !disposed, let request = conversationRequest else { return }
        var plan: AgentRewindPlan
        switch rewindPlan(item) {
        case .success(let made): plan = made
        case .failure(let unavailable):
            showNotice("Edit from Here is unavailable. " + unavailable.reason, kind: .warning)
            return
        }
        let session = session, fetch = surface.fetchAttachment
        guard let revision = snapshot?.revision else { return }
        rewindTask?.cancel()
        rewindTask = Task { [weak self] in
            // The message's attachments are read first: once rewound, it is only in the archive.
            let restored = await AgentRestoredPrompt.load(item, fetch: fetch)
            plan.missingAttachments = restored.missing
            guard let self, !Task.isCancelled, !self.disposed else { return }
            defer { self.rewindTask = nil; self.updateControls() }
            guard let choice = await self.askRewind(plan), !self.disposed else { return }
            let archive = SessionId()
            do {
                var reply = try await Self.rewindReply(request, .rewind(session: session, at: item.id, archive: archive, revision: revision,
                                                                       restoreFiles: choice == .restoreFiles, force: false))
                if !reply.files.conflicts.isEmpty {
                    let list = reply.files.conflicts.prefix(8).joined(separator: "\n") + (reply.files.conflicts.count > 8 ? "\n…" : "")
                    guard !self.disposed, await self.confirm(
                        reply.files.conflicts.count == 1 ? "1 file changed after these turns" : "\(reply.files.conflicts.count) files changed after these turns",
                        "\(list)\n\nRestoring discards those later changes too.", "Restore Anyway") else { return }
                    reply = try await Self.rewindReply(request, .rewind(session: session, at: item.id, archive: archive, revision: revision,
                                                                       restoreFiles: true, force: true))
                }
                guard let rewound = reply.snapshot, !self.disposed else { return }
                let kept = Set((rewound.turns ?? []).compactMap { $0.checkpoint?.id })
                let comments = self.reviewComments.filter { kept.contains($0.checkpoint) }
                self.accept(rewound, generation: self.connectionGeneration)
                self.reviewComments = comments
                self.refreshReviewComments()
                self.appendToDraft(restored.text)
                self.addRestoredAttachments(restored)
                self.saveDraft(immediate: true)
                if restored.missing.isEmpty {
                    let files = reply.files.reverted.count
                    self.showNotice(files == 0 ? "Rewound. The message is in the composer; the earlier conversation is in history."
                        : "Rewound and restored \(files == 1 ? "1 file" : "\(files) files"). The message is in the composer.", kind: .info)
                }
            } catch let error as ClientError where error.serverCode == .unsupported {
                self.showNotice("This server can't rewind a conversation. Update Tab on it, then restart it. Nothing was changed.", kind: .warning)
            } catch {
                guard !self.disposed else { return }
                self.showNotice("Couldn't edit from here: " + error.localizedDescription, kind: .warning)
                self.refresh()
            }
        }
        updateControls()
    }

    private func askRewind(_ plan: AgentRewindPlan) async -> AgentRewindChoice? {
        if let chooseRewind { return await chooseRewind(plan) }
        guard let window = surface.window else { return nil }
        let alert = NSAlert()
        alert.window.appearance = surface.theme.nsAppearance
        alert.messageText = "Edit from this message?"
        alert.informativeText = plan.summary
        alert.addButton(withTitle: plan.canRestoreFiles ? "Rewind and Keep Files" : "Rewind").hasDestructiveAction = true
        if plan.canRestoreFiles { alert.addButton(withTitle: "Rewind and Restore Files").hasDestructiveAction = true }
        alert.addButton(withTitle: "Cancel")
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        switch response {
        case .alertFirstButtonReturn: return .keepFiles
        case .alertSecondButtonReturn where plan.canRestoreFiles: return .restoreFiles
        default: return nil
        }
    }

    private static func rewindReply(_ request: (AgentConversationRequest) async throws -> AgentConversationReply,
                                    _ body: AgentConversationRequest) async throws -> AgentRewindReply {
        guard case .rewound(let reply) = try await request(body) else { throw ModelError("The server sent an unexpected reply.") }
        return reply
    }

    /// Records a turn's file changes again, from where it began, after recording failed.
    func retryCheckpoint(_ turn: String) {
        guard !disposed, let request = conversationRequest else { return }
        let session = session, generation = connectionGeneration
        Task { [weak self] in
            do {
                guard case .snapshot(let snapshot) = try await request(.retryCheckpoint(session: session, turn: turn)) else {
                    throw ModelError("The server sent an unexpected reply.")
                }
                self?.accept(snapshot, generation: generation)
            } catch let error as ClientError where error.serverCode == .unsupported {
                self?.showNotice("This server can't record a turn's changes again. Update Tab on it, then restart it.", kind: .warning)
            } catch {
                guard let self, !self.disposed else { return }
                self.showNotice("Couldn't record the changes: " + error.localizedDescription, kind: .warning)
                self.refresh()
            }
        }
    }

    /// Opens an agent's own steps in a window of their own, or brings it forward.
    func openSubagentSteps(_ agent: AgentSubagent) {
        guard !disposed, let toolUseID = agent.toolUseID, let request = conversationRequest else { return }
        if let existing = subagentWindows[toolUseID] { existing.update(agent); existing.showWindow(nil); return }
        let session = session
        let window = AgentSubagentStepsWindow(subagent: agent, toolUseID: toolUseID, theme: surface.theme) { [weak self] id in
            do {
                guard case .subagentSteps(let steps) = try await request(.subagentSteps(session: session, toolUseID: id)) else {
                    throw ModelError("The server sent an unexpected reply.")
                }
                // A server that can't read a shell's output still has its tool row.
                if steps.items.isEmpty, agent.agentType == "Shell", let item = self?.snapshot?.items.last(where: { $0.id == id }) {
                    return AgentSubagentSteps(toolUseID: id, items: [item])
                }
                return steps
            } catch let error as ClientError where error.serverCode == .unsupported {
                throw ModelError("This server can't show an agent's steps. Update Tab on it, then restart it.")
            }
        } fetchEarlier: { id, before in
            guard case .earlier(let page) = try await request(.subagentEarlier(session: session, toolUseID: id, before: before,
                                                                                limit: AgentEarlierItems.maxItems)) else {
                throw ModelError("The server sent an unexpected reply.")
            }
            return page
        }
        window.onClose = { [weak self] in self?.subagentWindows.removeValue(forKey: toolUseID) }
        subagentWindows[toolUseID] = window
        window.showWindow(nil)
    }

    func refreshReviewComments() {
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
        cancelArchiveSearch(nil)
        historyPicker?.close()
        helpPicker?.close()
        helpTask?.cancel()
        exportTask?.cancel()
        composerWork.dispose()
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
        rewindTask?.cancel()
        retryTask = nil
        refreshTask = nil
        commandTask = nil
        stopTask = nil
        historyTask = nil
        submitting = false
        stopRequested = false
        invalidateDraftImports()
        attachmentPreview?.close()
        composerCoordinator.invalidate()
        modelCatalogTask?.cancel()
        noticeExpiry?.cancel()
    }

    func connectionChanged() {
        guard !disposed else { return }
        connectionGeneration &+= 1
        readSinceUnsupported = false
        approvalToken = nil
        modelCatalogTask?.cancel()
        modelCatalogTask = nil
        modelCatalogLoadedAt = .distantPast
        modelCatalogs = [:]
        unavailableModelCatalogs = []
        discoveredCommands = [:]
        menuState = nil
        composerCoordinator.invalidate()
        needsAuthoritativeSnapshot = true
        restartArchiveSearch(afterReset: false)
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
                            self.selection = AgentModelSelection(provider: defaults.provider, providerID: defaults.providerID,
                                                                 model: defaults.model)
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

    /// Sends the draft, or queues it while the agent works. `now` asks to steer it into
    /// the running turn instead, through the same queue identity; see `sendNow`.
    func send(now: Bool = false) {
        if composerCoordinator.performTypedAction() { return }
        guard !approvalInFlight else { return }
        let sentDraft = NSAttributedString(attributedString: surface.composer.attributedString())
        let text = AgentComposerCitation.prompt(from: sentDraft)
        guard !disposed, commandTask == nil, created, canSend,
              preparingAttachments == 0,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty else { return }
        if let command = AgentSlashCommand(text: text), !command.isPath {
            let provider = selection.provider
            let names = composerCoordinator.providerCommands + composerCoordinator.providerDescriptors.flatMap(\.names)
            if let error = command.validationError(provider: provider, commands: names,
                                                    hasAttachments: !draftAttachments.isEmpty, descriptors: composerCoordinator.providerDescriptors) {
                showComposerError(error); return
            }
            if snapshot?.status == .working || snapshot?.status == .waiting || hasActiveQueue {
                showComposerError("Run commands after active and queued work finishes."); return
            }
        }
        let attachments = draftAttachments.map { AgentChatAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, data: $0.data) }
        let sentIDs = Set(attachments.map(\.id))
        // The message shows these bytes at once, never downloading them back from the server.
        attachmentCache.seed(attachments)
        composerCoordinator.dismiss()
        surface.scrollToEnd()
        var prompt = AgentPrompt(text: text, model: selection.model, effort: reasoningEffort,
                                 provider: selection.provider, providerID: selection.providerKey, planMode: snapshot?.planMode == true, attachments: attachments)
        // A reconnect may update the displayed model or mode after acceptance.
        // Keep the original delivery identity until the user edits the payload or settings.
        if let previous = lastSubmission, previous.text == text, previous.attachments == attachments {
            prompt = previous
        }
        lastSubmission = prompt
        let steer: ((AgentChatSnapshot) -> AgentChatRequest?)? = now ? { [weak self] in self?.sendNowRequest(prompt.id, after: $0) } : nil
        run(.submit(session: session, prompt: prompt), onSuccess: { [weak self] in
            self?.lastSubmission = nil
            self?.dismissNotice()
            self?.saveDraft()
            self?.selectionEdited = false
            self?.savePreferences?(nil)
            if ["reload-skills", "reload-plugins"].contains(AgentSlashCommand(text: text)?.name ?? "") {
                self?.composerCoordinator.invalidate()
            }
            self?.draftAttachments.removeAll { sentIDs.contains($0.id) }
            self?.updateAttachments()
            // Don't lose edits typed while the request was in flight, or a failed send.
            guard let self, self.surface.composer.attributedString().isEqual(to: sentDraft) else { return }
            self.surface.composer.string = ""
            self.surface.refreshComposer()
            self.saveDraft()
        }, then: steer, onFollowUp: { [weak self] in self?.sendNowDispatched(prompt.id, $0) })
    }

    func approve(_ id: String, allow: Bool, always: Bool = false, reason: String? = nil) {
        guard !disposed, !needsAuthoritativeSnapshot, !approvalInFlight, commandTask == nil, snapshot?.items.contains(where: {
            $0.id == id && $0.kind == .approval && !$0.isComplete
        }) == true else { return }
        run(.approve(session: session, request: id, allow: allow, always: always ? true : nil, reason: reason))
    }

    /// Sends one of the decisions the request offered, exactly as offered.
    func decide(_ id: String, decision: String, answers: [String: [String]]? = nil) {
        guard !disposed, !needsAuthoritativeSnapshot, !approvalInFlight, commandTask == nil,
              let item = snapshot?.items.first(where: { $0.id == id && $0.kind == .approval && !$0.isComplete }),
              item.approval?.decision(decision) != nil else { return }
        run(.decide(session: session, request: id, decision: decision, answers: answers))
    }

    /// Asks for a denial's reason in a sheet; nil when the user cancels.
    var askDenialReason: ((String) async -> String?)?

    func choose(_ choice: AgentApprovalChoice, approval id: String) {
        switch choice {
        case .decision(let decision):
            decide(id, decision: decision)
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
        prepareAttachments { try await AgentAttachmentImporter.intake(urls: attach) }
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

    private func attachImage(_ data: Data, mimeType: String) {
        guard !disposed else { return }
        prepareAttachments {
            try await Task.detached(priority: .userInitiated) {
                try AgentAttachmentImporter.imageIntake(data: data, mimeType: mimeType)
            }.value
        }
    }

    /// Adds what fits; false, with the reason shown, when the draft's limits refuse them.
    @discardableResult
    func addAttachments(_ attachments: [AgentDraftAttachment]) -> Bool {
        let additions = attachments.filter { candidate in
            !draftAttachments.contains { $0.name == candidate.name && $0.data == candidate.data }
        }
        if let reason = attachmentCapacityError(adding: additions) {
            showComposerError(reason)
            return false
        }
        draftAttachments += additions
        dismissNotice()
        updateAttachments()
        return true
    }

    func updateAttachments() {
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

    func showComposerError(_ message: String) {
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

    private func executeLocalCommand(_ command: AgentSlashCommand) {
        guard !disposed else { return }
        let name = command.name, arguments = command.arguments
        let offlineActions: Set<String> = ["help", "status", "copy", "export", "outline", "previous-prompt", "next-prompt", "attach", "clear-draft", "stashes"]
        guard offlineActions.contains(name) || (!needsAuthoritativeSnapshot && created) else {
            showComposerError("Wait for the conversation to connect before running commands."); return
        }
        if name == "effort", !surface.effort.isEnabled { showComposerError("Reasoning effort is unavailable for this model."); return }
        if name == "model", !surface.model.isEnabled { showComposerError("Model selection is unavailable right now."); return }
        let idleOnly: Set<String> = ["clear", "plan", "fork"]
        if idleOnly.contains(name), approvalInFlight || commandTask != nil || snapshot?.status == .working || snapshot?.status == .waiting || hasActiveQueue {
            showComposerError("Stop active work and remove queued prompts before running /" + name + "."); return
        }
        if !arguments.isEmpty, !["model", "effort", "plan", "skills", "attach"].contains(name) {
            showComposerError("/" + name + " does not accept arguments."); return
        }
        let draft = surface.composer.string
        let consume: () -> Void = { [weak self] in
            guard let self, self.surface.composer.string == draft else { return }
            self.surface.composer.string = ""; self.surface.refreshComposer(); self.saveDraft(); self.updateControls()
        }
        switch name {
        case "clear":
            guard let snapshot, runningSubagents == 0 else { showComposerError("Stop background agents before clearing."); return }
            run(.clear(session: session, archive: SessionId(), expectedRevision: snapshot.revision)) { [weak self] in
                consume()
                self?.showNotice("Conversation cleared. The previous conversation is kept in history.", kind: .info)
            }
            return
        case "help":
            helpPicker?.close()
            helpTask?.cancel()
            let picker = AgentSearchPicker(title: "Agent commands", placeholder: "Search commands…", theme: surface.theme)
            let note = "Return runs a command; Tab completes it. Commands with arguments show their syntax. Skills: /skills."
            picker.update(composerCoordinator.helpEntries, note: "Loading provider commands…")
            picker.onSelect = { [weak self] command in
                self?.surface.composer.string = command + " "
                self?.surface.refreshComposer(); self?.saveDraft()
            }
            helpPicker = picker; picker.present(in: surface.window)
            helpTask = Task { [weak self, weak picker] in
                guard let self, let picker else { return }
                do {
                    try await self.composerCoordinator.refreshCatalog()
                    guard !self.disposed, self.helpPicker === picker else { return }
                    picker.update(self.composerCoordinator.helpEntries, note: note)
                } catch is CancellationError {} catch {
                    picker.update(self.composerCoordinator.helpEntries, note: "Could not refresh provider commands. " + error.localizedDescription)
                }
            }
        case "fork":
            Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.request(.fork(session: SessionId(), from: self.session, project: nil))
                    guard !self.disposed else { return }
                    consume(); self.showConversation?(result)
                } catch { self.showComposerError(error.localizedDescription) }
            }
            return
        case "copy", "export": exportConversation(saveFile: name == "export", onSuccess: consume); return
        case "stashes": consume(); showStashedDrafts(); return
        case "skills": composerCoordinator.browseSkills(); return
        case "attach":
            surface.composer.string = arguments
            surface.refreshComposer(); saveDraft()
            chooseAttachments(); return
        case "plan":
            guard arguments.isEmpty || ["on", "off"].contains(arguments) else { showComposerError("Use /plan, /plan on, or /plan off."); return }
            run(.setPlan(session: session, enabled: arguments.isEmpty ? snapshot?.planMode != true : arguments == "on"), onSuccess: consume)
            return
        case "model" where !arguments.isEmpty:
            guard !arguments.contains(where: \.isWhitespace) else { showComposerError("Use /model <model-name> or /model default."); return }
            selectModel(provider: selection.provider, model: arguments == "default" ? nil : arguments)
        case "effort" where !arguments.isEmpty:
            guard surface.effort.isEnabled else { showComposerError("Reasoning effort is unavailable for this model."); return }
            let effort = arguments == "auto" ? nil : AgentReasoningEffort(rawValue: arguments)
            guard arguments == "auto" || effort.map({ supportedEfforts.contains($0) }) == true else {
                showComposerError("Choose a supported effort: auto" + supportedEfforts.map { ", " + $0.rawValue }.joined()); return
            }
            selectEffort(effort)
        case "stop":
            guard snapshot?.status == .working || snapshot?.status == .waiting || hasActiveQueue || submitting else {
                showNotice("No response is running.", kind: .info); consume(); return
            }
            stop()
        default:
            performComposerAction(name)
        }
        consume()
    }

    private func performComposerAction(_ action: String) {
        let control: NSControl?
        switch action {
        case "skills": composerCoordinator.browseSkills(); return
        case "status":
            showNotice("\(selection.provider.name) · \(effectiveModel ?? "Provider default") · \(reasoningEffort?.title ?? "Auto") · \((snapshot?.accessMode ?? .standard).title) · Plan \(snapshot?.planMode == true ? "on" : "off") · \(snapshot?.status.rawValue ?? "connecting") · \(snapshot?.queuedPrompts?.count ?? 0) queued · \(snapshot?.contextUsage?.usedTokens.description ?? "Unknown") context tokens. Model and effort apply to the next message.", kind: .info)
            return
        case "new": onNewConversation?(); return
        case "clear-conversation": if let command = AgentSlashCommand(text: "/clear") { executeLocalCommand(command) }; return
        case "resume": showHistory(); return
        case "outline": surface.showOutline(); return
        case "plan": togglePlanMode(); return
        case "copy": copyConversation(); return
        case "previous-prompt", "next-prompt":
            let previous = action == "previous-prompt"
            if !surface.navigatePrompt(previous: previous) {
                if previous, (surface.snapshot?.omittedItems ?? 0) > 0 {
                    loadEarlier()
                    showNotice("Loading earlier prompts. Run /previous-prompt again to continue.", kind: .info)
                } else { showNotice(previous ? "You are at the first loaded prompt." : "You are at the last prompt.", kind: .info) }
            }
            return
        case "effort":
            guard surface.effort.isEnabled else { showComposerError("Reasoning effort is unavailable for this model or while reconnecting."); return }
            surface.modelPicker.showSelectionMenu(effortOnly: true); return
        case "model": control = surface.modelPicker
        case "attach": chooseAttachments(); return
        case "stop": stop(); return
        case "stashes": showStashedDrafts(); return
        case "clear-draft":
            // Imports still running belonged to the draft being cleared.
            invalidateDraftImports()
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
        let saved = reply.conversations ?? []
        let tabEntries: [AgentSearchPicker.Entry] = saved.map { conversation in
            .init(id: Self.savedConversationPrefix + conversation.session.description, title: conversation.title,
                  detail: AgentSavedConversationText.detail(conversation, formatter: formatter))
        }
        picker.update(tabEntries + reply.entries.map { entry in
            .init(id: entry.id, title: entry.title, detail: historySource(entry) + " · " + formatter.localizedString(for: entry.updatedAt, relativeTo: Date()))
        }, note: reply.truncated ? "Showing the newest 200 conversations. Older results were omitted by the server."
            : reply.entries.isEmpty && saved.isEmpty ? "No other saved conversations in this folder."
            : saved.isEmpty ? "Conversations saved for this folder" : "Closed Tab conversations first, then ones saved by the agents' own apps")
        picker.onSelect = { [weak self] id in
            if let conversation = saved.first(where: { Self.savedConversationPrefix + $0.session.description == id }) {
                self?.reopenConversation(conversation.session)
                return
            }
            guard let entry = reply.entries.first(where: { $0.id == id }) else { return }
            self?.resumeHistory(entry)
        }
        if !saved.isEmpty {
            picker.entryActions = { [weak self] id in
                guard let conversation = saved.first(where: { Self.savedConversationPrefix + $0.session.description == id }) else { return [] }
                return self?.savedConversationActions(conversation) ?? []
            }
        }
        picker.onClose = { [weak self] in self?.historyPicker = nil }
        historyPicker = picker
        picker.present(in: surface.window)
    }

    private static let savedConversationPrefix = "tab:"

    /// Who saved a past conversation: its provider's name, with the kind's when the name is the account's own.
    private func historySource(_ entry: AgentHistoryEntry) -> String {
        guard let config = providers.first(where: { $0.id == entry.providerID }), config.title != entry.provider.name else {
            return entry.provider.name
        }
        return "\(entry.provider.name) · \(config.title)"
    }

    /// Reopen, keep or delete a closed conversation: retention is the user's explicit choice,
    /// and deleting asks first.
    func savedConversationActions(_ conversation: AgentSavedConversation) -> [NSMenuItem] {
        var items: [NSMenuItem] = [ClosureMenuItem("Reopen") { [weak self] in
            self?.historyPicker?.close()
            self?.reopenConversation(conversation.session)
        }, .separator()]
        for days in AgentConversationRetention.choices {
            let retention = AgentConversationRetention(deleteAfterDays: days)
            let item = ClosureMenuItem(retention.title) { [weak self] in
                self?.historyPicker?.close()
                self?.conversationAction(.setRetention(session: conversation.session, retention: retention), doing: "change how long it is kept")
            }
            item.state = conversation.retention == retention ? .on : .off
            items.append(item)
        }
        items.append(.separator())
        items.append(ClosureMenuItem("Delete Permanently…") { [weak self] in
            guard let self else { return }
            self.historyPicker?.close()
            Task { [weak self] in
                guard let self else { return }
                let review = conversation.needsReview == true ? " Prompts in it that may have reached the agent are deleted too." : ""
                guard await self.confirm("Delete “\(conversation.title)”?",
                                         "Its transcript, attachments and file checkpoints are removed from this server. Checkpoints another conversation still uses stay.\(review) This can't be undone.",
                                         "Delete"), !self.disposed else { return }
                self.conversationAction(.delete(session: conversation.session), doing: "delete that conversation")
            }
        })
        return items
    }

    /// Opens a closed conversation in a pane again, as it was.
    func reopenConversation(_ session: SessionId) {
        conversationAction(.reopen(session: session), doing: "reopen that conversation")
    }

    private func conversationAction(_ request: AgentConversationRequest, doing action: String) {
        guard !disposed, historyTask == nil, let conversationRequest else { return }
        let generation = connectionGeneration
        historyTask = Task { [weak self] in
            defer {
                self?.historyTask = nil
                self?.updateControls()
            }
            do {
                let reply = try await conversationRequest(request)
                guard let self, !Task.isCancelled, !self.disposed else { return }
                switch (request, reply) {
                case (.reopen, .conversation(let snapshot)):
                    if snapshot.session == self.session { self.accept(snapshot, generation: generation, authoritative: true) }
                    else { self.showConversation?(snapshot) }
                case (.setRetention, .conversation), (.delete, .deleted):
                    self.historyTask = nil
                    self.showHistory()
                default: break
                }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, !self.disposed else { return }
                self.showHistoryError(error, doing: action)
            }
        }
        updateControls()
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

    /// Sends `command` as the pane's one request in flight. `onReply` sees every accepted
    /// reply and `onFailure` takes a failure in place of the usual error; `then` may name a
    /// second request sent before another can start, whose outcome goes to `onFollowUp`.
    func run(_ command: AgentChatRequest, onSuccess: (() -> Void)? = nil, onReply: ((AgentChatSnapshot) -> Void)? = nil,
             onFailure: ((Error) -> Void)? = nil, then followUp: ((AgentChatSnapshot) -> AgentChatRequest?)? = nil,
             onFollowUp: ((Result<AgentChatSnapshot, Error>) -> Void)? = nil) {
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
                onReply?(result)
                guard let next = followUp?(result) else { return }
                do {
                    let followed = try await self.request(next)
                    guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                    self.accept(followed, generation: generation)
                    onFollowUp?(.success(followed))
                } catch {
                    guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                    onFollowUp?(.failure(error))
                }
            } catch {
                guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                if let onFailure { onFailure(error) }
                else if case .clear = command, (error as? ClientError)?.serverCode == .unsupported {
                    self.showComposerError("Update Tab on this server to clear a conversation in place. Your conversation is unchanged.")
                } else { self.showError(error) }
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
            // Previews that failed while the server was away load now that it's back.
            surface.transcript.retryFailedAttachments()
        } else {
            guard result.revision >= (snapshot?.revision ?? 0) else { return }
        }
        if snapshot?.resetID != result.resetID {
            earlierTask?.cancel(); earlierTask = nil; earlier = AgentEarlierTimeline(); earlierUnavailable = false
            restartArchiveSearch(afterReset: true)
            lastSubmission = nil; questionDrafts = [:]; reviewComments = []
            surface.closeOutline(); attachmentCache.cancel()
            composerCoordinator.invalidate()
        }
        if discoveredCommands[result.provider] == nil || snapshot?.commandDescriptors != result.commandDescriptors,
           let commands = result.commandDescriptors {
            discoveredCommands[result.provider] = commands
        }
        snapshot = result
        // Home may remap during bootstrap. Bind the first authoritative session
        // owner, then reject foreign-project replies for this controller's life.
        authoritativeProject = result.project
        surface.citationEnvironmentId = result.project.description
        errorMessage = nil
        if !selectionEdited {
            selection = AgentModelSelection(provider: result.provider, providerID: result.providerID, model: result.model)
            reasoningEffort = result.reasoningEffort
            selectionEdited = false
        }
        let shown = displayed(result)
        surface.render(shown.snapshot, itemsUnchanged: itemsUnchanged, unchangedLead: shown.unchangedLead)
        announcer.observe(result, in: surface)
        for (toolUseID, window) in subagentWindows {
            if let agent = result.subagents?.first(where: { $0.toolUseID == toolUseID }) { window.update(agent) }
        }
        if authoritative {
            surface.actions.project?.refreshProjectMetadata()
        }
        composerWorkAccepted(result)
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
        let prompts = (snapshot?.items ?? []).reversed().filter { $0.kind == .user && !$0.isAutomaticTurn && !$0.text.isEmpty }.map(\.text)
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

    /// Why a conversation that hasn't started has no provider to start with; nil once one can.
    private var providerGap: AgentPaneView.ProviderGap? {
        guard providersLoaded, snapshot?.providerSession == nil else { return nil }
        if providers.isEmpty { return .noneAdded }
        return providers.contains(where: \.enabled) ? nil : .allOff
    }

    /// The Add Provider dialog when none is added, else Settings › Agents.
    private func setUpProviders() {
        if providerGap == .noneAdded || providers.isEmpty, let addAgentProvider {
            addAgentProvider()
        } else {
            openAgentSettings?()
        }
    }

    private var canSend: Bool {
        guard providerGap == nil, !needsAuthoritativeSnapshot, let snapshot else { return false }
        return !restoringDraft && (snapshot.status == .idle || snapshot.status == .failed || snapshot.status == .working || snapshot.status == .waiting)
    }

    func updateControls() {
        let descriptors = discoveredCommands[selection.provider] ?? (snapshot?.provider == selection.provider ? snapshot?.commandDescriptors ?? [] : [])
        composerCoordinator.providerDescriptors = descriptors
        let names = selection.provider == .codex ? ["compact", "review"]
            : discoveredCommands[selection.provider]?.map(\.name)
                ?? (snapshot?.provider == .claude ? snapshot?.commands : nil) ?? descriptors.map(\.name)
        var seen = Set<String>()
        composerCoordinator.providerCommands = (names + (selection.provider == .claude ? ["compact", "context", "usage", "cost"] : [])).filter { seen.insert($0).inserted }
        let interactionsEnabled = !disposed && !needsAuthoritativeSnapshot && commandTask == nil && !approvalInFlight
        surface.promptQueue.unsavedEdits = Set(composerWork.queueEdits.keys)
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
        surface.providerGap = providerGap
        surface.contextIndicator.update(usedTokens: snapshot?.contextUsage?.usedTokens,
                                        contextWindow: snapshot?.contextUsage?.contextWindow)
        let canCompact = composerCoordinator.providerCommands.contains("compact") && snapshot?.status == .idle && commandTask == nil
        surface.contextIndicator.onCompact = canCompact ? { [weak self] in self?.compactConversation() } : nil
        surface.setActivity(status: snapshot?.status ?? .idle, submitting: submitting)
        updateSelectionMenus()
        surface.setApprovalsEnabled(!approvalInFlight && commandTask == nil && !disposed && !needsAuthoritativeSnapshot)
        surface.feedback.stringValue = errorMessage ?? notice?.text ?? statusText
        surface.noticeTone = noticeTone
        surface.feedback.toolTip = surface.feedback.stringValue
        surface.feedback.setAccessibilityValue(surface.feedback.stringValue)
        surface.retry.isHidden = errorMessage == nil
        surface.dismissNotice.isHidden = errorMessage != nil || notice == nil
        let retryable = retryableTurnItem
        surface.retryTurn.isHidden = errorMessage != nil || notice != nil || retryable == nil
        let blockedRetry = retryable.flatMap { item in unretryable?.item == item.id ? unretryable?.reason : nil }
        surface.retryTurn.isEnabled = retryTask == nil && commandTask == nil && canSend && blockedRetry == nil
        surface.retryTurn.toolTip = blockedRetry ?? "Send that prompt again as a new message"
        updateRateLimitControls(blocked: blockedRetry)
        surface.newConversation.isHidden = errorMessage != nil || notice != nil || snapshot?.status != .closed || onNewConversation == nil
        updateComposerWorkControls()
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

    /// The tone of what the notice card shows: an error, the notice, or else the status.
    private var noticeTone: AgentPaneView.NoticeTone {
        if errorMessage != nil { return .danger }
        if let notice {
            switch notice.kind {
            case .warning: return .warning
            case .info: return .info
            case .progress: return .progress
            }
        }
        if voice.state == .authorizing || preparingAttachments > 0 || historyTask != nil || needsAuthoritativeSnapshot { return .progress }
        if voice.state == .listening { return .info }
        switch snapshot?.status {
        case nil: return .progress
        case .failed: return snapshot?.turns?.last?.outcome == .interrupted ? .warning : .danger
        default: return .info
        }
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

    var canSendDraft: Bool {
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
        descriptor(for: AgentModelSelection(provider: selection.provider, providerID: selection.providerID, model: effectiveModel))
    }

    private func descriptor(for choice: AgentModelSelection) -> AgentModelDescriptor? {
        guard let model = choice.model else { return nil }
        let models = modelCatalogs[choice.providerKey] ?? []
        return models.first { $0.id == model } ?? models.first { $0.resolvedModel == model }
    }

    private func modelTitle(_ choice: AgentModelSelection) -> String {
        descriptor(for: choice)?.title ?? choice.title
    }

    private func refreshModelCatalog(force: Bool = false) {
        if force {
            modelCatalogTask?.cancel()
            modelCatalogTask = nil
        } else {
            guard modelCatalogTask == nil, Date().timeIntervalSince(modelCatalogLoadedAt) > 60 else { return }
        }
        guard loadModelCatalog != nil else { return }
        modelCatalogLoadedAt = Date()
        let generation = connectionGeneration
        let taskID = UUID()
        modelCatalogTaskID = taskID
        modelCatalogTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.connectionGeneration, self.modelCatalogTaskID == taskID {
                    self.modelCatalogTask = nil
                }
            }
            if let state = try? await self.loadProviders?() {
                guard !Task.isCancelled, !self.disposed, generation == self.connectionGeneration else { return }
                self.providersLoaded = true
                self.providers = state.settings.providers
                self.providerHealth = Dictionary(state.health.map { ($0.provider, $0) }, uniquingKeysWith: { _, last in last })
                if !self.providers.isEmpty, self.snapshot?.providerSession == nil, !self.selectionEdited,
                   !self.providers.contains(where: { $0.id == self.selection.providerKey && $0.enabled }),
                   let preferred = self.providers.first(where: { $0.enabled && $0.kind == self.selection.provider })
                       ?? self.providers.first(where: \.enabled) ?? self.providers.first {
                    self.selection = AgentModelSelection(provider: preferred.kind, providerID: preferred.id, model: nil)
                }
                self.menuState = nil
                self.updateControls()
                self.warnIfUnavailable()
            }
            let providers = self.menuProviders
            await withTaskGroup(of: Void.self) { group in
                for provider in providers {
                    group.addTask { @MainActor [weak self] in
                        await self?.fetchModelCatalog(provider: provider, force: force, generation: generation)
                    }
                }
            }
        }
    }

    private func fetchModelCatalog(provider: AgentProviderConfig, force: Bool, generation: UInt64) async {
        guard let loadModelCatalog else { return }
        do {
            let reply = try await loadModelCatalog(provider, force)
            guard !Task.isCancelled, !disposed, generation == connectionGeneration else { return }
            modelCatalogs[provider.id] = reply.models
            unavailableModelCatalogs.remove(provider.id)
            menuState = nil
            updateControls()
            // A persisted ("saved") reply was returned immediately while the server refreshes in
            // the background; join that live refresh so stale models are replaced once it finishes.
            if !force, reply.source == "saved", let live = try? await loadModelCatalog(provider, true) {
                guard !Task.isCancelled, !disposed, generation == connectionGeneration else { return }
                if !live.models.isEmpty {
                    modelCatalogs[provider.id] = live.models
                    menuState = nil
                    updateControls()
                }
            }
        } catch {
            guard !Task.isCancelled, !disposed, generation == connectionGeneration else { return }
            unavailableModelCatalogs.insert(provider.id)
            menuState = nil
            updateControls()
        }
    }

    var effectiveModel: String? {
        selection.model ?? (selection.provider == snapshot?.provider ? snapshot?.resolvedModel : nil)
            ?? modelCatalogs[selection.providerKey]?.first(where: \.isDefault)?.id
    }

    /// The providers the model menu lists: only enabled configured providers, plus the
    /// active conversation's provider if it has already started.
    private var menuProviders: [AgentProviderConfig] {
        providers.filter { $0.enabled || (snapshot?.providerSession != nil && $0.id == selection.providerKey) }
    }

    /// Why a provider can't start a conversation now, as its last check found.
    private func unavailability(_ config: AgentProviderConfig) -> AgentProviderUnavailability? {
        AgentProviderUnavailability(config, health: providerHealth[config.id], computer: computerName?() ?? nil)
    }

    /// Warns in the composer, once, that the chosen provider can't run, as a new
    /// conversation would otherwise fail only after a prompt is sent.
    private func warnIfUnavailable() {
        let config = providerConfig(selection.providerKey, kind: selection.provider)
        guard snapshot?.providerSession == nil || !isCurrentProvider(config.id),
              let reason = unavailability(config) else { return }
        let key = config.id + "\n" + reason.detail
        guard announcedUnavailable != key else { return }
        announcedUnavailable = key
        showNotice(reason.detail, kind: .warning)
    }

    private func providerConfig(_ key: String, kind: TabCore.AgentChatProvider) -> AgentProviderConfig {
        providers.first { $0.id == key && $0.kind == kind } ?? .builtIn(kind)
    }

    /// The conversation's provider ID, a built-in one's being its kind's name.
    private static func providerKey(_ snapshot: AgentChatSnapshot) -> String {
        snapshot.providerID ?? snapshot.provider.rawValue
    }

    /// Whether `key` is the provider the conversation already runs.
    private func isCurrentProvider(_ key: String) -> Bool {
        snapshot.map { Self.providerKey($0) == key } ?? false
    }

    /// Whether a provider other than the conversation's would take it over from its
    /// transcript, because the conversation has already begun.
    private var switchingHandsOff: Bool {
        guard let snapshot else { return false }
        return snapshot.providerSession != nil || (snapshot.omittedItems ?? 0) > 0
            || snapshot.items.contains { $0.kind == .user || $0.kind == .assistant }
    }

    /// The model and effort can change at any time: a choice made while the agent works
    /// applies to the next prompt, including one sent to the queue now.
    var canEditSelection: Bool {
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

    func selectModel(provider: TabCore.AgentChatProvider, providerID: String? = nil, model: String?) {
        // A picker opened while idle can finish during reconnection. Keep that
        // choice as a local draft until an authoritative snapshot arrives.
        let key = providerID ?? (provider == selection.provider ? selection.providerKey : provider.rawValue)
        guard canEditSelection else { return }
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = AgentModelSelection(provider: provider, providerID: key, model: trimmed?.isEmpty == false ? trimmed : nil)
        guard chosen != selection else { return applyModel(chosen) }
        guard switchingHandsOff, !isCurrentProvider(key), key != selection.providerKey else {
            return confirmingRestart { [weak self] in self?.applyModel(chosen) }
        }
        Task { [weak self] in
            guard let self else { return }
            let config = self.providerConfig(key, kind: provider)
            let confirmed = await (self.confirmProviderHandoff ?? self.presentHandoffConfirmation)(config.title)
            guard confirmed, !self.disposed else { self.menuState = nil; self.updateControls(); return }
            self.confirmingRestart { [weak self] in self?.applyModel(chosen) }
        }
    }

    /// Asks before another provider takes over the conversation; nil asks with a sheet.
    var confirmProviderHandoff: ((String) async -> Bool)?

    private func presentHandoffConfirmation(_ provider: String) async -> Bool {
        guard let window = surface.window else { return true }
        let current = snapshot.map { providerConfig(Self.providerKey($0), kind: $0.provider).title } ?? "The current agent"
        let alert = NSAlert()
        alert.window.appearance = surface.theme.nsAppearance
        alert.messageText = "Switch this conversation to \(provider)?"
        alert.informativeText = "\(provider) can't continue \(current)'s conversation, so your next message sends it the whole conversation so far. "
            + "A long conversation uses much more of your \(provider) limits or credits, and \(provider) starts without what \(current) kept out of the transcript, such as files it read in full. "
            + "Earlier messages can't be rewound after the switch."
        alert.addButton(withTitle: "Switch to \(provider)")
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
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
            selectModel(provider: value.provider, providerID: value.providerKey, model: value.model)
        } else if item.representedObject as? String == "refresh-models" {
            modelCatalogLoadedAt = .distantPast
            menuState = nil
            refreshModelCatalog(force: true)
        } else if item.representedObject as? String == "open-agent-settings" {
            setUpProviders()
        }
    }

    @objc private func setUpSelected(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        openProviderSettings?(provider)
    }

    @objc private func signInSelected(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        openTerminal?(command)
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
                                handsOff: switchingHandsOff,
                                resolvedModel: effectiveModel, providers: menuProviders, health: providerHealth)
        guard menuState != state else { return }
        menuState = state
        let displayedSelection = AgentModelSelection(provider: selection.provider, providerID: selection.providerID, model: effectiveModel)
        let menu = NSMenu()
        menu.delegate = self
        var menuLogos: [Int: AgentProviderConfig] = [:]
        menu.autoenablesItems = false
        for config in menuProviders {
            let provider = config.kind
            let key = config.id
            let heading = NSMenuItem(title: config.title, action: nil, keyEquivalent: "")
            let models = NSMenu(title: config.title)
            models.autoenablesItems = false
            heading.submenu = models
            heading.state = selection.providerKey == key ? .on : .off
            let unavailable = config.enabled ? unavailability(config) : nil
            if !config.enabled { heading.toolTip = "\(config.title): Turned off in Settings › Agents." }
            if let unavailable {
                heading.toolTip = unavailable.detail
                heading.badge = NSMenuItemBadge(string: unavailable.badge)
                let reason = NSMenuItem(title: unavailable.reason, action: nil, keyEquivalent: "")
                reason.isEnabled = false
                reason.toolTip = unavailable.detail
                models.addItem(reason)
                if let command = unavailable.signInCommand, openTerminal != nil {
                    let signIn = NSMenuItem(title: "Sign In in a Terminal…", action: #selector(signInSelected(_:)), keyEquivalent: "")
                    signIn.target = self
                    signIn.representedObject = command
                    signIn.toolTip = "Runs \(command)"
                    models.addItem(signIn)
                } else if openProviderSettings != nil {
                    let setUp = NSMenuItem(title: unavailable.setUpTitle, action: #selector(setUpSelected(_:)), keyEquivalent: "")
                    setUp.target = self
                    setUp.representedObject = key
                    setUp.toolTip = "Opens \(config.title) in Settings › Agents"
                    models.addItem(setUp)
                }
                models.addItem(.separator())
            }
            menuLogos[menu.items.count] = config
            menu.addItem(heading)
            var choices = (modelCatalogs[key] ?? []).map { AgentModelSelection(provider: provider, providerID: key, model: $0.id) }
            let shownModel = descriptor(for: displayedSelection)
            if displayedSelection.providerKey == key && displayedSelection.model != nil && shownModel == nil {
                choices.append(displayedSelection)
            }
            if choices.isEmpty {
                let title = !config.enabled ? "Turned off" : unavailableModelCatalogs.contains(key) ? "Models unavailable"
                    : modelCatalogs[key] == nil ? "Loading models…" : "No models reported"
                let status = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                status.isEnabled = false
                models.addItem(status)
            }
            for choice in choices {
                let item = NSMenuItem(title: modelTitle(choice), action: nil, keyEquivalent: "")
                item.representedObject = choice
                item.target = self
                item.action = #selector(modelSelected(_:))
                let current = selectedModelDescriptor.map {
                    AgentModelSelection(provider: selection.provider, providerID: selection.providerID, model: $0.id)
                } ?? displayedSelection
                item.state = choice == current ? .on : .off
                let reported = descriptor(for: choice) != nil
                item.isEnabled = reported && ((config.enabled && unavailable == nil) || isCurrentProvider(key))
                let handsOff = switchingHandsOff && !isCurrentProvider(key)
                item.toolTip = !reported ? "Current model is not listed in the provider catalog."
                    : unavailable.map { $0.detail }
                    ?? (handsOff ? "\(choice.model ?? config.title) · Switching sends \(config.title) the conversation so far" : choice.model)
                models.addItem(item)
            }
        }
        if menuProviders.isEmpty && providersLoaded {
            let empty = NSMenuItem(title: providers.isEmpty ? "No providers added" : "Every provider is off", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            if openAgentSettings != nil || addAgentProvider != nil {
                let title = providers.isEmpty && addAgentProvider != nil ? "Add Provider…" : "Open Settings › Agents…"
                let open = NSMenuItem(title: title, action: #selector(modelSelected(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = "open-agent-settings"
                menu.addItem(open)
            }
        }
        menu.addItem(.separator())
        let refreshModels = NSMenuItem(title: "Refresh models…", action: nil, keyEquivalent: "")
        refreshModels.representedObject = "refresh-models"
        menu.addItem(refreshModels)
        surface.model.menu = menu
        surface.model.menuLogos = menuLogos
        surface.model.providerLogo = (menuProviders.isEmpty && providersLoaded) ? nil : selection.provider.activityProvider
        surface.model.select(nil)
        surface.model.displayedTitle = (menuProviders.isEmpty && providersLoaded) ? "No Provider" : modelTitle(displayedSelection)
        surface.model.icon = selection.provider == .claude ? .sparkles : .cpu
        surface.model.toolTip = (menuProviders.isEmpty && providersLoaded)
            ? (providers.isEmpty ? "Add a provider in Settings › Agents to choose a model." : "Turn a provider on in Settings › Agents to choose a model.")
            : "Model · \(providerConfig(selection.providerKey, kind: selection.provider).title). Changes apply to the next message."

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
        surface.modelPicker.refresh()
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
    /// `progress` stays until its work ends; dismissing it cancels that work.
    enum Kind: Equatable { case warning, info, progress }
    var text: String
    var kind: Kind
}

private enum AgentPaneError: LocalizedError {
    case offline
    var errorDescription: String? { "The project server is offline." }
}

extension AgentPaneController {
    func configureDraftStore(_ url: URL) {
        let store = AgentDraftStore(url: url)
        draftStore = store; restoringDraft = true
        composerWork.stash = AgentDraftStash(draftURL: url)
        draftRestoreTask = Task { @MainActor [weak self] in
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

    func captureDraft() -> AgentSavedDraft {
        questionDrafts.merge(surface.questions.savedAnswers) { _, latest in latest }
        if let snapshot {
            let pending = Set(snapshot.items.filter { !$0.isComplete && $0.questionnaire != nil }.map(\.id))
            questionDrafts = questionDrafts.filter { pending.contains($0.key) }
        }
        return AgentSavedDraft(text: surface.composer.attributedString(), attachments: draftAttachments,
                               submission: lastSubmission, answers: questionDrafts, reviewComments: reviewComments)
    }
    func saveDraft(immediate: Bool = false) {
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

extension AgentPaneController: PanePrewarming {
    /// Loads the conversation while its tab is hidden, as showing it would.
    func prewarm() { refresh() }
}
