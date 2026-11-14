import Foundation
import Observation
import os
import TabProtocol
import TabShared

/// One agent pane's conversation. The server runs the agent and sends whole
/// snapshots: this reads the newest one when the server says the chat
/// changed, at most one read at a time, and never goes back to an older one.
///
/// It also keeps the pane's draft, saved as it changes, so text, files and
/// answers outlive the app, and a prompt resubmitted after a lost connection
/// keeps its id and isn't taken twice.
@MainActor
@Observable
public final class AgentChatController {
    public nonisolated let session: SessionId
    public let project: ProjectId
    public private(set) var provider: AgentChatProvider
    public private(set) var snapshot: AgentChatSnapshot?
    /// Each provider's models, as its CLI on the Mac reports them.
    public private(set) var models: [AgentChatProvider: [AgentModelDescriptor]] = [:]
    /// The provider and model the next message goes to; nil model is the provider's default.
    public private(set) var selection: (provider: AgentChatProvider, model: String?)
    public private(set) var effort: AgentReasoningEffort?
    /// A command is on its way; sending again waits for it.
    public private(set) var busy = false
    /// A message is on its way and the server hasn't taken it yet.
    public private(set) var submitting = false
    public private(set) var error: String?
    /// Changes when the draft changes other than by typing, such as when it's
    /// restored or a sent message leaves it; the composer then reloads it.
    public private(set) var draftGeneration = 0
    /// The saved draft has been read, so the composer may edit it.
    public private(set) var draftRestored = false

    @ObservationIgnored public private(set) var draft = AgentDraft()
    @ObservationIgnored private weak var server: ServerModel?
    @ObservationIgnored private let drafts: AgentDraftStore?
    @ObservationIgnored private var draftRevision: UInt64 = 0
    @ObservationIgnored private var draftSave: Task<Void, Never>?
    @ObservationIgnored private var created = false
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var readAgain = false
    @ObservationIgnored private var wanted = false
    /// The server predates queued prompts, so messages go by `send`.
    @ObservationIgnored private var sendsDirectly = false
    @ObservationIgnored private static let log = Logger(subsystem: "com.hugocorta.tabios", category: "agent")

    init(session: SessionId, project: ProjectId, provider: AgentChatProvider, server: ServerModel?,
         drafts: AgentDraftStore?) {
        self.session = session
        self.project = project
        self.provider = provider
        self.server = server
        self.drafts = drafts
        selection = (provider, nil)
        restoreDraft()
    }

    /// The provider stays open to change until the conversation starts, as on the desktop.
    public var canChangeProvider: Bool { snapshot?.providerSession == nil }

    /// The model the next message uses: the chosen one, the conversation's, or the default.
    public var effectiveModel: String? {
        selection.model ?? (selection.provider == snapshot?.provider ? snapshot?.resolvedModel ?? snapshot?.model : nil)
            ?? models[selection.provider]?.first(where: \.isDefault)?.id
    }

    public var selectedModel: AgentModelDescriptor? {
        models[selection.provider]?.first { $0.id == effectiveModel }
    }

    public var status: AgentChatStatus { snapshot?.status ?? .idle }
    public var items: [AgentChatItem] { snapshot?.items ?? [] }
    public var isRunning: Bool { status == .working || status == .waiting }
    public var planMode: Bool { snapshot?.planMode == true }
    public var queuedPrompts: [AgentQueuedPrompt] { snapshot?.queuedPrompts ?? [] }
    public var queuePaused: Bool { snapshot?.queuePaused == true }
    /// Agents the conversation's agent started that are still running.
    public var runningSubagents: [AgentSubagent] { (snapshot?.subagents ?? []).filter { $0.status == .running } }

    /// Closing the pane would stop work: a turn, queued prompts or agents
    /// running in the background.
    public var closingStopsWork: Bool { isBusy || !runningSubagents.isEmpty }

    /// Queued prompts will go on their own once the agent is free.
    public var hasActiveQueue: Bool { !queuePaused && !queuedPrompts.isEmpty }

    /// Something is happening that Stop can end: a message on its way, a
    /// turn, or prompts waiting their turn.
    public var isBusy: Bool { submitting || isRunning || hasActiveQueue }

    /// The question the agent is waiting on, answered in its form above the composer.
    public var pendingQuestion: AgentChatItem? {
        items.first { $0.questionnaire != nil && !$0.isComplete }
    }

    /// Nothing sent, queued or running yet.
    public var isEmptyConversation: Bool {
        (snapshot?.items.isEmpty ?? true) && queuedPrompts.isEmpty && !submitting && !isRunning
    }

