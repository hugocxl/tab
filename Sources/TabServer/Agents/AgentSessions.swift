import Foundation
import TabProtocol

/// Injectable boundary: tests never need a provider executable.
protocol AgentSessionRuntime: Sendable {
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
              attachments: [StagedAgentAttachment]) async throws
    func approve(request: String, allow: Bool) async throws
    func setAccess(_ mode: AgentAccessMode) async throws
    func interrupt() async throws
    func stop()
}

extension AgentSessionRuntime {
    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
              attachments: [StagedAgentAttachment]) async throws {
        guard attachments.isEmpty else { throw AgentRuntimeError("This agent runtime does not support attachments.") }
        try await send(text: text, model: model, reasoningEffort: reasoningEffort)
    }
}

extension AgentRuntime: AgentSessionRuntime {}

/// Conversation ownership is independent of sockets, terminal channels and app references.
final class AgentSessions: @unchecked Sendable {
    typealias Factory = @Sendable (AgentChatProvider, String, String?,
                                  @escaping @Sendable (AgentRuntimeEvent) -> Void) -> any AgentSessionRuntime
    /// All mutable fields are confined to `queue`, including completion callbacks.
    private final class Entry: @unchecked Sendable {
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
    private let root: URL
    private let factory: Factory
    private let projectDirectory: @Sendable (ProjectId) throws -> String
    private let submissionTimeout: TimeInterval
    private let interruptTimeout: TimeInterval
    var changed: @Sendable (SessionId, UInt64) -> Void
    var checkDirectory: @Sendable (String) throws -> Void = { _ in }
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
                entry.hasSuccessfulTurn = saved.hasSuccessfulTurn ?? entry.hasSuccessfulTurn
                bound(entry)
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

    private func begin(_ request: AgentChatRequest,
                       continuation: CheckedContinuation<AgentChatSnapshot, Error>) throws {
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
            let entry = Entry(AgentChatSnapshot(session: id, project: project, provider: provider), directory: directory)
            entries[id] = entry
            touch(entry)
            persist(entry)
            continuation.resume(returning: entry.snapshot)
            return
        }
        let id: SessionId
        switch request {
        case .read(let session), .send(let session, _, _, _, _, _), .approve(let session, _, _),
             .interrupt(let session), .close(let session), .setAccess(let session, _): id = session
        case .create: throw ServiceError(.badRequest, "Unexpected create")
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
            guard !entry.submitting, entry.snapshot.status != .working, entry.snapshot.status != .waiting else {
                throw ServiceError(.badRequest, "The agent is already handling a message")
            }
            _ = try projectDirectory(entry.snapshot.project)
            try checkDirectory(entry.directory)
            let provider = requestedProvider ?? entry.snapshot.provider
            if provider != entry.snapshot.provider {
                guard entry.snapshot.providerSession == nil, !entry.hasSuccessfulTurn,
                      entry.snapshot.status == .idle || entry.snapshot.status == .failed else {
                    throw ServiceError(.badRequest, "An established conversation cannot switch providers. Open a new Agent Tab.")
                }
            }
            if let effort, !AgentReasoningEffort.supported(provider: provider, model: model).contains(effort) {
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
            do {
                stagedAttachments = try AgentAttachments.stage(attachments ?? [], root: root
                    .appendingPathComponent("attachments", isDirectory: true)
                    .appendingPathComponent(id.description, isDirectory: true))
            } catch {
                throw ServiceError(.badRequest, error.localizedDescription)
            }
            if restart, entry.runtime != nil { retireRuntime(entry) }
            entry.snapshot.provider = provider
            let user = AgentChatItem(kind: .user, text: text,
                                     attachments: attachments?.map(\.descriptor))
            entry.snapshot.items.append(user)
            entry.snapshot.turns = (entry.snapshot.turns ?? []) + [AgentChatTurn(userItemID: user.id, startedAt: Date())]
            entry.snapshot.model = model
            entry.snapshot.reasoningEffort = effort
            entry.snapshot.status = .working
            entry.submitting = true
            touch(entry)
            persist(entry)
        }
        if case .approve(_, let request, _) = request {
            guard !entry.submitting, entry.snapshot.status == .waiting,
                  !entry.approving.contains(request),
                  entry.snapshot.items.contains(where: { $0.id == request && $0.kind == .approval && !$0.isComplete }) else {
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
                configureAccess(entry, runtime: runtime, mode: entry.snapshot.accessMode ?? .standard)
            }
        }
        guard let runtime = entry.runtime else { throw ServiceError(.badRequest, "Agent unavailable") }
        let generation = entry.generation
        let model = entry.snapshot.model
        let effort = entry.snapshot.reasoningEffort
        let accessTask = entry.accessTask
        if case .approve(_, let request, _) = request { entry.approving.insert(request) }
        if case .interrupt = request {
            guard entry.interrupting == nil else { throw ServiceError(.badRequest, "An interrupt is already pending") }
            entry.interrupting = UUID()
        }
        let pending = PendingReply(continuation)
        let turnAttachments = stagedAttachments
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
        pending.task = Task { [self] in
            guard !Task.isCancelled else { return }
            let failure: Error?
            do {
                switch request {
                case .send(_, let text, _, _, _, _):
                    try await accessTask?.value
                    try Task.checkCancellation()
                    try await runtime.send(text: text, model: model, reasoningEffort: effort, attachments: turnAttachments)
                case .setAccess: try await accessTask?.value
                case .approve(_, let request, let allow): try await runtime.approve(request: request, allow: allow)
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
            }
        }
    }

    private func receive(_ event: AgentRuntimeEvent, session: SessionId, generation: UUID) {
        guard !stopping, let entry = entries[session], entry.generation == generation,
              entry.snapshot.status != .closed else { return }
        switch event {
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
                entry.snapshot.items[index] = item
            } else { entry.snapshot.items.append(item) }
        case .textDelta(let id, let text):
            guard id.utf8.count <= 1024 else { return }
            if let index = entry.snapshot.items.firstIndex(where: { $0.id == id }) {
                entry.snapshot.items[index].text += text
            } else {
                entry.snapshot.items.append(AgentChatItem(id: id, kind: .assistant,
                                                         text: text, isComplete: false))
            }
        case .status(let status):
            if status == .idle, entry.interrupting == nil,
               entry.snapshot.status == .working || entry.snapshot.status == .waiting {
                entry.hasSuccessfulTurn = true
            }
            entry.snapshot.status = status
            updateTurn(entry, status: status)
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
        case .failure(let message):
            entry.snapshot.status = .failed
            updateTurn(entry, status: .failed)
            entry.snapshot.items.append(AgentChatItem(kind: .notice, text: message))
            retireRuntime(entry)
            for index in entry.snapshot.items.indices { entry.snapshot.items[index].isComplete = true }
        }
        touch(entry)
        if entry.snapshot.status == .idle || entry.snapshot.status == .failed || entry.snapshot.status == .closed {
            persist(entry)
        }
        if entry.snapshot.status == .failed || entry.snapshot.status == .closed { settleSubmission(entry) }
        if case .providerSession = event { persist(entry) }
    }

