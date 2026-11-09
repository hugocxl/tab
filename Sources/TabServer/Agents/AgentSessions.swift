import Foundation
import TabCore
import TabProtocol

/// Injectable boundary: tests never need a provider executable.
protocol AgentSessionRuntime: Sendable {
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
              attachments: [StagedAgentAttachment]) async throws
    func steer(text: String, attachments: [StagedAgentAttachment]) async throws
    func answer(request: String, answers: [String: [String]], cancelled: Bool) async throws
    func approve(request: String, allow: Bool) async throws
    func setPlan(_ enabled: Bool) async throws
    func setAccess(_ mode: AgentAccessMode) async throws
    func interrupt() async throws
    func stop()
    /// Called once, before the first message: what the provider process starts with.
    func prepare(_ launch: AgentLaunch)
}

/// What a conversation's provider process starts with beyond its arguments.
struct AgentLaunch: Sendable, Equatable {
    /// Added to the provider's environment, such as `TAB_AGENT_ID`.
    var environment: [String: String] = [:]
    /// Searched first on `PATH`, so the agent finds this Tab's `tab`.
    var path: String?
    /// The provider conversation to fork rather than resume, until the provider
    /// names the new one.
    var forkSource: String?
    /// The message of `forkSource` to fork at, rather than its latest.
    var forkPoint: String?
    /// Added to the provider's system prompt: where in Tab the agent runs.
    var instructions: String?
}

extension AgentSessionRuntime {
    func answer(request: String, answers: [String: [String]], cancelled: Bool) async throws {
        throw AgentRuntimeError("This runtime does not support question forms.")
    }
    func setPlan(_ enabled: Bool) async throws {
        if enabled { throw AgentRuntimeError("This runtime does not support plan mode.") }
    }

    func steer(text: String, attachments: [StagedAgentAttachment]) async throws {
        throw AgentRuntimeError("This runtime does not support messages during an active response.")
    }

    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
              attachments: [StagedAgentAttachment]) async throws {
        guard attachments.isEmpty else { throw AgentRuntimeError("This agent runtime does not support attachments.") }
        try await send(text: text, model: model, reasoningEffort: reasoningEffort)
    }

    func prepare(_ launch: AgentLaunch) {}
}

extension AgentRuntime: AgentSessionRuntime {}

/// Conversation ownership is independent of sockets, terminal channels and app references.
final class AgentSessions: @unchecked Sendable {
    typealias Factory = @Sendable (AgentChatProvider, String, String?,
                                  @escaping @Sendable (AgentRuntimeEvent) -> Void) -> any AgentSessionRuntime
    /// All mutable fields are confined to `queue`, including completion callbacks.
    private final class Entry: @unchecked Sendable {
        var inbox = AgentPromptInbox()
        var inboxError: String?
        var deliveryCancelled = false
        var deliveryID: String?
        var snapshot: AgentChatSnapshot
        let directory: String
        var runtime: (any AgentSessionRuntime)?
        var generation = UUID()
        var submitting = false
        var pendingSubmission: PendingReply?
        var approving: Set<String> = []
        var interrupting: UUID?
        var notifying = false
        var checkpointing = false
        var hasSuccessfulTurn = false
        var accessTask: Task<Void, Error>?
        var baselineTask: Task<AgentCheckpointStore.Snapshot?, Never>?
        var checkpointTask: Task<Void, Never>?
        var stagingToolImages = false
        var deferredEvents: [AgentRuntimeEvent] = []
        var deferredEventBytes = 0
        var deferredEventOverflow = false
        /// The provider conversation this one forks, until the provider names its own.
        var forkSource: String?
        /// The message of `forkSource` the fork ends at, so it leaves out what the
        /// source said after the fork was made.
        var forkPoint: String?
        /// The latest message the provider wrote to this conversation.
        var lastProviderMessage: String?
        /// Worker reports waiting for this coordinator, oldest first.
        var heldReports: [AgentHeldReport] = []
        var reportsPaused = false
        var deliveringReport = false
        /// The user asked for the held reports even though they stopped the agent.
        var forceDelivery = false
        /// Reports delivered since the user last sent a message.
        var unattendedDeliveries = 0
        var deliveryFailures = 0
        /// This worker's coordinator shows the card for it.
        var announced = false

        init(_ snapshot: AgentChatSnapshot, directory: String) {
            self.snapshot = snapshot
            self.directory = directory
            hasSuccessfulTurn = snapshot.items.contains { $0.kind == .assistant || $0.kind == .tool }
                || (snapshot.status == .idle && snapshot.items.contains { $0.kind == .user })
        }
    }

    private struct Saved: Codable {
        var snapshot: AgentChatSnapshot
        var directory: String
        var hasSuccessfulTurn: Bool?
        var forkSource: String?
        var forkPoint: String?
        var lastProviderMessage: String?
        var heldReports: [AgentHeldReport]?
        var reportsPaused: Bool?
        var announced: Bool?
        var unattendedDeliveries: Int?
    }

    /// A message from another agent, or a worker's report, on its way into a conversation.
    private struct Incoming {
        /// What the provider reads; the transcript shows the request's text.
        var modelText: String
        var peer: AgentPeer
        var itemType: String
        var requestKind: String?
        var sourceStatus: String?
        var detail: String?
        /// Who the reply of a turn this starts goes back to, and who asked them.
        var requestedBy: SessionId?
        var upstream: SessionId?
    }