    /// A message can be sent now, or queued behind the running turn.
    public var canSend: Bool {
        snapshot != nil && status != .closed && draftRestored
    }

    /// Starts following the chat: creates it on the server if it's new.
    public func open() {
        wanted = true
        refresh()
        loadModels()
    }

    public func close() {
        wanted = false
        saveDraft(immediately: true)
    }

    func connectionRestored(_ client: ServerClient) {
        guard wanted else { return }
        refresh()
    }

    func changed(revision: UInt64) {
        guard wanted, revision > (snapshot?.revision ?? 0) else { return }
        refresh()
    }

    private func refresh() {
        guard !reading else {
            readAgain = true
            return
        }
        guard let client = server?.client else { return }
        reading = true
        Task {
            defer { reading = false }
            repeat {
                readAgain = false
                let request: AgentChatRequest = created
                    ? .read(session: session)
                    : .create(session: session, project: project, provider: provider)
                do {
                    accept(try await client.agentChat(request))
                    created = true
                } catch let failure as ClientError {
                    error = failure.description
                    return
                } catch {
                    return
                }
            } while readAgain
        }
    }

    func accept(_ next: AgentChatSnapshot) {
        guard next.session == session, next.revision >= (snapshot?.revision ?? 0) else { return }
        let first = snapshot == nil
        snapshot = next
        provider = next.provider
        // The conversation's own provider and model win, unless this pane chose others for its first message.
        if first || !canChangeProvider {
            selection = (next.provider, next.model)
            effort = next.reasoningEffort
        }
        error = nil
        forgetAnsweredQuestions()
    }

    private func loadModels() {
        guard let client = server?.client else { return }
        for provider in AgentChatProvider.allCases where models[provider] == nil {
            let request = AgentModelCatalogRequest(project: project, provider: provider, forceRefresh: false)
            Task {
                guard let reply = try? await client.agentModelCatalog(request) else { return }
                models[provider] = reply.models
            }
        }
    }

    /// One page of the files a turn changed, or one file's diff when `path` is set.
    public func checkpoint(_ checkpoint: String, path: String? = nil, offset: Int = 0) async throws -> AgentCheckpointReply {
        guard let client = server?.client else { throw ClientError.disconnected }
        return try await client.agentCheckpoint(AgentCheckpointRequest(session: session, checkpoint: checkpoint, path: path,
                                                                       offset: offset))
    }

    /// Conversations Claude Code and Codex saved for this project's folder outside Tab.
    public func savedConversations() async throws -> AgentHistoryReply {
        guard let client = server?.client else { throw ClientError.disconnected }
        return try await client.agentHistory(AgentHistoryRequest(project: project))
    }

    /// Whether this pane can take over a saved conversation: nothing has been said in it.
    public var isUnused: Bool {
        created && !submitting && !busy && snapshot.map {
            $0.items.isEmpty && $0.providerSession == nil && $0.status == .idle
        } == true
    }

    /// Continues `entry`: in this pane when it's unused, which then returns nil;
    /// otherwise as a new conversation, which the caller opens beside it.
    public func continueConversation(_ entry: AgentHistoryEntry) async throws -> AgentChatSnapshot? {
        guard let client = server?.client else { throw ClientError.disconnected }
        let target = isUnused ? session : SessionId()
        let reply = try await client.importAgentHistory(AgentHistoryImport(session: target, project: project,
                                                                           provider: entry.provider,
                                                                           providerSession: entry.providerSession))
        guard reply.session == session else { return reply }
        accept(reply)
        return nil
    }

    /// The bytes of a file sent with a message, for showing its image.
    public func attachment(item: String, id: String) async throws -> AgentChatAttachment {
        guard let client = server?.client else { throw ClientError.disconnected }
        let request = AgentAttachmentRequest(session: session, item: item, attachment: id)
        return try await client.agentAttachment(request).attachment
    }

    // MARK: Draft

    /// The composer's text changed as the user typed.
    public func draftChanged(text: String) {
        guard draft.text != text else { return }
        draft.text = text
        saveDraft()
    }

    /// Why `attachment` can't join the draft, or nil once it has.
    public func attach(_ attachment: AgentChatAttachment) -> String? {
        if let problem = AgentDraftAttachments.problem(adding: attachment, to: draft.attachments) { return problem }
        draft.attachments.append(attachment)
        saveDraft()
        return nil
    }