    private func interrupted(_ entry: Entry, message: String) {
        entry.snapshot.status = .failed
        updateTurn(entry, status: .failed)
        entry.snapshot.revision &+= 1
        for index in entry.snapshot.items.indices { entry.snapshot.items[index].isComplete = true }
        entry.snapshot.items.append(AgentChatItem(kind: .notice, text: message))
        bound(entry)
    }

    private func close(_ entry: Entry) {
        guard entry.snapshot.status != .closed else { return }
        retireRuntime(entry)
        entry.snapshot.status = .closed
        updateTurn(entry, status: .closed)
        for index in entry.snapshot.items.indices { entry.snapshot.items[index].isComplete = true }
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
        Task { runtime?.stop() }
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

    private func updateTurn(_ entry: Entry, status: AgentChatStatus) {
        guard var turns = entry.snapshot.turns, let index = turns.indices.last,
              turns[index].completedAt == nil else { return }
        turns[index].status = status
        if status == .idle || status == .failed || status == .closed {
            turns[index].completedAt = max(Date(), turns[index].startedAt)
        }
        entry.snapshot.turns = turns
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
        if entry.snapshot.items.filter({ $0.kind == .approval && !$0.isComplete }).count > 128 {
            entry.snapshot.status = .failed
            updateTurn(entry, status: .failed)
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
            if let bounded = boundedItem(item, budget: pending ? 2048 : min(64 * 1024, remaining), pending: pending) {
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
            entry.snapshot.turns = Array(turns.filter { users.contains($0.userItemID) }.suffix(512))
        }
    }

    private func boundedItem(_ source: AgentChatItem, budget: Int, pending: Bool = false) -> AgentChatItem? {
        guard budget > 0 else { return nil }
        var item = source
        var remaining = budget
        remaining -= (item.attachments ?? []).reduce(0) { $0 + $1.transcriptByteCount }
        guard remaining >= 0 else { return nil }
        if let tool = item.tool {
            item.tool = boundedTool(tool, budget: min(32 * 1024, max(0, budget - 1024)))
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
        if let detail = item.detail { item.detail = clipped(detail, bytes: min(pending ? 1536 : 16 * 1024, remaining)) }
        return item
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

    private func persist(_ entry: Entry) {
        let saved = Saved(snapshot: entry.snapshot, directory: entry.directory, hasSuccessfulTurn: entry.hasSuccessfulTurn)
        let file = root.appendingPathComponent(entry.snapshot.session.description + ".json")
        writer.async {
            do {
                try JSONEncoder().encode(saved).write(to: file, options: .atomic)
            } catch { ServerLog.error("agent checkpoint failed: \(error)") }
        }
    }
}