    private final class PendingReply: @unchecked Sendable {
        var finished = false // Confined to queue.
        let continuation: CheckedContinuation<AgentChatSnapshot, Error>
        var task: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<AgentChatSnapshot, Error>) {
            self.continuation = continuation
        }
    }

    private let queue = DispatchQueue(label: "tab.agents.sessions", qos: .userInitiated)
    private let writer = DispatchQueue(label: "tab.agents.persistence", qos: .utility)
    private var retainedCheckpointIDs: [SessionId: Set<String>] = [:] // writer queue only
    private let root: URL
    private let factory: Factory
    private let projectDirectory: @Sendable (ProjectId) throws -> String
    private let submissionTimeout: TimeInterval
    private let interruptTimeout: TimeInterval
    /// Reports a chat's state with the folder it runs in.
    var activityChanged: @Sendable (AgentChatSnapshot, String) -> Void = { _, _ in }
    var changed: @Sendable (SessionId, UInt64) -> Void
    var checkDirectory: @Sendable (String) throws -> Void = { _ in }
    /// Tab's variables for every agent; each also gets `TAB_AGENT_ID`.
    var launchEnvironment: [String: String] = [:]
    /// The folder holding this Tab's `tab`, put first on agents' `PATH`.
    var cliDirectory: String?
    /// How long a settled worker report waits before delivery; see `AgentReports.grace`.
    var reportGrace = AgentReports.grace
    /// The project an agent works in, as its instructions describe it.
    var projectContext: @Sendable (ProjectId) -> AgentContext.Project? = { _ in nil }
    var stageToolImages: @Sendable ([AgentChatAttachment], URL) throws -> Void = { images, directory in
        let staged = try AgentAttachments.stageToolImages(images, root: directory)
        try AgentAttachments.record(staged, root: directory)
    }
    private var entries: [SessionId: Entry] = [:]
    private var stopping = false

    init(root: URL, projectDirectory: @escaping @Sendable (ProjectId) throws -> String,
         changed: @escaping @Sendable (SessionId, UInt64) -> Void = { _, _ in },
         submissionTimeout: TimeInterval = 120,
         interruptTimeout: TimeInterval = 15,
         factory: @escaping Factory = { provider, directory, resume, callback in
             AgentRuntime(provider: provider, directory: directory, resumeSession: resume, onEvent: callback)
         }) throws {
        self.root = root
        self.factory = factory
        self.projectDirectory = projectDirectory
        self.submissionTimeout = submissionTimeout
        self.interruptTimeout = interruptTimeout
        self.changed = changed
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
            where file.pathExtension == "json" {
            do {
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= Limits.maxFrame else {
                    continue
                }
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
                guard file.deletingPathExtension().lastPathComponent == saved.snapshot.session.description else {
                    continue
                }
                let entry = Entry(saved.snapshot, directory: saved.directory)
                do {
                    entry.inbox = try AgentPromptInbox.load(root.appendingPathComponent("inbox/" + entry.snapshot.session.description + ".json"))
                    if !entry.inbox.records.isEmpty || entry.inbox.paused {
                        entry.snapshot.queuedPrompts = entry.inbox.visible
                        entry.snapshot.queuePaused = entry.inbox.paused
                    } else if entry.snapshot.queuedPrompts?.isEmpty == false {
                        throw AgentRuntimeError("The queue acceptance ledger is missing. Pending prompts have not been replayed.")
                    }
                } catch {
                    entry.inboxError = error.localizedDescription
                    entry.snapshot.queuePaused = true
                    entry.snapshot.items.append(AgentChatItem(kind: .notice, text: "Queue recovery failed: " + error.localizedDescription))
                }
                entry.hasSuccessfulTurn = saved.hasSuccessfulTurn ?? entry.hasSuccessfulTurn
                entry.forkSource = saved.forkSource
                entry.forkPoint = saved.forkPoint
                entry.lastProviderMessage = saved.lastProviderMessage
                entry.heldReports = saved.heldReports ?? []
                entry.reportsPaused = saved.reportsPaused ?? false
                entry.announced = saved.announced ?? false
                entry.unattendedDeliveries = saved.unattendedDeliveries ?? 0
                bound(entry)
                let checkpointDirectory = root.appendingPathComponent("checkpoints", isDirectory: true)
                    .appendingPathComponent(entry.snapshot.session.description, isDirectory: true)
                let existing = (try? FileManager.default.contentsOfDirectory(at: checkpointDirectory, includingPropertiesForKeys: nil)) ?? []
                let checkpointIDs = Set(existing.filter { $0.pathExtension == "json" }.map { file in
                    let name = file.deletingPathExtension().lastPathComponent
                    return name.hasPrefix("pending-") ? String(name.dropFirst(8)) : name
                })
                let sessionID = entry.snapshot.session
                writer.async { self.retainedCheckpointIDs[sessionID] = checkpointIDs }
                restoreCheckpoints(entry)
                if entry.snapshot.status == .working || entry.snapshot.status == .waiting {
                    interrupted(entry, message: "Agent interrupted when the server stopped. Send a message to resume.")
                } else {
                    updateTurn(entry, status: entry.snapshot.status)
                }
                entries[entry.snapshot.session] = entry
                persist(entry)
            } catch {
                ServerLog.error("agent snapshot unavailable: \(file.lastPathComponent): \(error)")
            }
        }
        // Turns that settled while the server stopped report now; held reports
        // wait out their grace, so a returning coordinator can read them first.
        let restored = Array(entries.values)
        queue.asyncAfter(deadline: .now() + AgentReports.grace) { [self] in
            for entry in restored { routeReports(entry) }
            for entry in restored where !entry.heldReports.isEmpty { drainReports(entry) }
        }
    }

    func publishActivity() {
        queue.sync { for entry in entries.values { activityChanged(entry.snapshot, entry.directory) } }
    }

    var hasSessions: Bool {
        queue.sync { entries.values.contains { $0.snapshot.status != .closed || $0.runtime != nil || $0.submitting } }
    }

    func handle(_ request: AgentChatRequest) async throws -> AgentChatSnapshot {
        try request.validate()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try begin(request, continuation: continuation)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func attachment(_ request: AgentAttachmentRequest) async throws -> AgentAttachmentReply {
        try request.validate()
        let descriptor = queue.sync {
            entries[request.session]?.snapshot.items.first { $0.id == request.item }?.attachments?.first { $0.id == request.attachment }
        }
        guard let descriptor else { throw ServiceError(.badRequest, "Attachment not found in this conversation message") }
        let directory = root.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(request.session.description, isDirectory: true)
            .appendingPathComponent(AgentToolImages.directoryName(item: request.item), isDirectory: true)
        return try await runBlocking {
            AgentAttachmentReply(attachment: try AgentAttachments.retrieve(descriptor, root: directory))
        }
    }

    func checkpoint(_ request: AgentCheckpointRequest) async throws -> AgentCheckpointReply {
        try request.validate()
        let known = queue.sync {
            entries[request.session]?.snapshot.turns?.contains { $0.checkpoint?.id == request.checkpoint } ?? false
        }
        guard known else { throw ServiceError(.badRequest, "Checkpoint not found in this conversation") }
        let file = root.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(request.session.description, isDirectory: true)
            .appendingPathComponent(request.checkpoint + ".json")
        return try await runBlocking {
            let record = try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: file))
            guard request.offset <= record.files.count else { throw ServiceError(.badRequest, "Invalid checkpoint page") }
            let end = min(record.files.count, request.offset + min(128, record.files.count - request.offset))
            let files = Array(record.files[request.offset..<end])
            var diff: GitDiff?
            if let path = request.path {
                guard let file = record.files.first(where: { $0.path == path }) else {
                    throw ServiceError(.badRequest, "File is not part of this checkpoint")
                }
                var content = try AgentCheckpointStore().diff(from: record.before, to: record.after, path: path)
                content.additions = file.additions ?? 0
                content.deletions = file.deletions ?? 0
                content.binary = file.additions == nil || file.deletions == nil
                if content.rows.count > 8000 {
                    content.rows = Array(content.rows.prefix(8000))
                    content.truncated = true
                }
                diff = content
            }
            let reply = AgentCheckpointReply(checkpoint: request.checkpoint, files: files,
                totalFiles: record.files.count, nextOffset: end < record.files.count ? end : nil, path: request.path, diff: diff)
            try reply.validate()
            return reply
        }
    }

    private func begin(_ request: AgentChatRequest,
                       continuation: CheckedContinuation<AgentChatSnapshot, Error>, deliveryID: String? = nil,
                       incoming: Incoming? = nil) throws {
        switch request {
        case .delegate(let id, let name, let coordinator, let reports):
            continuation.resume(returning: try delegate(id, name: name, coordinator: coordinator, reports: reports))
            return
        case .message(let id, let text, let from):
            guard let entry = entries[id] else { throw ServiceError.unknownSession(id) }
            guard let sender = entries[from], sender.snapshot.status != .closed else {
                throw ServiceError(.badRequest, "The sending agent isn't open on this server")
            }
            let fromCoordinator = entry.snapshot.coordinator?.session == from
            let message = incomingMessage(text, to: entry, from: sender, task: fromCoordinator && !entry.announced)
            try begin(.send(session: id, text: text, model: entry.snapshot.model,
                            reasoningEffort: entry.snapshot.reasoningEffort),
                      continuation: continuation, incoming: message)
            if fromCoordinator, !entry.announced { announce(entry, to: sender, task: text) }
            return
        case .acknowledge(let id, let turn, let by):
            continuation.resume(returning: try acknowledge(id, turn: turn, by: by))
            return
        case .deliverReports(let id):
            guard let entry = entries[id] else { throw ServiceError.unknownSession(id) }
            guard !stopping, entry.snapshot.status != .closed else {
                throw ServiceError(.badRequest, "The agent session is closed or the server is stopping")
            }
            entry.forceDelivery = !entry.heldReports.isEmpty
            entry.reportsPaused = false
            entry.unattendedDeliveries = 0
            entry.deliveryFailures = 0
            syncReportQueue(entry)
            touch(entry)
            persist(entry)
            drainReports(entry)
            continuation.resume(returning: entry.snapshot)
            return
        default: break
        }
        if case .create(let id, let project, let provider) = request {
            if let entry = entries[id] {
                guard entry.snapshot.project == project else {
                    throw ServiceError(.badRequest, "This agent session ID is already in use")
                }
                continuation.resume(returning: entry.snapshot)
                return
            }
            guard !stopping else { throw ServiceError(.badRequest, "The server is stopping") }
            let directory = try projectDirectory(project)
            try checkDirectory(directory)
            let entry = Entry(AgentChatSnapshot(session: id, project: project, provider: provider, accessMode: .fullAccess), directory: directory)
            entries[id] = entry
            touch(entry)
            persist(entry)
            continuation.resume(returning: entry.snapshot)
            return
        }
        if case .fork(let id, let from, let project) = request {
            continuation.resume(returning: try fork(id, from: from, into: project))
            return
        }
        let id: SessionId
        switch request {
        case .read(let session), .send(let session, _, _, _, _, _), .approve(let session, _, _),
             .interrupt(let session), .close(let session), .setAccess(let session, _), .setPlan(let session, _): id = session
        case .submit(let session, _), .editQueued(let session, _, _, _, _), .removeQueued(let session, _, _),
             .deliverQueued(let session, _, _), .moveQueued(let session, _, _, _), .resumeQueue(let session), .answer(let session, _, _, _): id = session
        case .create, .fork, .delegate, .message, .acknowledge, .deliverReports:
            throw ServiceError(.badRequest, "Unexpected request")
        }
        guard let entry = entries[id] else { throw ServiceError.unknownSession(id) }
        if case .read = request {
            continuation.resume(returning: entry.snapshot)
            return
        }
        if case .close = request {
            close(entry)
            continuation.resume(returning: entry.snapshot)
            return
        }
        guard !stopping, entry.snapshot.status != .closed else {
            throw ServiceError(.badRequest, "The agent session is closed or the server is stopping")
        }
        if try handleInbox(request, entry: entry) {
            writer.async { [self] in
                queue.async {
                    if let error = entry.inboxError { continuation.resume(throwing: AgentRuntimeError(error)) }
                    else { continuation.resume(returning: entry.snapshot) }
                }
            }
            return
        }
        if case .interrupt = request {
            entry.deliveryCancelled = true
            try mutateInbox(entry) { $0.paused = true }
        }
        if case .setPlan(_, let enabled) = request {
            guard !entry.submitting, entry.snapshot.status != .working, entry.snapshot.status != .waiting else {
                throw ServiceError(.badRequest, "Stop the current response before changing plan mode.")
            }
            entry.snapshot.planMode = enabled
            touch(entry)
            persist(entry)
            continuation.resume(returning: entry.snapshot)
            return
        }
        if case .setAccess(_, let mode) = request {
            entry.snapshot.accessMode = mode
            touch(entry)
            persist(entry)
            if let runtime = entry.runtime {
                configureAccess(entry, runtime: runtime, mode: mode)
            } else {
                continuation.resume(returning: entry.snapshot)
                return
            }
        }
        if case .interrupt = request, entry.submitting {
            // No authoritative turn exists yet, so there is nothing to interrupt
            // gracefully. Fence the startup and settle its reply before stopping it.
            retireRuntime(entry)
            interrupted(entry, message: "Agent startup stopped. Send a message to retry.")
            touch(entry)
            persist(entry)
            settleSubmission(entry)
            continuation.resume(returning: entry.snapshot)
            return
        }
        var stagedAttachments: [StagedAgentAttachment] = []
        if case .send(_, let text, let model, let effort, let requestedProvider, let attachments) = request {
            guard entry.deliveryID == nil || entry.deliveryID == deliveryID else {
                throw ServiceError(.badRequest, "A queued prompt is being delivered.")
            }
            _ = try projectDirectory(entry.snapshot.project)
            try checkDirectory(entry.directory)
            if !entry.submitting, entry.snapshot.status == .working, let runtime = entry.runtime {
                guard requestedProvider == nil || requestedProvider == entry.snapshot.provider,
                      model == entry.snapshot.model, effort == entry.snapshot.reasoningEffort else {
                    throw ServiceError(.badRequest, "Model and reasoning changes apply after the current response.")
                }
                let userID = deliveryID ?? UUID().uuidString
                let attachmentRoot = root.appendingPathComponent("attachments", isDirectory: true)
                    .appendingPathComponent(id.description).appendingPathComponent(userID)
                let staged = try AgentAttachments.stage(attachments ?? [], root: attachmentRoot)
                try AgentAttachments.record(staged, root: attachmentRoot)
                let generation = entry.generation
                entry.submitting = true
                let pending = PendingReply(continuation)
                entry.pendingSubmission = pending
                queue.asyncAfter(deadline: .now() + submissionTimeout) { [self] in
                    guard !pending.finished else { return }
                    pending.task?.cancel()
                    receive(.failure("Follow-up delivery timed out. It may have reached the agent; review the conversation before retrying."), session: id, generation: generation)
                    settleSubmission(entry)
                }
                pending.task = Task {
                    do {
                        try await runtime.steer(text: incoming?.modelText ?? text, attachments: staged)
                        self.queue.async {
                            guard !pending.finished else { return }
                            pending.finished = true
                            if entry.pendingSubmission === pending { entry.pendingSubmission = nil }
                            guard entry.generation == generation else {
                                continuation.resume(throwing: AgentRuntimeError("The conversation changed before the message was accepted."))
                                return
                            }
                            entry.submitting = false
                            entry.snapshot.items.append(self.observedItem(Self.item(.init(id: userID, kind: .user, text: text,
                                attachments: attachments?.map(\.descriptor)), incoming), entry: entry))
                            // The running turn's reply also answers whoever asked in it.
                            if let asker = incoming?.requestedBy, let last = entry.snapshot.turns?.indices.last,
                               entry.snapshot.turns?[last].completedAt == nil, entry.snapshot.turns?[last].requestedBy == nil {
                                entry.snapshot.turns?[last].requestedBy = asker
                                entry.snapshot.turns?[last].upstream = incoming?.upstream
                            }
                            if incoming == nil { self.userSent(entry) }
                            self.touch(entry)
                            self.persist(entry)
                            continuation.resume(returning: entry.snapshot)
                            self.queue.async { self.drainReports(entry) }
                        }
                    } catch {
                        self.queue.async {
                            guard !pending.finished else { return }
                            pending.finished = true
                            if entry.pendingSubmission === pending { entry.pendingSubmission = nil }
                            if entry.generation == generation { entry.submitting = false }
                            try? FileManager.default.removeItem(at: attachmentRoot)
                            // The turn ended while the follow-up was on its way; its idle
                            // status is already applied, so the message starts a new turn.
                            guard error is AgentTurnFinishedError, entry.generation == generation,
                                  entry.snapshot.status != .working else {
                                continuation.resume(throwing: error)
                                return
                            }
                            do { try self.begin(request, continuation: continuation, deliveryID: deliveryID, incoming: incoming) }
                            catch { continuation.resume(throwing: error) }
                        }
                    }
                }
                return
            }
            guard !entry.submitting, entry.snapshot.status != .working, entry.snapshot.status != .waiting else {
                throw ServiceError(.badRequest, "The agent is already handling a message")
            }
            _ = try projectDirectory(entry.snapshot.project)
            try checkDirectory(entry.directory)
            let provider = requestedProvider ?? entry.snapshot.provider
            if provider != entry.snapshot.provider {
                guard entry.snapshot.providerSession == nil, !entry.hasSuccessfulTurn,
                      entry.snapshot.status == .idle || entry.snapshot.status == .failed else {
                    throw ServiceError(.badRequest, "An established conversation cannot switch providers. Open a new agent pane.")
                }
            }
            if let effort, !effort.isAccepted(provider: provider, model: model) {
                throw ServiceError(.badRequest, "\(provider.name) does not support \(effort.title) reasoning for this model")
            }
            let restart = provider != entry.snapshot.provider
                || (provider == .claude && (model != entry.snapshot.model || effort != entry.snapshot.reasoningEffort))
            if restart {
                guard !entry.hasSuccessfulTurn || entry.snapshot.providerSession != nil else {
                    throw ServiceError(.badRequest, "The provider has not supplied a session ID to resume this conversation")
                }
            }
            if entry.runtime == nil, entry.hasSuccessfulTurn, entry.snapshot.providerSession == nil {
                throw ServiceError(.badRequest, "The provider has not supplied a session ID to resume this conversation")
            }
            let userID = deliveryID ?? UUID().uuidString
            let attachmentRoot = root.appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(id.description, isDirectory: true)
                .appendingPathComponent(userID, isDirectory: true)
            do {
                stagedAttachments = try AgentAttachments.stage(attachments ?? [], root: attachmentRoot)
                try AgentAttachments.record(stagedAttachments, root: attachmentRoot)
            } catch {
                throw ServiceError(.badRequest, error.localizedDescription)
            }
            if restart, entry.runtime != nil { retireRuntime(entry) }
            if provider != entry.snapshot.provider || model != entry.snapshot.model {
                entry.snapshot.contextUsage = nil
                entry.snapshot.resolvedModel = nil
            }
            entry.snapshot.provider = provider
            let user = Self.item(AgentChatItem(id: userID, kind: .user, text: text,
                                               attachments: attachments?.map(\.descriptor)), incoming)
            entry.snapshot.items.append(observedItem(user, entry: entry))
            entry.snapshot.turns = (entry.snapshot.turns ?? []) + [AgentChatTurn(userItemID: user.id, startedAt: Date(),
                requestedBy: incoming?.requestedBy, upstream: incoming?.upstream)]
            if incoming == nil { userSent(entry) }
            let priorCheckpoint = entry.checkpointTask
            let captureDirectory = entry.directory
            let pendingDirectory = root.appendingPathComponent("checkpoints", isDirectory: true)
                .appendingPathComponent(id.description, isDirectory: true)
            entry.baselineTask = Task {
                await priorCheckpoint?.value
                return try? await runBlocking {
                    let store = AgentCheckpointStore()
                    let before = try store.capture(directory: captureDirectory)
                    do {
                        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
                        try JSONEncoder().encode(AgentCheckpointPending(turnID: user.id, before: before))
                            .write(to: pendingDirectory.appendingPathComponent("pending-" + user.id + ".json"), options: .atomic)
                        return before
                    } catch {
                        try? store.remove(before)
                        throw error
                    }
                }
            }
            entry.snapshot.model = model
            entry.snapshot.reasoningEffort = effort
            entry.snapshot.status = .working
            entry.submitting = true
            touch(entry)
            persist(entry)
        }
        if case .answer(_, let request, let answers, let cancelled) = request {
            if entry.snapshot.items.contains(where: { $0.id == request && $0.questionnaire != nil && $0.isComplete }) {
                continuation.resume(returning: entry.snapshot)
                return
            }
            guard !entry.approving.contains(request), let item = entry.snapshot.items.first(where: { $0.id == request && !$0.isComplete }),
                  let form = item.questionnaire, entry.runtime != nil else {
                throw ServiceError(.badRequest, "This question is no longer pending.")
            }
            try form.validate(answers: answers, cancelled: cancelled)
            entry.approving.insert(request)
        }
        if case .approve(_, let request, _) = request {
            guard !entry.submitting, entry.snapshot.status == .waiting,
                  !entry.approving.contains(request),
                  entry.snapshot.items.contains(where: { $0.id == request && $0.kind == .approval && !$0.isComplete && $0.questionnaire == nil }) else {
                throw ServiceError(.badRequest, "This approval is no longer pending")
            }
        }
        if entry.runtime == nil {
            guard case .send = request else {
                continuation.resume(returning: entry.snapshot)
                return
            }
            let generation = entry.generation
            entry.runtime = factory(entry.snapshot.provider, entry.directory, entry.snapshot.providerSession) {
                [weak self] event in
                self?.queue.async { [weak self] in self?.receive(event, session: id, generation: generation) }
            }
            if let runtime = entry.runtime {
                var environment = launchEnvironment
                environment["TAB_AGENT_ID"] = id.description
                environment[AgentContext.providedVariable] = "1"
                let coordinator = entry.snapshot.coordinator.map {
                    AgentContext.Coordinator(name: $0.name, agent: $0.session.description,
                                             reports: entry.snapshot.reportsToCoordinator ?? true)
                }
                let context = AgentContext(place: .agentPane(agent: id.description),
                                           project: projectContext(entry.snapshot.project),
                                           cli: cliDirectory.map { ($0 as NSString).appendingPathComponent(Executable.cli) },
                                           coordinator: coordinator)
                runtime.prepare(AgentLaunch(environment: environment, path: cliDirectory, forkSource: entry.forkSource,
                                            forkPoint: entry.forkPoint, instructions: context.text))
                configureAccess(entry, runtime: runtime, mode: entry.snapshot.accessMode ?? .standard)
            }
        }
        guard let runtime = entry.runtime else { throw ServiceError(.badRequest, "Agent unavailable") }
        let generation = entry.generation
        let model = entry.snapshot.model
        let effort = entry.snapshot.reasoningEffort
        let accessTask = entry.accessTask
        let baselineTask = entry.baselineTask
        if case .approve(_, let request, _) = request { entry.approving.insert(request) }
        if case .interrupt = request {
            guard entry.interrupting == nil else { throw ServiceError(.badRequest, "An interrupt is already pending") }
            entry.interrupting = UUID()
        }
        let pending = PendingReply(continuation)
        let turnAttachments = stagedAttachments
        let modelText = incoming?.modelText
        if case .send = request { entry.pendingSubmission = pending }
        queue.asyncAfter(deadline: .now() + submissionTimeout) { [self] in
            guard !pending.finished else { return }
            pending.finished = true
            pending.task?.cancel()
            if entry.pendingSubmission === pending { entry.pendingSubmission = nil }
            if entry.generation == generation, !stopping, entry.snapshot.status != .closed {
                receive(.failure("Agent submission timed out. The agent was stopped; send a message to retry."),
                        session: id, generation: generation)
            }
            continuation.resume(returning: entry.snapshot)
        }
        let planMode = entry.snapshot.planMode == true
        pending.task = Task { [self] in
            guard !Task.isCancelled else { return }
            let failure: Error?
            do {
                switch request {
                case .send(_, let text, _, _, _, _):
                    try await accessTask?.value
                    _ = await baselineTask?.value
                    try Task.checkCancellation()
                    try await runtime.setPlan(planMode)
                    try await runtime.send(text: modelText ?? text, model: model, reasoningEffort: effort,
                                           attachments: turnAttachments)
                case .setAccess: try await accessTask?.value
                case .approve(_, let request, let allow): try await runtime.approve(request: request, allow: allow)
                case .answer(_, let request, let answers, let cancelled): try await runtime.answer(request: request, answers: answers, cancelled: cancelled)
                case .interrupt: try await runtime.interrupt()
                default: break
                }
                failure = nil
            } catch { failure = error }
            queue.async { [self] in
                guard !pending.finished else { return }
                pending.finished = true
                if entry.pendingSubmission === pending { entry.pendingSubmission = nil }
                // Synchronous runtime callbacks were enqueued before this completion.
                if entry.generation == generation, entry.snapshot.status != .closed, !stopping {
                    if case .send = request { entry.submitting = false }
                    if case .approve(_, let request, _) = request { entry.approving.remove(request) }
                    if case .answer(_, let request, _, _) = request { entry.approving.remove(request) }
                    if let failure {
                        if case .interrupt = request {
                            entry.interrupting = nil
                            entry.snapshot.items.append(AgentChatItem(kind: .notice,
                                                                     text: "Interrupt failed: " + failure.localizedDescription))
                            touch(entry)
                        } else {
                            receive(.failure(failure.localizedDescription), session: id, generation: generation)
                        }
                    } else if case .interrupt = request {
                        if let interruption = entry.interrupting {
                            if entry.snapshot.status == .idle {
                                entry.interrupting = nil
                                entry.snapshot.items.append(AgentChatItem(kind: .notice, text: "Agent interrupted."))
                            } else {
                                entry.snapshot.items.append(AgentChatItem(kind: .notice,
                                                                         text: "Interrupt requested. Waiting for the agent to finish."))
                                queue.asyncAfter(deadline: .now() + interruptTimeout) { [self] in
                                    guard entry.generation == generation, entry.interrupting == interruption,
                                          !stopping, entry.snapshot.status != .closed else { return }
                                    receive(.failure("The agent did not finish interrupting in time and was stopped."),
                                            session: id, generation: generation)
                                }
                            }
                            touch(entry)
                        }
                    } else if case .approve(_, let approval, _) = request {
                        if let index = entry.snapshot.items.firstIndex(where: { $0.id == approval }) {
                            entry.snapshot.items[index].isComplete = true
                        }
                        if entry.snapshot.status == .waiting,
                           !entry.snapshot.items.contains(where: { $0.kind == .approval && !$0.isComplete }) {
                            entry.snapshot.status = .working
                        }
                        touch(entry)
                    }
                }
                persist(entry)
                continuation.resume(returning: entry.snapshot)
                self.drainInbox(entry)
                // A started turn can now take the reports that waited for it.
                if case .send = request, !entry.heldReports.isEmpty { queue.async { [self] in drainReports(entry) } }
            }
        }
    }

    private func receive(_ event: AgentRuntimeEvent, session: SessionId, generation: UUID) {
        guard !stopping, let entry = entries[session], entry.generation == generation,
              entry.snapshot.status != .closed else { return }
        if entry.stagingToolImages {
            guard !entry.deferredEventOverflow else { return }
            let bytes = deferredBytes(event)
            guard entry.deferredEvents.count < 512,
                  bytes <= Self.maximumDeferredEventBytes - entry.deferredEventBytes else {
                // Stop the producer instead of retaining an unbounded stream
                // behind slow disk I/O. The failure follows the in-flight image.
                entry.deferredEventOverflow = true
                entry.deferredEvents = [.failure("Agent output exceeded the pending media limit. Send a message to resume.")]
                entry.deferredEventBytes = 0
                let runtime = entry.runtime
                Task { runtime?.stop() }
                return
            }
            entry.deferredEvents.append(event)
            entry.deferredEventBytes += bytes
            return
        }
        if case .toolItem(let item, let images) = event {
            guard item.id.utf8.count <= 1024 else { return }
            let directory = root.appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(session.description, isDirectory: true)
                .appendingPathComponent(AgentToolImages.directoryName(item: item.id), isDirectory: true)
            entry.stagingToolImages = true
            let stage = stageToolImages
            Task { [weak self] in
                var stored = item
                do { try await runBlocking { try stage(images, directory) } }
                catch { stored.detail = (stored.detail ?? "") + "\nImage storage failed: " + error.localizedDescription }
                let completed = stored
                self?.queue.async { [weak self] in
                    guard let self, !self.stopping, entry.generation == generation,
                          entry.snapshot.status != .closed else { return }
                    let deferred = entry.deferredEvents
                    entry.stagingToolImages = false
                    entry.deferredEvents.removeAll()
                    entry.deferredEventBytes = 0
                    entry.deferredEventOverflow = false
                    self.receive(.item(completed), session: session, generation: generation)
                    for event in deferred { self.receive(event, session: session, generation: generation) }
                }
            }
            return
        }
        switch event {
        case .toolItem: return
        case .item(let item):
            guard item.id.utf8.count <= 1024 else { return }
            if item.kind == .approval, !item.isComplete,
               !entry.snapshot.items.contains(where: { $0.id == item.id }),
               entry.snapshot.items.filter({ $0.kind == .approval && !$0.isComplete }).count >= 128 {
                receive(.failure("Too many pending approvals. The agent was stopped."), session: session,
                        generation: generation)
                return
            }
            if let index = entry.snapshot.items.firstIndex(where: { $0.id == item.id }) {
                entry.snapshot.items[index] = observedItem(item, entry: entry, previous: entry.snapshot.items[index])
            } else { entry.snapshot.items.append(observedItem(item, entry: entry)) }
        case .textDelta(let id, let text):
            guard id.utf8.count <= 1024 else { return }
            if let index = entry.snapshot.items.firstIndex(where: { $0.id == id }) {
                entry.snapshot.items[index].text += text
                entry.snapshot.items[index].updatedAt = Date()
            } else {
                entry.snapshot.items.append(observedItem(AgentChatItem(id: id, kind: .assistant,
                                                         text: text, isComplete: false), entry: entry))
            }
        case .status(let status):
            if status == .idle, entry.interrupting == nil,
               entry.snapshot.status == .working || entry.snapshot.status == .waiting {
                entry.hasSuccessfulTurn = true
            }
            entry.snapshot.status = status
            let outcome: AgentChatTurn.Outcome? = status == .idle ? (entry.interrupting == nil ? .completed : .interrupted)
                : status == .failed ? .failed : status == .closed ? .cancelled : nil
            updateTurn(entry, status: status, outcome: outcome)
            if status == .idle, entry.interrupting != nil {
                entry.interrupting = nil
                entry.snapshot.items.append(AgentChatItem(kind: .notice, text: "Agent interrupted."))
            }
            if status == .failed || status == .closed { retireRuntime(entry) }
            if status == .idle || status == .failed || status == .closed {
                for index in entry.snapshot.items.indices { entry.snapshot.items[index].isComplete = true }
            }
        case .providerSession(let id):
            guard id.utf8.count <= 4096 else {
                receive(.failure("The agent returned an invalid session identifier."), session: session,
                        generation: generation)
                return
            }
            guard entry.snapshot.providerSession != id else { return }
            entry.snapshot.providerSession = id
            entry.forkSource = nil
            entry.forkPoint = nil
            entry.lastProviderMessage = nil
        case .providerMessage(let id):
            guard id.utf8.count <= 4096 else { return }
            entry.lastProviderMessage = id
            return
        case .contextUsage(let usage):
            guard usage.usedTokens >= 0, usage.contextWindow.map({ $0 > 0 }) ?? true,
                  entry.snapshot.contextUsage != usage else { return }
            entry.snapshot.contextUsage = usage
        case .planMode(let enabled):
            entry.snapshot.planMode = enabled
            persist(entry)
        case .commands(let commands):
            entry.snapshot.commands = Array(commands.filter {
                !$0.isEmpty && $0.utf8.count <= 128 &&
                $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_:.".unicodeScalars.contains($0) }
            }.prefix(256))
        case .resolvedModel(let model):
            guard !model.isEmpty, model.utf8.count <= 256, !model.contains("\0"),
                  entry.snapshot.resolvedModel != model else { return }
            entry.snapshot.resolvedModel = model
        case .failure(let message):
            entry.snapshot.status = .failed
            updateTurn(entry, status: .failed, outcome: .failed)
            entry.snapshot.items.append(observedItem(AgentChatItem(kind: .notice, text: message,
                workContext: .init(itemType: "error", sourceStatus: "failed")), entry: entry))
            retireRuntime(entry)
            for index in entry.snapshot.items.indices { entry.snapshot.items[index].isComplete = true }
        }
        touch(entry)
        if entry.snapshot.status == .idle || entry.snapshot.status == .failed || entry.snapshot.status == .closed {
            persist(entry)
        }
        if entry.snapshot.status == .failed || entry.snapshot.status == .closed {
            settleSubmission(entry)
            do { try mutateInbox(entry) { $0.paused = true } }
            catch { entry.inboxError = error.localizedDescription }
        }
        drainInbox(entry)
        if case .providerSession = event { persist(entry) }
        switch event {
        case .status, .failure:
            if !entry.heldReports.isEmpty { queue.async { [self] in drainReports(entry) } }
        default: break
        }
    }

    /// A new conversation `id` holding `from`'s transcript and choices. Its
    /// provider forks `from`'s conversation on the first message, so neither
    /// sees what the other says next. Claude forks at the message `from` had
    /// reached when the fork was made; Codex forks the whole thread as it is
    /// at the first message.
    private func fork(_ id: SessionId, from: SessionId, into project: ProjectId?) throws -> AgentChatSnapshot {
        guard let source = entries[from] else { throw ServiceError.unknownSession(from) }
        let project = project ?? source.snapshot.project
        if let entry = entries[id] {
            guard entry.snapshot.project == project else {
                throw ServiceError(.badRequest, "This agent session ID is already in use")
            }
            return entry.snapshot
        }
        guard !stopping else { throw ServiceError(.badRequest, "The server is stopping") }
        let folder = try projectDirectory(project)
        // A fork in its source's project keeps working where the source does.
        let directory = project == source.snapshot.project ? source.directory : folder
        try checkDirectory(directory)
        var snapshot = source.snapshot
        snapshot.session = id
        snapshot.project = project
        snapshot.revision = 0
        snapshot.status = .idle
        snapshot.turns = nil
        snapshot.items = snapshot.items.filter { $0.kind != .approval || $0.isComplete }
        for index in snapshot.items.indices { snapshot.items[index].isComplete = true }
        // A fork is nobody's worker and holds no reports until `delegate` says otherwise.
        snapshot.name = nil
        snapshot.coordinator = nil
        snapshot.reportsToCoordinator = nil
        snapshot.reportQueue = nil
        let entry = Entry(snapshot, directory: directory)
        entry.hasSuccessfulTurn = source.hasSuccessfulTurn
        if let pending = source.forkSource {
            entry.forkSource = pending
            entry.forkPoint = source.forkPoint
        } else {
            entry.forkSource = source.snapshot.providerSession
            entry.forkPoint = source.lastProviderMessage
        }
        entries[id] = entry
        touch(entry)
        persist(entry)
        return entry.snapshot
    }

    // MARK: Workers and reports

    /// Names conversation `id` and makes it `coordinator`'s worker, before its first message.
    private func delegate(_ id: SessionId, name: String?, coordinator: SessionId?, reports: Bool) throws -> AgentChatSnapshot {
        guard let entry = entries[id] else { throw ServiceError.unknownSession(id) }
        guard !stopping, entry.snapshot.status != .closed else {
            throw ServiceError(.badRequest, "The agent session is closed or the server is stopping")
        }
        guard entry.snapshot.turns?.isEmpty ?? true, entry.runtime == nil, !entry.submitting else {
            throw ServiceError(.badRequest, "Name an agent and give it a coordinator before its first message")
        }
        var normalized: String?
        if let name {
            guard let value = AgentChatSnapshot.normalizedName(name) else {
                throw ServiceError(.badRequest, "A name needs a letter or digit")
            }
            normalized = value
        }
        var peer: AgentPeer?
        var taken: Set<String> = []
        if let coordinator {
            guard let boss = entries[coordinator], boss.snapshot.status != .closed else {
                throw ServiceError(.badRequest, "The coordinator isn't open on this server")
            }
            let chain = coordinators(of: boss)
            guard !chain.contains(id) else { throw ServiceError(.badRequest, "An agent can't coordinate its own coordinator") }
            guard chain.count < AgentReports.maximumDepth else {
                throw ServiceError(.badRequest, "Workers can't be more than \(AgentReports.maximumDepth) levels deep")
            }
            let siblings = entries.values.filter {
                $0 !== entry && $0.snapshot.coordinator?.session == coordinator && $0.snapshot.status != .closed
            }
            guard siblings.count < AgentReports.maximumWorkers else {
                throw ServiceError(.badRequest,
                                   "An agent can have at most \(AgentReports.maximumWorkers) open workers; close some first")
            }
            taken = Set(siblings.compactMap(\.snapshot.name))
            peer = self.peer(boss)
        }
        entry.snapshot.name = normalized.map { AgentReports.unique($0, taken: taken) }
        entry.snapshot.coordinator = peer
        entry.snapshot.reportsToCoordinator = peer == nil ? nil : reports
        touch(entry)
        persist(entry)
        return entry.snapshot
    }

    /// The coordinators above `entry`, nearest first.
    private func coordinators(of entry: Entry) -> [SessionId] {
        var chain: [SessionId] = []
        var current = entry
        while let next = current.snapshot.coordinator?.session, !chain.contains(next), chain.count <= 8 {
            chain.append(next)
            guard let found = entries[next] else { break }
            current = found
        }
        return chain
    }

    private func peer(_ entry: Entry) -> AgentPeer {
        AgentPeer(session: entry.snapshot.session, project: entry.snapshot.project, provider: entry.snapshot.provider,
                  name: entry.snapshot.displayName)
    }

    /// `text` from `sender` to `entry`, whose reply goes back to `sender`.
    private func incomingMessage(_ text: String, to entry: Entry, from sender: Entry, task: Bool) -> Incoming {
        let fromCoordinator = entry.snapshot.coordinator?.session == sender.snapshot.session
        let reports = fromCoordinator ? entry.snapshot.reportsToCoordinator ?? true : true
        let peer = self.peer(sender)
        // The sender's running turn may itself be work for another agent.
        let upstream = sender.snapshot.turns?.last.flatMap { $0.completedAt == nil ? $0.requestedBy : nil }
        return Incoming(modelText: AgentReports.message(text, from: peer, reports: reports), peer: peer,
                        itemType: AgentPeerItemType.agentMessage, requestKind: task ? AgentPeerItemType.taskRequest : nil,
                        requestedBy: reports ? sender.snapshot.session : nil, upstream: reports ? upstream : nil)
    }

    /// `item` marked as coming from another agent.
    private static func item(_ item: AgentChatItem, _ incoming: Incoming?) -> AgentChatItem {
        guard let incoming else { return item }
        var item = item
        item.peer = incoming.peer
        item.detail = incoming.detail
        item.workContext = AgentChatWorkContext(itemType: incoming.itemType, sourceStatus: incoming.sourceStatus,
                                                requestKind: incoming.requestKind)
        return item
    }

    /// Shows `worker` in its coordinator's conversation, once.
    private func announce(_ worker: Entry, to coordinator: Entry, task: String) {
        worker.announced = true
        persist(worker)
        let id = "worker:" + worker.snapshot.session.description
        guard !coordinator.snapshot.items.contains(where: { $0.id == id }) else { return }
        let peer = self.peer(worker)
        coordinator.snapshot.items.append(observedItem(AgentChatItem(id: id, kind: .notice, text: "Started worker " + peer.name,
            detail: AgentReports.clipped(task), workContext: AgentChatWorkContext(itemType: AgentPeerItemType.workerStarted),
            peer: peer), entry: coordinator))
        touch(coordinator)
        persist(coordinator)
    }

    /// The user wrote to `entry` themselves: agent-driven delivery may go on.
    private func userSent(_ entry: Entry) {
        entry.unattendedDeliveries = 0
        entry.deliveryFailures = 0
        guard entry.reportsPaused else { return }
        entry.reportsPaused = false
        syncReportQueue(entry)
    }

    /// `by` read the reply of `id`'s turn `turn` itself; it isn't delivered again.
    private func acknowledge(_ id: SessionId, turn: String, by: SessionId) throws -> AgentChatSnapshot {
        guard let worker = entries[id] else { throw ServiceError.unknownSession(id) }
        guard let index = worker.snapshot.turns?.firstIndex(where: { $0.userItemID == turn }),
              worker.snapshot.turns?[index].requestedBy == by else { return worker.snapshot }
        if let coordinator = entries[by] {
            let held = coordinator.heldReports.count
            coordinator.heldReports.removeAll { $0.worker.session == id && $0.turn == turn }
            if coordinator.heldReports.count != held {
                syncReportQueue(coordinator)
                touch(coordinator)
                persist(coordinator)
            }
        }
        if worker.snapshot.turns?[index].report != .delivered {
            worker.snapshot.turns?[index].report = .acknowledged
            touch(worker)
            persist(worker)
        }
        return worker.snapshot
    }

    /// Hands each settled turn that another agent asked for to that agent, once.
    private func routeReports(_ worker: Entry) {
        guard !stopping, var turns = worker.snapshot.turns else { return }
        var changed = false
        for index in turns.indices where turns[index].completedAt != nil && turns[index].report == nil {
            guard let asker = turns[index].requestedBy else { continue }
            changed = true
            guard let coordinator = entries[asker], coordinator.snapshot.status != .closed else {
                turns[index].report = .dropped
                continue
            }
            let outcome = turns[index].outcome ?? .completed
            let next = turns.indices.contains(index + 1) ? turns[index + 1].userItemID : nil
            let report = AgentHeldReport(worker: peer(worker), turn: turns[index].userItemID, outcome: outcome,
                reply: AgentReports.reply(turn: turns[index].userItemID, next: next, items: worker.snapshot.items, outcome: outcome),
                upstream: turns[index].upstream, settledAt: turns[index].completedAt ?? Date())
            if !coordinator.heldReports.contains(where: { $0.worker.session == report.worker.session && $0.turn == report.turn }) {
                // A coordinator that never takes its reports keeps only the latest.
                if coordinator.heldReports.count >= 64 { coordinator.heldReports.removeFirst() }
                coordinator.heldReports.append(report)
            }
            turns[index].report = .held
            syncReportQueue(coordinator)
            touch(coordinator)
            persist(coordinator)
            queue.asyncAfter(deadline: .now() + reportGrace) { [self] in drainReports(coordinator) }
        }
        guard changed else { return }
        worker.snapshot.turns = turns
        touch(worker)
        persist(worker)
    }

    /// Delivers `entry`'s next ready report, if it can take one now; each
    /// delivery drains again when it lands.
    private func drainReports(_ entry: Entry) {
        guard !stopping, !entry.deliveringReport, !entry.heldReports.isEmpty else { return }
        guard entry.snapshot.status != .closed else { return dropReports(entry) }
        let now = Date()
        let forced = entry.forceDelivery
        guard let index = entry.heldReports.firstIndex(where: {
            forced || $0.settledAt.addingTimeInterval(reportGrace) <= now
        }) else {
            if let ready = entry.heldReports.map({ $0.settledAt.addingTimeInterval(reportGrace) }).min() {
                queue.asyncAfter(deadline: .now() + max(0.05, ready.timeIntervalSince(now))) { [self] in drainReports(entry) }
            }
            return
        }
        // The user's own queued prompts go first; reports join the turn they start.
        let userQueued = !entry.inbox.paused && entry.inbox.records.contains { $0.display?.state == .queued }
        let delivery = AgentReports.delivery(status: entry.snapshot.status,
                                             submitting: entry.submitting || entry.deliveryID != nil
                                                || (userQueued && entry.snapshot.status == .idle),
                                             hasRuntime: entry.runtime != nil,
                                             lastOutcome: entry.snapshot.turns?.last?.outcome,
                                             paused: entry.reportsPaused, forced: forced)
        guard delivery != .hold else { return }
        let report = entry.heldReports.remove(at: index)
        let files = changedFiles(report)
        entry.deliveringReport = true
        syncReportQueue(entry)
        let incoming = Incoming(modelText: AgentReports.report(report, files: files), peer: report.worker,
                                itemType: AgentPeerItemType.workerReport, sourceStatus: report.outcome.rawValue,
                                detail: files.isEmpty ? nil : files.joined(separator: "\n"),
                                requestedBy: report.upstream)
        let request = AgentChatRequest.send(session: entry.snapshot.session, text: report.reply,
                                            model: entry.snapshot.model, reasoningEffort: entry.snapshot.reasoningEffort)
        Task { [self] in
            do {
                _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AgentChatSnapshot, Error>) in
                    queue.async { [self] in
                        do { try begin(request, continuation: continuation, incoming: incoming) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                queue.async { [self] in delivered(report, to: entry) }
            } catch {
                queue.async { [self] in deliveryFailed(report, to: entry, error: error) }
            }
        }
    }

    /// The files the report's turn changed, once its checkpoint is ready.
    private func changedFiles(_ report: AgentHeldReport) -> [String] {
        entries[report.worker.session]?.snapshot.turns?.first { $0.userItemID == report.turn }?
            .checkpoint?.files.map(\.path) ?? []
    }

    private func delivered(_ report: AgentHeldReport, to entry: Entry) {
        entry.deliveringReport = false
        entry.deliveryFailures = 0
        if entry.heldReports.isEmpty { entry.forceDelivery = false }
        entry.unattendedDeliveries += 1
        if entry.unattendedDeliveries >= AgentReports.maximumUnattendedDeliveries, !entry.reportsPaused {
            entry.reportsPaused = true
            entry.snapshot.items.append(observedItem(AgentChatItem(kind: .notice, text: "Paused worker reports after "
                + "\(AgentReports.maximumUnattendedDeliveries) in a row without you. Send a message, or deliver them, to go on."),
                entry: entry))
        }
        setReport(.delivered, of: report)
        syncReportQueue(entry)
        touch(entry)
        persist(entry)
        drainReports(entry)
    }

    private func deliveryFailed(_ report: AgentHeldReport, to entry: Entry, error: Error) {
        entry.deliveringReport = false
        guard !stopping, entry.snapshot.status != .closed else {
            setReport(.dropped, of: report)
            return
        }
        entry.heldReports.insert(report, at: 0)
        entry.deliveryFailures += 1
        if entry.deliveryFailures >= AgentReports.maximumDeliveryFailures {
            entry.reportsPaused = true
            entry.deliveryFailures = 0
            entry.snapshot.items.append(observedItem(AgentChatItem(kind: .notice, text: "Paused worker reports: "
                + error.localizedDescription + " Send a message, or deliver them, to try again."), entry: entry))
        } else {
            queue.asyncAfter(deadline: .now() + AgentReports.retryDelay) { [self] in drainReports(entry) }
        }
        syncReportQueue(entry)
        touch(entry)
        persist(entry)
    }

    /// A closed coordinator takes no reports.
    private func dropReports(_ entry: Entry) {
        guard !entry.heldReports.isEmpty || entry.reportsPaused else { return }
        for report in entry.heldReports { setReport(.dropped, of: report) }
        entry.heldReports.removeAll()
        entry.reportsPaused = false
        entry.forceDelivery = false
        syncReportQueue(entry)
        persist(entry)
    }

    private func setReport(_ state: AgentChatTurn.Report, of report: AgentHeldReport) {
        guard let worker = entries[report.worker.session],
              let index = worker.snapshot.turns?.firstIndex(where: { $0.userItemID == report.turn }),
              worker.snapshot.turns?[index].report != state else { return }
        worker.snapshot.turns?[index].report = state
        touch(worker)
        persist(worker)
    }

    private func syncReportQueue(_ entry: Entry) {
        let held = entry.heldReports.count
        let queue = held == 0 && !entry.reportsPaused ? nil : AgentReportQueue(held: held, paused: entry.reportsPaused)
        if entry.snapshot.reportQueue != queue { entry.snapshot.reportQueue = queue }
    }

    /// Provider conversations that open Tab conversations continue.
    func openProviderSessions() -> Set<String> {
        queue.sync {
            Set(entries.values.filter { $0.snapshot.status != .closed }.compactMap(\.snapshot.providerSession))
        }
    }

    /// Continues a conversation a provider CLI saved outside Tab; see `AgentHistoryImport`.
    /// `transcript` reads the saved conversation for the project's folder.
    func importHistory(_ request: AgentHistoryImport,
                       transcript: @escaping @Sendable (String) throws -> AgentHistoryTranscript) async throws -> AgentChatSnapshot {
        try request.validate()
        if let existing = try queue.sync(execute: { try importTarget(request) }) { return existing }
        let directory = try queue.sync { () throws -> String in
            let directory = try projectDirectory(request.project)
            try checkDirectory(directory)
            return directory
        }
        let saved = try await runBlocking { try transcript(directory) }
        return try queue.sync {
            if let existing = try importTarget(request) { return existing }
            var snapshot = entries[request.session]?.snapshot
                ?? AgentChatSnapshot(session: request.session, project: request.project, provider: request.provider)
            snapshot.provider = request.provider
            snapshot.providerSession = request.providerSession
            snapshot.model = nil
            snapshot.reasoningEffort = nil
            snapshot.resolvedModel = saved.resolvedModel
            snapshot.contextUsage = nil
            snapshot.turns = nil
            snapshot.status = .idle
            snapshot.items = saved.items.map { item in
                var item = item
                item.isComplete = true
                return item
            }
            snapshot.items.append(AgentChatItem(kind: .notice,
                text: "Continued from \(request.provider.name). New messages carry on this conversation."))
            let entry = Entry(snapshot, directory: directory)
            entry.hasSuccessfulTurn = true
            entries[request.session] = entry
            touch(entry)
            persist(entry)
            return entry.snapshot
        }
    }

    /// The conversation that already continues `request`'s, or `nil` when
    /// `request.session` is free to take it.
    private func importTarget(_ request: AgentHistoryImport) throws -> AgentChatSnapshot? {
        guard !stopping else { throw ServiceError(.badRequest, "The server is stopping") }
        if let existing = entries.values.first(where: {
            $0.snapshot.status != .closed && $0.snapshot.provider == request.provider
                && $0.snapshot.providerSession == request.providerSession
        }) {
            return existing.snapshot
        }
        guard let entry = entries[request.session] else { return nil }
        guard entry.snapshot.project == request.project, entry.snapshot.items.isEmpty, entry.snapshot.providerSession == nil,
              entry.snapshot.status == .idle, entry.runtime == nil, !entry.submitting, !entry.hasSuccessfulTurn else {
            throw ServiceError(.badRequest, "This agent session ID is already in use")
        }
        return nil
    }

    private func interrupted(_ entry: Entry, message: String) {

        entry.snapshot.status = .failed
        updateTurn(entry, status: .failed, outcome: .interrupted)
        entry.snapshot.revision &+= 1
        for index in entry.snapshot.items.indices { entry.snapshot.items[index].isComplete = true }
        entry.snapshot.items.append(AgentChatItem(kind: .notice, text: message))
        bound(entry)
    }

    private func close(_ entry: Entry) {
        guard entry.snapshot.status != .closed else { return }
        entry.deliveryCancelled = true
        if !entry.inbox.visible.isEmpty {
            do {
                try mutateInbox(entry) { inbox in
                    inbox.paused = true
                    for index in inbox.records.indices { inbox.records[index].prompt = nil; inbox.records[index].display = nil }
                }
            } catch { entry.snapshot.items.append(AgentChatItem(kind: .notice, text: "Could not save queue cancellation: " + error.localizedDescription)) }
        }
        retireRuntime(entry)
        entry.snapshot.status = .closed
        updateTurn(entry, status: .closed, outcome: .cancelled)
        for index in entry.snapshot.items.indices { entry.snapshot.items[index].isComplete = true }
        dropReports(entry)
        touch(entry)
        persist(entry)
        settleSubmission(entry)
    }

    private func retireRuntime(_ entry: Entry) {
        entry.pendingSubmission?.task?.cancel()
        entry.generation = UUID()
        let runtime = entry.runtime
        entry.runtime = nil
        entry.submitting = false
        entry.approving.removeAll()
        entry.interrupting = nil
        entry.accessTask = nil
        clearDeferredEvents(entry)
        Task { runtime?.stop() }
    }

    private static let maximumDeferredEventBytes = 8 * AgentChatAttachment.maxPayloadBytes + 512 * 1024

    private func deferredBytes(_ event: AgentRuntimeEvent) -> Int {
        switch event {
        case .item(let item): return item.transcriptByteCount
        case .toolItem(let item, let images):
            var bytes = min(item.transcriptByteCount, Self.maximumDeferredEventBytes + 1)
            for image in images {
                guard image.data.count <= Self.maximumDeferredEventBytes - min(bytes, Self.maximumDeferredEventBytes) else {
                    return Self.maximumDeferredEventBytes + 1
                }
                bytes += image.data.count
            }
            return bytes
        case .commands(let commands): return commands.reduce(0) { $0 + $1.utf8.count }
        case .textDelta(_, let text), .failure(let text), .providerSession(let text), .resolvedModel(let text): return text.utf8.count
        default: return 128
        }
    }

    private func clearDeferredEvents(_ entry: Entry) {
        entry.stagingToolImages = false
        entry.deferredEvents.removeAll()
        entry.deferredEventBytes = 0
        entry.deferredEventOverflow = false
    }

    @discardableResult
    private func configureAccess(_ entry: Entry, runtime: any AgentSessionRuntime,
                                 mode: AgentAccessMode) -> Task<Void, Error> {
        let previous = entry.accessTask
        let task = Task {
            // Preserve accepted mode-change order even when concurrent request Tasks start out of order.
            _ = try? await previous?.value
            try await runtime.setAccess(mode)
        }
        entry.accessTask = task
        return task
    }

    private func settleSubmission(_ entry: Entry) {
        guard let pending = entry.pendingSubmission else { return }
        entry.pendingSubmission = nil
        guard !pending.finished else { return }
        pending.finished = true
        pending.continuation.resume(returning: entry.snapshot)
    }

    private func observedItem(_ value: AgentChatItem, entry: Entry, previous: AgentChatItem? = nil) -> AgentChatItem {
        var item = value
        item.questionnaire = item.questionnaire ?? previous?.questionnaire
        let now = Date()
        item.createdAt = item.createdAt ?? previous?.createdAt ?? item.tool?.startedAt ?? now
        item.updatedAt = item.updatedAt ?? now
        var context = item.workContext ?? previous?.workContext ?? AgentChatWorkContext()
        context.runID = context.runID ?? previous?.workContext?.runID
            ?? (item.kind == .user ? "native-turn:" + item.id : entry.snapshot.turns?.last.map { "native-turn:" + $0.userItemID })
        if context.itemType == nil {
            switch item.kind {
            case .user: context.itemType = "user_message"
            case .assistant: context.itemType = "assistant_message"
            case .approval: context.itemType = "approval_request"
            case .notice: context.itemType = "system_notice"
            case .tool:
                if item.tool?.presentsCommand == true { context.itemType = "command_execution" }
                else {
                    switch item.tool?.presentation {
                    case .fileChange: context.itemType = "file_change"
                    case .fileSearch: context.itemType = "file_search"
                    case .webSearch: context.itemType = "web_search"
                    default: context.itemType = "dynamic_tool"
                    }
                }
            }
        }
        item.workContext = context
        return item
    }

    private func updateTurn(_ entry: Entry, status: AgentChatStatus, outcome: AgentChatTurn.Outcome? = nil) {
        guard var turns = entry.snapshot.turns, let index = turns.indices.last,
              turns[index].completedAt == nil else { return }
        turns[index].status = status
        if status == .idle || status == .failed || status == .closed {
            turns[index].completedAt = max(Date(), turns[index].startedAt)
            turns[index].outcome = outcome
            captureCompletedTurn(entry, turnID: turns[index].userItemID)
            // After this event lands, so a failure's notice is part of the report.
            if turns[index].requestedBy != nil { queue.async { [self] in routeReports(entry) } }
        }
        entry.snapshot.turns = turns
    }

    /// Startup recovery is idempotent: a final record can precede its transcript
    /// revision on disk, and a persisted baseline can outlive an interrupted run.
    private func restoreCheckpoints(_ entry: Entry) {
        let directory = root.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(entry.snapshot.session.description, isDirectory: true)
        guard var turns = entry.snapshot.turns else { return }
        var pending: AgentCheckpointPending?
        for index in turns.indices where turns[index].checkpoint == nil {
            let id = turns[index].userItemID
            guard UUID(uuidString: id) != nil else { continue }
            if let data = try? Data(contentsOf: directory.appendingPathComponent(id + ".json")),
               let record = try? JSONDecoder().decode(AgentCheckpointRecord.self, from: data) {
                turns[index].checkpoint = record.summary(id: id)
            } else if index == turns.indices.last,
                      let data = try? Data(contentsOf: directory.appendingPathComponent("pending-" + id + ".json")),
                      let value = try? JSONDecoder().decode(AgentCheckpointPending.self, from: data),
                      value.turnID == id, value.before.directory == entry.directory {
                pending = value
            }
        }
        entry.snapshot.turns = turns
        if let pending {
            entry.baselineTask = Task { pending.before }
            // Already-terminal turns do not pass through updateTurn on startup.
            if turns.last?.completedAt != nil { captureCompletedTurn(entry, turnID: pending.turnID) }
        }
    }

    private func captureCompletedTurn(_ entry: Entry, turnID: String) {
        guard let baseline = entry.baselineTask else { return }
        entry.baselineTask = nil
        let directory = entry.directory
        let destination = root.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(entry.snapshot.session.description, isDirectory: true)
        entry.checkpointTask = Task { [weak self] in
            guard let before = await baseline.value else { return }
            do {
                let summary = try await runBlocking {
                    let store = AgentCheckpointStore()
                    let after = try store.capture(directory: directory)
                    do {
                        let files = try store.files(from: before, to: after)
                        let id = turnID
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                        let record = AgentCheckpointRecord(before: before, after: after, files: files)
                        try JSONEncoder().encode(record).write(to: destination.appendingPathComponent(id + ".json"), options: .atomic)
                        return record.summary(id: id)
                    } catch {
                        try? store.remove(after)
                        throw error
                    }
                }
                self?.queue.async { [weak self] in
                    guard let self, !self.stopping,
                          let index = entry.snapshot.turns?.firstIndex(where: { $0.userItemID == turnID }) else { return }
                    entry.snapshot.turns?[index].checkpoint = summary
                    self.touch(entry)
                    self.persist(entry)
                }
            } catch {
                // Keep the durable baseline pinned so restart recovery can retry.
                ServerLog.error("agent checkpoint unavailable: \(error)")
            }
        }
    }

    /// Called before removing a project/worktree, including conversations never attached to a client.
    func close(project: ProjectId, directory: String? = nil) {
        queue.sync {
            for entry in entries.values {
                let inside = directory.map { WorktreeProcesses.isInside(Catalog.canonical(entry.directory),
                                                                        Catalog.canonical($0)) } ?? false
                if entry.snapshot.project == project || inside { close(entry) }
            }
        }
    }

    func shutdown() {
        let runtimes: [any AgentSessionRuntime] = queue.sync {
            stopping = true
            var runtimes: [any AgentSessionRuntime] = []
            for entry in entries.values {
                entry.pendingSubmission?.task?.cancel()
                entry.generation = UUID()
                if let runtime = entry.runtime { runtimes.append(runtime) }
                entry.runtime = nil
                if entry.snapshot.status == .working || entry.snapshot.status == .waiting {
                    interrupted(entry, message: "Agent interrupted when the server stopped. Send a message to resume.")
                }
                entry.submitting = false
                entry.approving.removeAll()
                entry.interrupting = nil
                entry.accessTask = nil
                clearDeferredEvents(entry)
                persist(entry)
                settleSubmission(entry)
            }
            return runtimes
        }
        for runtime in runtimes { runtime.stop() }
        writer.sync {}
    }

    func refuseNewRequests() { queue.sync { stopping = true } }

    /// Atomically checks ownership and reserves the store for an idle shutdown.
    /// A create either wins first and makes this fail, or observes the refusal.
    func tryRefuseIfIdle() -> Bool {
        queue.sync {
            guard !stopping,
                  !entries.values.contains(where: { $0.snapshot.status != .closed || $0.runtime != nil || $0.submitting }) else {
                return false
            }
            stopping = true
            return true
        }
    }

    private func touch(_ entry: Entry) {
        activityChanged(entry.snapshot, entry.directory)
        bound(entry)
        entry.snapshot.revision &+= 1
        if !entry.notifying {
            entry.notifying = true
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                entry.notifying = false
                guard !stopping else { return }
                changed(entry.snapshot.session, entry.snapshot.revision)
            }
        }
        if !entry.checkpointing {
            entry.checkpointing = true
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in
                entry.checkpointing = false
                guard !stopping else { return }
                persist(entry)
            }
        }
    }

    private func bound(_ entry: Entry) {
        // Even worst-case six-byte JSON escapes for all 512 KiB of bodies and
        // 512 x 1 KiB IDs stay comfortably below the 16 MiB control-frame limit.
        entry.snapshot.items.removeAll { $0.id.utf8.count > 1024 }
        if let id = entry.snapshot.providerSession, id.utf8.count > 4096 { entry.snapshot.providerSession = nil }
        if let model = entry.snapshot.model, model.utf8.count > 256 { entry.snapshot.model = nil }
        if let model = entry.snapshot.resolvedModel, model.utf8.count > 256 { entry.snapshot.resolvedModel = nil }
        if let usage = entry.snapshot.contextUsage,
           usage.usedTokens < 0 || (usage.contextWindow.map({ $0 <= 0 }) ?? false) {
            entry.snapshot.contextUsage = nil
        }
        if entry.snapshot.items.filter({ $0.kind == .approval && !$0.isComplete }).count > 128 {
            entry.snapshot.status = .failed
            updateTurn(entry, status: .failed, outcome: .failed)
            for index in entry.snapshot.items.indices { entry.snapshot.items[index].isComplete = true }
        }
        // Retain pending permission IDs even when later tool/output rows overflow.
        // At most 128 are admitted; reserve up to 256 KiB for their display text.
        let pending = entry.snapshot.items.indices.filter {
            entry.snapshot.items[$0].kind == .approval && !entry.snapshot.items[$0].isComplete
        }
        let latestUser = entry.snapshot.items.indices.last { entry.snapshot.items[$0].kind == .user }
        let priority = pending + (latestUser.map { [$0] } ?? [])
        let prioritySet = Set(priority)
        let recent = entry.snapshot.items.indices.filter { !prioritySet.contains($0) }.suffix(512 - priority.count)
        entry.snapshot.items = (priority + recent).sorted().map { entry.snapshot.items[$0] }
        let userID = entry.snapshot.items.last { $0.kind == .user }?.id
        var remaining = 512 * 1024
        var preserved: Set<String> = []
        for index in entry.snapshot.items.indices {
            let item = entry.snapshot.items[index]
            let pending = item.kind == .approval && !item.isComplete
            guard pending || item.id == userID else { continue }
            if let bounded = boundedItem(item, budget: pending ? min(remaining, max(2048, (item.questionnaire?.transcriptByteCount ?? 0) + 1024)) : min(64 * 1024, remaining), pending: pending) {
                entry.snapshot.items[index] = bounded
                remaining -= bounded.transcriptByteCount
                preserved.insert(item.id)
            }
        }
        var remove: [Int] = []
        for index in entry.snapshot.items.indices.reversed() {
            let item = entry.snapshot.items[index]
            if preserved.contains(item.id) { continue }
            guard let bounded = boundedItem(item, budget: remaining) else { remove.append(index); continue }
            entry.snapshot.items[index] = bounded
            remaining -= bounded.transcriptByteCount
        }
        for index in remove { entry.snapshot.items.remove(at: index) }
        if let turns = entry.snapshot.turns {
            let users = Set(entry.snapshot.items.filter { $0.kind == .user }.map(\.id))
            var retained = Array(turns.filter { users.contains($0.userItemID) }.suffix(512))
            var checkpointBudget = 64 * 1024
            for index in retained.indices.reversed() {
                guard var checkpoint = retained[index].checkpoint else { continue }
                let bytes = checkpoint.files.reduce(0) { $0 + $1.path.utf8.count + 64 }
                if bytes > checkpointBudget {
                    checkpoint.files = []
                    checkpoint.truncated = checkpoint.totalFiles > 0
                } else { checkpointBudget -= bytes }
                retained[index].checkpoint = checkpoint
            }
            entry.snapshot.turns = retained
        }
    }

    private func boundedItem(_ source: AgentChatItem, budget: Int, pending: Bool = false) -> AgentChatItem? {
        guard budget > 0 else { return nil }
        var item = source
        var remaining = budget
        // Reserve all non-body fields before clipping compatibility text/tool data.
        // The same accounting as validation includes observed dates and work IDs.
        remaining -= item.transcriptByteCount - item.text.utf8.count
            - (item.detail?.utf8.count ?? 0) - (item.tool?.transcriptByteCount ?? 0)
        guard remaining >= 0 else { return nil }
        if let tool = item.tool {
            item.tool = boundedTool(tool, budget: min(32 * 1024, max(0, remaining - 1024)))
            if item.tool == nil {
                guard pending else { return nil }
                item.detail = "[Tool metadata truncated]\n" + (item.detail ?? "")
            }
            remaining -= item.tool?.transcriptByteCount ?? 0
        }
        let detailReserve = min(truncationMarker.utf8.count, item.detail?.utf8.count ?? 0)
        let textBudget = min(pending ? 512 : 64 * 1024, max(0, remaining - detailReserve))
        if textBudget < truncationMarker.utf8.count, item.text.utf8.count > textBudget { return nil }
        item.text = clipped(item.text, bytes: textBudget)
        remaining -= item.text.utf8.count
        if let detail = item.detail { item.detail = clipped(detail, bytes: min(pending ? 1536 : 16 * 1024, max(0, remaining))) }
        return item.transcriptByteCount <= budget ? item : nil
    }

    private func boundedTool(_ source: AgentToolActivity, budget: Int) -> AgentToolActivity? {
        let note = "\n[Tool metadata truncated]"
        guard budget >= 512 + note.utf8.count else { return nil }
        if source.transcriptByteCount <= budget,
           (source.name?.utf8.count ?? 0) <= 256,
           (source.input?.utf8.count ?? 0) <= 8 * 1024,
           (source.output?.utf8.count ?? 0) <= 16 * 1024,
           (source.filePaths?.count ?? 0) <= 32, (source.urls?.count ?? 0) <= 32,
           (source.fileChanges?.count ?? 0) <= 32,
           (source.filePaths ?? []).allSatisfy({ $0.utf8.count <= 1024 }),
           (source.urls ?? []).allSatisfy({ $0.utf8.count <= 2048 }),
           (source.fileChanges ?? []).allSatisfy({ $0.path.utf8.count <= 1024
               && ($0.diff?.utf8.count ?? 0) <= 8 * 1024 && ($0.kind?.utf8.count ?? 0) <= 64 }) {
            return source
        }
        var tool = source
        var remaining = budget - 512 - note.utf8.count
        var truncated = source.output?.hasSuffix(note) == true
        func take(_ text: String?, limit: Int) -> String? {
            guard let text else { return nil }
            let bytes = min(limit, remaining)
            if text.utf8.count > bytes { truncated = true }
            guard bytes >= truncationMarker.utf8.count || text.utf8.count <= bytes else { return nil }
            let value = clipped(text, bytes: bytes)
            remaining -= value.utf8.count
            return value
        }
        func strings(_ values: [String]?, limit: Int) -> [String]? {
            guard let values else { return nil }
            if values.count > 32 { truncated = true }
            var result: [String] = []
            for value in values.prefix(32) {
                guard remaining >= 8 else { truncated = true; break }
                remaining -= 8
                guard let text = take(value, limit: limit) else { remaining += 8; break }
                result.append(text)
            }
            return result
        }
        tool.name = take(source.name, limit: 256)
        tool.input = take(source.input, limit: 8 * 1024)
        let output = source.output.map { $0.hasSuffix(note) ? String($0.dropLast(note.count)) : $0 }
        tool.output = take(output, limit: 16 * 1024 - note.utf8.count)
        tool.filePaths = strings(source.filePaths, limit: 1024)
        tool.urls = strings(source.urls, limit: 2048)
        if let changes = source.fileChanges {
            if changes.count > 32 { truncated = true }
            var result: [AgentToolActivity.FileChange] = []
            for change in changes.prefix(32) {
                guard remaining >= 64 else { truncated = true; break }
                remaining -= 64
                guard let path = take(change.path, limit: 1024) else { remaining += 64; break }
                result.append(.init(path: path, diff: take(change.diff, limit: 8 * 1024), kind: take(change.kind, limit: 64)))
            }
            tool.fileChanges = result
        }
        func reserve(_ bytes: Int) -> Bool {
            guard remaining >= bytes else { truncated = true; return false }
            remaining -= bytes
            return true
        }
        tool.searchPatterns = strings(source.searchPatterns, limit: 2048)
        if let results = source.webResults {
            if results.count > 32 { truncated = true }
            tool.webResults = results.prefix(32).compactMap { result in
                guard reserve(64) else { return nil }
                return .init(title: take(result.title, limit: 1024), url: take(result.url, limit: 2048),
                             snippet: take(result.snippet, limit: 8000))
            }
        }
        tool.fileSearchDetails = nil
        if let details = source.fileSearchDetails, reserve(64) {
            var bounded = AgentToolActivity.FileSearchDetails(pattern: take(details.pattern, limit: 2048))
            if let results = details.results {
                if results.count > 32 { truncated = true }
                bounded.results = results.prefix(32).compactMap { result in
                    guard reserve(128), let name = take(result.fileName, limit: 1024), !name.isEmpty else { return nil }
                    return .init(fileName: name, line: result.line, column: result.column,
                                 preview: take(result.preview, limit: 8000))
                }
            }
            tool.fileSearchDetails = bounded
        }
        tool.fileChangeDetails = nil
        if let details = source.fileChangeDetails, reserve(128),
           let name = take(details.fileName, limit: 1024), !name.isEmpty {
            var bounded = AgentToolActivity.FileChangeDetails(fileName: name, diff: take(details.diff, limit: 8 * 1024),
                                                               additions: details.additions, deletions: details.deletions)
            if let operations = details.operations {
                if operations.count > 32 { truncated = true }
                bounded.operations = operations.prefix(32).compactMap { operation in
                    guard reserve(128), let kind = take(operation.operation, limit: 64),
                          let path = take(operation.path, limit: 1024), !path.isEmpty else { return nil }
                    return .init(operation: kind, path: path, oldPath: take(operation.oldPath, limit: 1024),
                                 fileType: take(operation.fileType, limit: 128), mimeType: take(operation.mimeType, limit: 128))
                }
            }
            tool.fileChangeDetails = bounded
        }
        if truncated { tool.output = (tool.output ?? "") + note }
        return tool
    }

    private let truncationMarker = "[Earlier text truncated]\n"

    private func clipped(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        guard bytes >= truncationMarker.utf8.count else { return "" }
        // Drop a partial leading scalar instead of introducing a replacement character.
        var suffix = text.utf8.suffix(bytes - truncationMarker.utf8.count)
        while let first = suffix.first, first & 0xC0 == 0x80 { suffix = suffix.dropFirst() }
        return truncationMarker + String(decoding: suffix, as: UTF8.self)
    }

    /// Only this session's own checkpoint refs are retired, after its bounded
    /// transcript has been persisted. In-flight baselines remain pinned.
    private func cleanupCheckpoints(_ saved: Saved) {
        let directory = root.appendingPathComponent("checkpoints", isDirectory: true)
            .appendingPathComponent(saved.snapshot.session.description, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let turns = saved.snapshot.turns ?? []
        let retained = Set(turns.map(\.userItemID)).union(turns.compactMap { $0.checkpoint?.id })
        let finished = Set(turns.compactMap { $0.checkpoint?.id })
        let previous = retainedCheckpointIDs[saved.snapshot.session] ?? retained
        let retired = previous.subtracting(retained)
        retainedCheckpointIDs[saved.snapshot.session] = retained
        let store = AgentCheckpointStore()
        for file in files where file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            do {
                if name.hasPrefix("pending-") {
                    let id = String(name.dropFirst(8))
                    guard retired.contains(id) || finished.contains(id) else { continue }
                    let pending = try JSONDecoder().decode(AgentCheckpointPending.self, from: Data(contentsOf: file))
                    if !finished.contains(id) { try store.remove(pending.before) }
                } else {
                    guard retired.contains(name) else { continue }
                    let record = try JSONDecoder().decode(AgentCheckpointRecord.self, from: Data(contentsOf: file))
                    try store.remove(record.before)
                    try store.remove(record.after)
                }
                try FileManager.default.removeItem(at: file)
            } catch { ServerLog.error("agent checkpoint cleanup failed: \(error)") }
        }
    }

    private func persist(_ entry: Entry) {
        let saved = Saved(snapshot: entry.snapshot, directory: entry.directory, hasSuccessfulTurn: entry.hasSuccessfulTurn,
                          forkSource: entry.forkSource, forkPoint: entry.forkPoint,
                          lastProviderMessage: entry.lastProviderMessage,
                          heldReports: entry.heldReports.isEmpty ? nil : entry.heldReports,
                          reportsPaused: entry.reportsPaused ? true : nil, announced: entry.announced ? true : nil,
                          unattendedDeliveries: entry.unattendedDeliveries == 0 ? nil : entry.unattendedDeliveries)
        let file = root.appendingPathComponent(entry.snapshot.session.description + ".json")
        writer.async {
            do {
                try JSONEncoder().encode(saved).write(to: file, options: .atomic)
                self.cleanupCheckpoints(saved)
            } catch { ServerLog.error("agent checkpoint failed: \(error)") }
        }
    }
}