    public func detach(_ id: String) {
        draft.attachments.removeAll { $0.id == id }
        saveDraft()
    }

    /// The review comments on `checkpoint`'s changes.
    public func reviewComments(for checkpoint: String) -> [AgentReviewComment] {
        draft.reviewComments.filter { $0.checkpoint == checkpoint }
    }

    /// Replaces the review comments on `checkpoint`'s changes.
    public func setReviewComments(_ comments: [AgentReviewComment], for checkpoint: String) {
        draft.reviewComments.removeAll { $0.checkpoint == checkpoint }
        draft.reviewComments += comments
        saveDraft(immediately: true)
    }

    /// Adds the comments on `checkpoint` to the end of the message, without
    /// sending it, and lets them go. Returns why it can't.
    public func addReviewToDraft(_ checkpoint: String) -> String? {
        guard draftRestored else { return "The message isn't ready yet. Try again in a moment." }
        let comments = reviewComments(for: checkpoint)
        guard !comments.isEmpty else { return nil }
        let text = AgentReviewComment.prompt(comments)
        let separator = draft.text.isEmpty ? "" : "\n\n"
        guard draft.text.utf8.count + separator.utf8.count + text.utf8.count <= 256 * 1024 else {
            return "These comments would make the message too long. Shorten the message or the comments first."
        }
        draft.text += separator + text
        draft.reviewComments.removeAll { $0.checkpoint == checkpoint }
        draftGeneration += 1
        saveDraft(immediately: true)
        return nil
    }

    /// Keeps what's been answered so far in a question's form; private answers are never saved.
    public func questionAnswersChanged(_ answers: [String: [String]], for item: AgentChatItem) {
        let secrets = Set(item.questionnaire?.questions.filter(\.secret).map(\.id) ?? [])
        let kept = answers.filter { !secrets.contains($0.key) && !$0.value.isEmpty }
        guard draft.answers[item.id] ?? [:] != kept else { return }
        draft.answers[item.id] = kept.isEmpty ? nil : kept
        saveDraft()
    }

    private func forgetAnsweredQuestions() {
        let pending = Set(items.filter { $0.questionnaire != nil && !$0.isComplete }.map(\.id))
        let kept = draft.answers.filter { pending.contains($0.key) }
        guard kept.count != draft.answers.count else { return }
        draft.answers = kept
        saveDraft()
    }

    private func restoreDraft() {
        guard let drafts else {
            draftRestored = true
            return
        }
        Task {
            let saved = await drafts.read(session)
            // Anything typed before the file was read wins over it.
            if let saved, draft.text.isEmpty, draft.attachments.isEmpty {
                draft = saved
                draftGeneration += 1
            }
            draftRestored = true
        }
    }