extension AgentSessions {
    private func mutateInbox(_ entry: Entry, _ change: (inout AgentPromptInbox) throws -> Void) throws {
        if let error = entry.inboxError { throw AgentRuntimeError("Queue storage is unavailable: " + error) }
        var next = entry.inbox
        try change(&next)
        entry.inbox = next
        entry.snapshot.queuedPrompts = next.visible
        entry.snapshot.queuePaused = next.paused
        touch(entry)
        persist(entry)
        let file = root.appendingPathComponent("inbox/" + entry.snapshot.session.description + ".json")
        let savedInbox = next
        writer.async { [self] in
            do { try savedInbox.save(file) }
            catch {
                let message = "Queue could not be saved: " + error.localizedDescription
                queue.async { [self] in
                    entry.inboxError = message
                    entry.inbox.paused = true
                    entry.snapshot.queuePaused = true
                    entry.snapshot.items.append(AgentChatItem(kind: .notice, text: message))
                    touch(entry)
                }
            }
        }
    }

    private func handleInbox(_ request: AgentChatRequest, entry: Entry) throws -> Bool {
        switch request {
        case .submit(_, let prompt):
            guard prompt.provider == entry.snapshot.provider || entry.snapshot.providerSession == nil else {
                throw AgentRuntimeError("An established conversation cannot switch providers.")
            }
            try mutateInbox(entry) { try $0.submit(prompt) }
            drainInbox(entry)
        case .editQueued(_, let id, let text, let revision, let settings):
            try mutateInbox(entry) { inbox in
                let index = try inbox.index(id, revision: revision)
                if let settings {
                    inbox.records[index].prompt?.model = settings.model
                    inbox.records[index].prompt?.effort = settings.effort
                    inbox.records[index].prompt?.planMode = settings.planMode
                }
                inbox.records[index].prompt?.text = text
                if let prompt = inbox.records[index].prompt { try prompt.validate() }
                inbox.records[index].display?.text = text
                inbox.records[index].display?.revision += 1
            }
        case .moveQueued(_, let id, let before, let revision):
            try mutateInbox(entry) { inbox in
                let index = try inbox.index(id, revision: revision)
                guard inbox.records[index].display?.state == .queued,
                      let target = inbox.records.firstIndex(where: { $0.id == before && $0.display?.state == .queued }), index != target else {
                    throw AgentRuntimeError("Only undelivered prompts can be reordered.")
                }
                let record = inbox.records.remove(at: index)
                inbox.records.insert(record, at: target > index ? target - 1 : target)
                for i in inbox.records.indices where inbox.records[i].display != nil { inbox.records[i].display?.revision += 1 }
            }
        case .removeQueued(_, let id, let revision):
            try mutateInbox(entry) { inbox in
                let index = try inbox.index(id, revision: revision)
                inbox.records[index].prompt = nil
                inbox.records[index].display = nil
            }
        case .resumeQueue:
            guard entry.snapshot.status != .failed else {
                throw AgentRuntimeError("Review the failed response and use Send now on the prompt you want to retry.")
            }
            try mutateInbox(entry) { $0.paused = false }
            drainInbox(entry)
        case .deliverQueued(_, let id, let revision):
            let index = try entry.inbox.index(id, revision: revision)
            try deliverInbox(entry, index: index)
        default: return false
        }
        return true
    }