    private func saveDraft(immediately: Bool = false) {
        guard let drafts, draftRestored else { return }
        draftRevision += 1
        let revision = draftRevision
        let draft = draft
        let session = session
        draftSave?.cancel()
        draftSave = Task {
            if !immediately {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            do {
                try await drafts.write(draft, session: session, revision: revision)
            } catch {
                Self.log.error("Couldn't save an agent draft: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Commands

    /// Sends the draft, with the chat's current model, effort and plan mode.
    /// While the agent works the server queues it for the next turn. The
    /// draft clears once the server has it; edits typed meanwhile stay.
    public func send() {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, canSend, !text.isEmpty || !draft.attachments.isEmpty else { return }
        let attachments = draft.attachments
        var prompt = AgentPrompt(text: text, model: selection.model, effort: effort, provider: selection.provider,
                                 planMode: planMode, attachments: attachments)
        // A retry of the same message keeps its id, so the server takes it only once.
        if let previous = draft.submission, previous.text == text, previous.attachments == attachments {
            prompt = previous
        }
        draft.submission = prompt
        saveDraft(immediately: true)
        let sentText = draft.text
        let sentIDs = Set(attachments.map(\.id))
        submitting = true
        run(sendsDirectly ? legacySend(prompt) : .submit(session: session, prompt: prompt), fallback: legacySend(prompt)) {
            [weak self] in
            guard let self else { return }
            submitting = false
            draft.submission = nil
            draft.attachments.removeAll { sentIDs.contains($0.id) }
            if draft.text == sentText { draft.text = "" }
            draftGeneration += 1
            saveDraft(immediately: true)
        } finally: { [weak self] in
            self?.submitting = false
        }
    }

    /// The same message for a server that predates queued prompts.
    private func legacySend(_ prompt: AgentPrompt) -> AgentChatRequest {
        .send(session: session, text: prompt.text, model: prompt.model, reasoningEffort: prompt.effort,
              provider: prompt.provider == snapshot?.provider ? nil : prompt.provider,
              attachments: prompt.attachments.isEmpty ? nil : prompt.attachments)
    }

    /// Chooses the provider and model for the next message.
    public func select(provider: AgentChatProvider, model: String?) {
        guard canChangeProvider || provider == snapshot?.provider else { return }
        selection = (provider, model)
        let supported = models[provider]?.first { $0.id == effectiveModel }?.reasoningEfforts ?? []
        if let effort, !supported.contains(effort) { self.effort = nil }
    }

    public func select(effort: AgentReasoningEffort?) {
        self.effort = effort
    }

    public func approve(_ item: AgentChatItem, allow: Bool) {
        run(.approve(session: session, request: item.id, allow: allow))
    }

    /// Answers the pending question, or dismisses it when `cancelled`.
    public func answer(_ item: AgentChatItem, answers: [String: [String]], cancelled: Bool) {
        run(.answer(session: session, request: item.id, answers: cancelled ? [:] : answers, cancelled: cancelled))
    }

    /// Plan mode applies from the next turn, so it changes only while the agent is free.
    public func togglePlanMode() {
        guard !busy, snapshot != nil else { return }
        guard status == .idle || status == .failed else {
            error = "Stop the current response before changing plan mode."
            return
        }
        run(.setPlan(session: session, enabled: !planMode))
    }

    public func interrupt() {
        guard isRunning || hasActiveQueue else { return }
        run(.interrupt(session: session), exclusive: false)
    }

    // MARK: Queue

    /// Changes a queued prompt's text; `useCurrentSettings` also gives it the
    /// model, effort and plan mode now chosen. Its files stay with it.
    public func editQueued(_ prompt: AgentQueuedPrompt, text: String, useCurrentSettings: Bool) {
        let settings = useCurrentSettings
            ? AgentQueuedSettings(model: effectiveModel, effort: effort, planMode: planMode) : nil
        run(.editQueued(session: session, id: prompt.id, text: text, expectedRevision: prompt.revision, settings: settings))
    }

    public func removeQueued(_ prompt: AgentQueuedPrompt) {
        run(.removeQueued(session: session, id: prompt.id, expectedRevision: prompt.revision))
    }

    /// Sends a queued prompt now, ahead of the rest.
    public func deliverQueued(_ prompt: AgentQueuedPrompt) {
        run(.deliverQueued(session: session, id: prompt.id, expectedRevision: prompt.revision))
    }

    /// The queued prompt before `prompt` that it can move ahead of.
    public func earlierQueued(than prompt: AgentQueuedPrompt) -> AgentQueuedPrompt? {
        guard prompt.state == .queued, let index = queuedPrompts.firstIndex(where: { $0.id == prompt.id }) else { return nil }
        return queuedPrompts[..<index].last { $0.state == .queued }
    }

    public func moveQueuedEarlier(_ prompt: AgentQueuedPrompt) {
        guard let earlier = earlierQueued(than: prompt) else { return }
        run(.moveQueued(session: session, id: prompt.id, beforeID: earlier.id, expectedRevision: prompt.revision))
    }

    public func resumeQueue() {
        run(.resumeQueue(session: session))
    }

    /// Runs one command; `fallback` replaces it once if the server is too old
    /// to know it. `exclusive` commands wait for none other to be on its way.
    private func run(_ request: AgentChatRequest, fallback: AgentChatRequest? = nil, exclusive: Bool = true,
                     onSuccess: (() -> Void)? = nil, finally: (() -> Void)? = nil) {
        guard !exclusive || !busy else {
            finally?()
            return
        }
        guard let client = server?.client else {
            error = "Not connected."
            finally?()
            return
        }
        if exclusive { busy = true }
        Task {
            defer {
                if exclusive { busy = false }
                finally?()
            }
            do {
                let reply: AgentChatSnapshot
                do {
                    reply = try await client.agentChat(request)
                } catch let failure as ClientError where failure.serverCode == .unsupported && fallback != nil {
                    guard let fallback else { throw failure }
                    sendsDirectly = true
                    reply = try await client.agentChat(fallback)
                }
                onSuccess?()
                accept(reply)
            } catch let failure as ClientError {
                error = failure.serverCode == .unsupported
                    ? "The Tab on this Mac can't do that yet. Update Tab on the Mac, then try again."
                    : failure.description
            } catch {}
        }
    }
}