    private func drainInbox(_ entry: Entry) {
        guard !stopping, entry.snapshot.status == .idle, !entry.submitting, entry.deliveryID == nil,
              entry.interrupting == nil, !entry.inbox.paused,
              let index = entry.inbox.records.firstIndex(where: { $0.display?.state == .queued }) else { return }
        do { try deliverInbox(entry, index: index) }
        catch {
            try? mutateInbox(entry) { $0.paused = true }
            entry.snapshot.items.append(AgentChatItem(kind: .notice, text: "Queue paused: " + error.localizedDescription))
            touch(entry)
        }
    }

    private func deliverInbox(_ entry: Entry, index: Int) throws {
        guard !entry.submitting, entry.deliveryID == nil, entry.interrupting == nil,
              entry.snapshot.status != .waiting, entry.snapshot.status != .closed,
              let prompt = entry.inbox.records[index].prompt else {
            throw AgentRuntimeError("Wait for the current interaction before delivering this prompt.")
        }
        if entry.snapshot.status == .working {
            guard prompt.model == entry.snapshot.model, prompt.effort == entry.snapshot.reasoningEffort,
                  prompt.provider == entry.snapshot.provider, prompt.planMode == (entry.snapshot.planMode == true) else {
                throw AgentRuntimeError("This prompt uses different model or plan settings. It must wait for the next turn.")
            }
        } else { entry.snapshot.planMode = prompt.planMode }
        try mutateInbox(entry) { inbox in
            inbox.records[index].display?.state = .delivering
            inbox.records[index].display?.error = nil
            inbox.records[index].display?.revision += 1
        }
        let attemptID = UUID().uuidString
        entry.deliveryID = attemptID
        entry.deliveryCancelled = false
        let id = entry.snapshot.session
        Task { [self] in
            let outcome: Result<AgentChatSnapshot, Error>
            do {
                let snapshot: AgentChatSnapshot = try await withCheckedThrowingContinuation { continuation in
                    writer.async { [self] in
                      queue.async { [self] in
                        do {
                            if let error = entry.inboxError { throw AgentRuntimeError(error) }
                            guard !stopping, entry.snapshot.status != .closed, entry.deliveryID == attemptID, !entry.deliveryCancelled else {
                                throw AgentRuntimeError("Delivery was cancelled before it began.")
                            }
                            try begin(.send(session: id, text: prompt.text, model: prompt.model, reasoningEffort: prompt.effort,
                                            provider: prompt.provider, attachments: prompt.attachments),
                                      continuation: continuation, deliveryID: attemptID)
                        } catch { continuation.resume(throwing: error) }
                      }
                    }
                }
                outcome = .success(snapshot)
            } catch { outcome = .failure(error) }
            queue.async { [self] in
                entry.deliveryID = nil
                do {
                    try mutateInbox(entry) { inbox in
                        guard let index = inbox.records.firstIndex(where: { $0.id == prompt.id }) else { return }
                        switch outcome {
                        case .success(let snapshot) where snapshot.status != .failed && snapshot.status != .closed:
                            inbox.records[index].prompt = nil
                            inbox.records[index].display = nil
                        default:
                            inbox.paused = true
                            inbox.records[index].display?.state = .uncertain
                            inbox.records[index].display?.error = "Delivery did not finish cleanly. Review the conversation before sending again."
                            inbox.records[index].display?.revision += 1
                        }
                    }
                } catch { entry.inboxError = error.localizedDescription }
                drainInbox(entry)
            }
        }
    }
}
