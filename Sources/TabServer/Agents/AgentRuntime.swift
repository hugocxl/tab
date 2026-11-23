import Foundation
import TabCore
import TabProtocol

internal enum AgentRuntimeEvent: Sendable {
    case item(AgentChatItem)
    /// Replaces an item the conversation still holds; one it no longer has, as after
    /// trimming, stays gone rather than coming back out of order.
    case itemUpdate(AgentChatItem)
    case toolItem(AgentChatItem, images: [AgentChatAttachment])
    case textDelta(id: String, text: String)
    case status(AgentChatStatus)
    case providerSession(String)
    /// The latest message the provider wrote to its conversation, where a fork made now begins.
    case providerMessage(String)
    case contextUsage(AgentContextUsage)
    /// The agents still running for the conversation, then those finished since the
    /// user's last prompt, replacing the previous list.
    case subagents([AgentSubagent])
    /// An agent's own steps so far, keyed by the tool call that started it.
    case subagentSteps(toolUseID: String, items: [AgentChatItem])
    /// The provider began a turn nobody sent, such as Claude answering a background
    /// agent that finished; `reason` says why when it is known.
    case providerTurn(reason: String)
    /// What holds the provider up now, or nil when nothing does.
    case activity(AgentChatActivity?)
    /// What the turn that just ended used, and why it stopped.
    case turnUsage(AgentTurnUsage)
    case resolvedModel(String)
    case commands([String])
    case commandDescriptors([AgentCommandDescriptor])
    case planMode(Bool)
    case failure(String)
}

/// A follow-up arrived after the provider finished its turn; it needs a turn of its own.
internal struct AgentTurnFinishedError: LocalizedError {
    var errorDescription: String? { "The response has finished. Send the message again to start a follow-up." }
}

internal struct AgentRuntimeError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// All protocol state is confined to queue; process readers never call client code directly.
// Raw control envelope reference: the provider source
// apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.test.ts:2366–2402.
// Codex handshake/request lifecycle: the adjacent CodexAdapterV2.ts,
// ensureInitialized, ensureThread/resumeThread, startNativeTurn, interruptTurn.
internal final class AgentRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tab.agent-runtime")
    private let provider: AgentChatProvider
    private let directory: String
    private var resumeSession: String?
    private let onEvent: @Sendable (AgentRuntimeEvent) -> Void
    private let launchOverride: AgentProcess.Launch?
    private let launchBuilder: (@Sendable ([String]) -> AgentProcess.Launch)?
    private let requestTimeout: TimeInterval
    private var process: AgentProcess?
    private var closed = false
    private var failed = false
    private var busy = false
    /// The user stopped the running turn. Providers end such a turn with an error
    /// (Claude's `error_during_execution` result); that error is the stop, not a failure.
    private var interruptRequested = false
    /// Follow-ups written to Claude that it has not echoed back yet. Claude folds a
    /// follow-up into the running turn at a tool boundary, or else answers it in
    /// its own turn after the current result; only the echo tells which.
    private var unconsumedClaudeInputs: Set<String> = []
    /// Retries the provider announced since its last successful output.
    private var retryAttempts = 0
    /// The running turn is one the provider began on its own, such as Claude answering
    /// a background agent that finished.
    private var providerInitiatedTurn = false
    /// Sends that arrived during a provider-initiated turn; they start when it ends,
    /// so a queued prompt's delivery is never refused or folded into that turn.
    private var deferredSends: [(Error?) -> Void] = []
    private var ready = false
    private var sequence = 0
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var approvals: [String: [String: Any]] = [:]
    private var questions: [String: (form: AgentQuestionnaire, wire: [String: Any])] = [:]
    private var answeredQuestions: Set<String> = []
    private var completedApprovals: Set<String> = []
    private var completedApprovalOrder: [String] = []
    /// What each pending request offered and how its row looked, by request key.
    private var presented: [String: AgentProviderRequests.Presented] = [:]
    private var pendingRows: [String: AgentChatItem] = [:]
    /// The key of each pending provider request: a number and a string are different IDs.
    private var requestKeys: [AgentProviderRequestID: String] = [:]
    /// Requests that ended unanswered because the agent that asked ended, so a late answer says so.
    private var expiredRequests: [String: String] = [:]
    /// Codex agents' threads, by thread ID: the collab tool call that started each, and its prompt.
    private var codexChildren: [String: (toolUseID: String, title: String?)] = [:]
    /// Claude's subagents, by `agent_id`: the Agent tool call that started each.
    private var claudeChildren: [String: String] = [:]
    /// The description of each Agent tool call, by its ID.
    private var claudeAgentTitles: [String: String] = [:]
    /// When Codex's exhausted usage window resets, from its latest rate-limit report.
    private var codexLimitReset: Date?
    private var threadID: String?
    private var turnID: String?
    private var model: String?
    private var reasoningEffort: AgentReasoningEffort?
    private var hasSubmittedTurn = false
    private var processGeneration = UUID()
    private var accessMode: AgentAccessMode = .standard
    private var launch = AgentLaunch()
    private lazy var claude = ClaudeAgentRuntime(onEvent: onEvent)
    private lazy var codex = CodexAgentRuntime(onEvent: onEvent)

    init(provider: AgentChatProvider, directory: String, resumeSession: String?,
         onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) {
        self.provider = provider
        self.directory = directory
        self.resumeSession = resumeSession
        self.onEvent = onEvent
        launchOverride = nil
        launchBuilder = nil
        requestTimeout = 30
    }

    /// Test seam uses an actual local fake subprocess, never a provider/account.
    init(provider: AgentChatProvider, directory: String, resumeSession: String?,
         launch: AgentProcess.Launch, requestTimeout: TimeInterval = 30,
         onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) {
        self.provider = provider
        self.directory = directory
        self.resumeSession = resumeSession
        self.onEvent = onEvent
        launchOverride = launch
        launchBuilder = nil
        self.requestTimeout = requestTimeout
    }

    /// Replays the actual generated provider arguments against a synthetic subprocess.
    init(provider: AgentChatProvider, directory: String, resumeSession: String?,
         launchBuilder: @escaping @Sendable ([String]) -> AgentProcess.Launch, requestTimeout: TimeInterval = 30,
         onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) {
        self.provider = provider
        self.directory = directory
        self.resumeSession = resumeSession
        self.onEvent = onEvent
        launchOverride = nil
        self.launchBuilder = launchBuilder
        self.requestTimeout = requestTimeout
    }

    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort? = nil) async throws {
        try await send(text: text, model: model, reasoningEffort: reasoningEffort, attachments: [])
    }

    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
              attachments: [StagedAgentAttachment]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.startSend(text: text, model: model, reasoningEffort: reasoningEffort, attachments: attachments,
                               continuation: continuation)
            }
        }
    }

    private func startSend(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
                           attachments: [StagedAgentAttachment], continuation: CheckedContinuation<Void, Error>) {
                guard !self.closed, !self.failed else {
                    continuation.resume(throwing: AgentRuntimeError("Agent is closed or failed; open a new agent pane to resume."))
                    return
                }
                if self.busy, self.providerInitiatedTurn {
                    self.deferredSends.append { error in
                        if let error { continuation.resume(throwing: error); return }
                        self.startSend(text: text, model: model, reasoningEffort: reasoningEffort,
                                       attachments: attachments, continuation: continuation)
                    }
                    return
                }
                guard !self.busy else {
                    continuation.resume(throwing: AgentRuntimeError("Wait for the current turn or interrupt it first."))
                    return
                }
                if let reasoningEffort,
                   !reasoningEffort.isAccepted(provider: self.provider, model: model) {
                    continuation.resume(throwing: AgentRuntimeError("This provider/model does not support \(reasoningEffort.title) reasoning."))
                    return
                }
                do {
                    if self.provider == .claude, self.ready,
                       model != self.model || reasoningEffort != self.reasoningEffort {
                        try self.restartClaudeSelection()
                    }
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                self.busy = true
                self.interruptRequested = false
                self.onEvent(.status(.working))
                let submit: (Result<[String: Any], Error>) -> Void = { result in
                    do {
                        _ = try result.get()
                        try self.submit(text: text, model: model, reasoningEffort: reasoningEffort,
                                        attachments: attachments, continuation: continuation)
                    } catch {
                        self.fail(error.localizedDescription)
                        continuation.resume(throwing: error)
                    }
                }
                do {
                    if self.ready { submit(.success([:])); return }
                    try self.start(model: model, reasoningEffort: reasoningEffort, completion: submit)
                } catch {
                    self.fail(error.localizedDescription)
                    continuation.resume(throwing: error)
                }
    }

    func steer(text: String, attachments: [StagedAgentAttachment]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard !self.closed, !self.failed else {
                        throw AgentRuntimeError("Agent is closed or failed; open a new agent pane to resume.")
                    }
                    guard self.busy, self.ready else { throw AgentTurnFinishedError() }
                    if self.provider == .claude {
                        let input = UUID().uuidString.lowercased()
                        try self.write(["type": "user", "message": ["role": "user",
                            "content": AgentAttachments.claudeContent(text: text, attachments: attachments)],
                            "parent_tool_use_id": NSNull(), "session_id": self.claude.sessionID ?? self.resumeSession ?? "",
                            "uuid": input])
                        self.unconsumedClaudeInputs.insert(input)
                        continuation.resume()
                    } else {
                        guard let thread = self.threadID, let turn = self.turnID else {
                            throw AgentRuntimeError("The response is still starting. Try sending again shortly.")
                        }
                        try self.request("turn/steer", params: ["threadId": thread, "expectedTurnId": turn,
                            "input": AgentAttachments.codexInput(text: text, attachments: attachments)]) { result in
                            do { _ = try result.get(); continuation.resume() }
                            catch { continuation.resume(throwing: error) }
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func restartClaudeSelection() throws {
        // the source renderer's query identity includes model and effort. Clearing effort must
        // reload provider settings, not silently retain the previous override.
        guard let session = claude.sessionID ?? resumeSession else {
            throw AgentRuntimeError("Claude has not supplied a session ID to resume after changing model or effort.")
        }
        processGeneration = UUID()
        process?.stop()
        process = nil
        let stopped = claude.endProcess()
        if stopped > 0 {
            onEvent(.item(AgentChatItem(kind: .notice, text: Self.stoppedAgents(stopped, because: "the model or reasoning effort changed, which restarts Claude"))))
        }
        pending.removeAll() // Only non-awaited interrupt acknowledgments can remain after an idle turn.
        resumeSession = session
        ready = false
    }

    private func start(model: String?, reasoningEffort: AgentReasoningEffort?,
                       completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        var environment = AgentProcess.environment()
        // A nested SDK process is intentional, not an interactive Claude session.
        environment.removeValue(forKey: "CLAUDECODE")
        // Only terminals are Tab sessions; an inherited one isn't this agent's.
        environment.removeValue(forKey: "TAB_SESSION_ID")
        let config = launch.provider ?? .builtIn(provider)
        environment = AgentProviderLaunch.environment(config, base: environment)
        environment.merge(launch.environment) { _, tab in tab }

        if let path = launch.path { environment["PATH"] = [path, environment["PATH"]].compactMap { $0 }.joined(separator: ":") }
        let forking = launch.forkSource != nil && resumeSession == launch.forkSource
        var arguments = provider == .claude
            ? ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
               "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio", "--permission-mode", "default"]
            : ["app-server"]
        if provider == .claude {
            appliedClaudePlanMode = false
            if let resumeSession { arguments += ["--resume", resumeSession] }
            if forking {
                arguments.append("--fork-session")
                if let point = launch.forkPoint { arguments += ["--resume-session-at", point] }
            }
            if let model { arguments += ["--model", model] }
            if let reasoningEffort { arguments += ["--effort", claudeWireEffort(reasoningEffort, model: model)] }
            if let instructions = self.launch.instructions { arguments += ["--append-system-prompt", instructions] }
            self.model = model
            self.reasoningEffort = reasoningEffort
        }
        arguments += config.arguments
        let launch = try launchBuilder?(arguments) ?? launchOverride ?? AgentProcess.Launch(
            executable: AgentProviderLaunch.executable(config, environment: environment),
            arguments: arguments, environment: environment)
        let generation = processGeneration
        process = try AgentProcess(launch: launch, directory: directory, onLine: { [weak self] line in
            self?.queue.async { [weak self] in
                guard let self, self.processGeneration == generation else { return }
                self.receive(line)
            }
        }, onExit: { [weak self] code, stderr in
            self?.queue.async { [weak self] in
                guard let self, !self.closed, !self.failed, self.processGeneration == generation else { return }
                self.fail("\(self.provider.name) exited (\(code)). \(stderr.isEmpty ? "Check CLI installation and authentication; update the CLI if stream-json/app-server is unsupported." : stderr)")
            }
        })
        if provider == .claude {
            try request("initialize", params: ["hooks": [:]], completion: { result in
                if case .success(let response) = result {
                    self.ready = true
                    let descriptors = AgentCommandDiscovery.descriptors(response["commands"] as? [[String: Any]] ?? [])
                    self.onEvent(.commandDescriptors(Array(descriptors.prefix(256))))
                }
                completion(result)
            })
        } else {
            try request("initialize", params: ["clientInfo": ["name": "tab", "version": Release.version], "capabilities": ["experimentalApi": true]], completion: { result in
                do {
                    _ = try result.get()
                    try self.write(["method": "initialized"])
                    var params: [String: Any] = ["cwd": self.directory,
                        "approvalPolicy": self.accessMode == .fullAccess ? "never" : self.accessMode == .ask ? "untrusted" : "on-request",
                        "sandbox": self.accessMode == .fullAccess ? "danger-full-access" : self.accessMode == .ask ? "read-only" : "workspace-write"]
                    if let model { params["model"] = model }
                    if let instructions = self.launch.instructions { params["developerInstructions"] = instructions }
                    if let resumeSession = self.resumeSession { params["threadId"] = resumeSession }
                    let method = self.resumeSession == nil ? "thread/start" : forking ? "thread/fork" : "thread/resume"
                    try self.request(method, params: params) { result in
                        do {
                            let response = try result.get()
                            guard let thread = response["thread"] as? [String: Any], let id = thread["id"] as? String else {
                                throw AgentRuntimeError("Codex did not return a thread ID.")
                            }
                            self.threadID = id
                            if forking { self.resumeSession = id }
                            self.ready = true
                            self.onEvent(.providerSession(id))
                            if let model = response["model"] as? String { self.onEvent(.resolvedModel(model)) }
                            completion(.success(response))
                        } catch { completion(.failure(error)) }
                    }
                } catch { completion(.failure(error)) }
            })
        }
    }

    private func submit(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
                        attachments: [StagedAgentAttachment],
                        continuation: CheckedContinuation<Void, Error>) throws {
        if provider == .claude {
            let submitUser: (Result<[String: Any], Error>) -> Void = { result in
                do {
                    _ = try result.get()
                    self.claude.beginTurn()
                    self.claude.clearFinishedSubagents()
                    try self.write(["type": "user", "message": ["role": "user", "content": AgentAttachments.claudeContent(text: text, attachments: attachments)],
                                     "parent_tool_use_id": NSNull(), "session_id": self.claude.sessionID ?? self.resumeSession ?? ""])
                    self.hasSubmittedTurn = true
                    continuation.resume()
                } catch {
                    self.fail(error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
            if planMode != appliedClaudePlanMode {
                try request("set_permission_mode", params: ["mode": planMode ? "plan" : "default"]) { result in
                    if case .success = result { self.appliedClaudePlanMode = self.planMode }
                    submitUser(result)
                }
            } else { submitUser(.success([:])) }
        } else {
            guard let threadID else { throw AgentRuntimeError("Codex thread is not initialized.") }
            let invocation = AgentSlashCommand(text: text)
            if let command = invocation, ["compact", "review"].contains(command.name) {
                if let error = command.validationError(provider: .codex, commands: ["compact", "review"], hasAttachments: !attachments.isEmpty) {
                    throw AgentRuntimeError(error)
                }
                guard attachments.isEmpty else { throw AgentRuntimeError("This command does not accept attachments.") }
                let method = command.name == "compact" ? "thread/compact/start" : "review/start"
                var params: [String: Any] = ["threadId": threadID]
                if command.name == "review" {
                    var target = ["type": "uncommittedChanges"]
                    if command.arguments.hasPrefix("branch ") { target = ["type": "baseBranch", "branch": String(command.arguments.dropFirst(7)).trimmingCharacters(in: .whitespaces)] }
                    if command.arguments.hasPrefix("commit ") { target = ["type": "commit", "sha": String(command.arguments.dropFirst(7)).trimmingCharacters(in: .whitespaces)] }
                    params["target"] = target; params["delivery"] = "inline"
                }
                try request(method, params: params) { result in
                    do { _ = try result.get(); continuation.resume() }
                    catch { self.fail(error.localizedDescription); continuation.resume(throwing: error) }
                }
                return
            }
            try codexSelection(model: model, reasoningEffort: reasoningEffort) { selection in
                do {
                    let (wireModel, effort) = try selection.get()
                    var params: [String: Any] = ["threadId": threadID, "input": AgentAttachments.codexInput(text: text, attachments: attachments)]
                    // Source codexRuntimeModeTurnDefaults: explicitly reset on every
                    // turn so leaving Full access restores native prompting/sandboxing.
                    params["approvalPolicy"] = self.accessMode == .fullAccess ? "never" : self.accessMode == .ask ? "untrusted" : "on-request"
                    params["sandboxPolicy"] = ["type": self.accessMode == .fullAccess ? "dangerFullAccess" : self.accessMode == .ask ? "readOnly" : "workspaceWrite"]
                    if let wireModel { params["model"] = wireModel }
                    if let effort { params["effort"] = effort }
                    if self.planModeConfigured, let collaborationModel = wireModel {
                        params["collaborationMode"] = ["mode": self.planMode ? "plan" : "default",
                            "settings": ["model": collaborationModel, "reasoning_effort": effort as Any? ?? NSNull(),
                                         "developer_instructions": NSNull()]]
                    } else if self.planMode {
                        throw AgentRuntimeError("Choose an explicit model before starting plan mode.")
                    }
                    try self.request("turn/start", params: params) { result in
                        do {
                            let response = try result.get()
                            self.model = model
                            if let wireModel { self.onEvent(.resolvedModel(wireModel)) }
                            self.reasoningEffort = reasoningEffort
                            self.hasSubmittedTurn = true
                            if self.busy, let turn = response["turn"] as? [String: Any] { self.turnID = turn["id"] as? String }
                            continuation.resume()
                        } catch {
                            self.fail(error.localizedDescription)
                            continuation.resume(throwing: error)
                        }
                    }
                } catch {
                    self.fail(error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func claudeWireEffort(_ effort: AgentReasoningEffort, model: String?) -> String {
        let model = (model ?? "").lowercased().replacingOccurrences(of: ".", with: "-")
        // Source manifest adapter.claudeCode.effortMap for the two legacy profiles.
        if effort == .xhigh, model.contains("opus-4-7") { return "max" }
        if effort == .max, model.contains("sonnet-4-6") { return "high" }
        return effort.rawValue
    }

    private func codexSelection(model: String?, reasoningEffort: AgentReasoningEffort?,
                                completion: @escaping (Result<(String?, String?), Error>) -> Void) throws {
        let resumedDefaults = !hasSubmittedTurn && resumeSession != nil
        let resetModel = model == nil && (planModeConfigured || resumedDefaults || (hasSubmittedTurn && self.model != nil))
        let resetEffort = reasoningEffort == nil && (resumedDefaults
            || (hasSubmittedTurn && (self.reasoningEffort != nil || model != self.model)))
        guard resetModel || resetEffort else {
            completion(.success((model, reasoningEffort?.rawValue)))
            return
        }
        // Codex turn/start overrides persist to subsequent turns. Omitting a
        // cleared selector would keep its old value. Read real provider defaults.
        try request("config/read", params: ["includeLayers": false, "cwd": directory]) { result in
            do {
                let config = try result.get()["config"] as? [String: Any] ?? [:]
                try self.codexModels { result in
                    do {
                        let models = try result.get()
                        let defaultModel = config["model"] as? String
                            ?? models.first(where: { $0["isDefault"] as? Bool == true })?["model"] as? String
                        let effectiveModel = model ?? defaultModel
                        let descriptor = models.first { ($0["model"] as? String ?? $0["id"] as? String) == effectiveModel }
                        let defaultEffort = config["model_reasoning_effort"] as? String
                            ?? descriptor?["defaultReasoningEffort"] as? String
                        guard (!resetModel || defaultModel != nil), (!resetEffort || defaultEffort != nil) else {
                            throw AgentRuntimeError("Codex did not report its default model/effort. Cannot safely reset this selection; choose explicit values.")
                        }
                        completion(.success((resetModel ? defaultModel : model,
                                             resetEffort ? defaultEffort : reasoningEffort?.rawValue)))
                    } catch { completion(.failure(error)) }
                }
            } catch { completion(.failure(error)) }
        }
    }

    private func codexModels(cursor: String? = nil, rows: [[String: Any]] = [],
                             cursors: Set<String> = [],
                             completion: @escaping (Result<[[String: Any]], Error>) -> Void) throws {
        var params: [String: Any] = ["includeHidden": false, "limit": 100]
        if let cursor { params["cursor"] = cursor }
        try request("model/list", params: params) { result in
            do {
                let response = try result.get()
                let models = rows + (response["data"] as? [[String: Any]] ?? [])
                guard models.count <= 4096 else { throw AgentRuntimeError("Codex model catalog is too large.") }
                if let next = response["nextCursor"] as? String, !next.isEmpty {
                    guard cursors.count < 32, !cursors.contains(next) else {
                        throw AgentRuntimeError("Codex model catalog pagination did not finish.")
                    }
                    try self.codexModels(cursor: next, rows: models, cursors: cursors.union([next]), completion: completion)
                } else { completion(.success(models)) }
            } catch { completion(.failure(error)) }
        }
    }

    private var planMode = false
    /// Tools the user allowed for the rest of the conversation; never questions or plans.
    private var alwaysAllowedTools: Set<String> = []
    private var planModeConfigured = false
    private var appliedClaudePlanMode = false

    func setPlan(_ enabled: Bool) async throws {
        try await perform { self.planMode = enabled; self.planModeConfigured = true }
    }

    func approve(request: String, allow: Bool) async throws {
        try await approve(request: request, allow: allow, always: false, reason: nil)
    }

    func approve(request: String, allow: Bool, always: Bool, reason: String?) async throws {
        try await perform {
            // A mode change may have answered the same request while a manual
            // response was in flight. Return the real, already-completed outcome.
            if self.approvals[request] == nil, self.completedApprovals.contains(request) { return }
            if let reason = self.expiredRequests[request] { throw AgentRuntimeError(reason) }
            guard let approval = self.approvals[request] else { throw AgentRuntimeError("Approval is no longer pending.") }
            if reason != nil, self.provider != .claude {
                throw AgentRuntimeError("Codex can't take a reason with a denial.")
            }
            guard always else {
                try self.resolveApproval(request, allow: allow, reason: reason)
                return
            }
            guard allow, self.provider == .claude, AgentApprovalScope.canAlwaysAllow(approval["tool_name"] as? String ?? "") else {
                throw AgentRuntimeError("This request can only be allowed once.")
            }
            try self.resolve(request, decision: "allowAlways")
        }
    }

    func setAlwaysAllowed(_ tools: Set<String>) async throws {
        try await perform {
            self.alwaysAllowedTools = tools
            try self.allowPendingAutomatically()
        }
    }

    private func allowPendingAutomatically() throws {
        for id in approvals.keys.sorted() {
            guard let approval = approvals[id], automaticallyAllows(approval), presented[id]?.request.first(.allowOnce) != nil else { continue }
            try resolveApproval(id, allow: true, automatic: true)
        }
    }

    /// Changes host approvals immediately without restarting an active turn.
    /// Codex native prompting/sandbox changes are sent on its next turn/start.
    func setAccess(_ mode: AgentAccessMode) async throws {
        try await perform {
            self.accessMode = mode
            try self.allowPendingAutomatically()
        }
    }

    private func automaticallyAllows(_ approval: [String: Any]) -> Bool {
        let tool = approval["tool_name"] as? String
        guard tool != "AskUserQuestion", tool != "ExitPlanMode",
              approval["method"] as? String != "mcpServer/elicitation/request" else { return false }
        if provider == .claude, let tool, alwaysAllowedTools.contains(tool) { return true }
        switch accessMode {
        case .ask: return false
        case .fullAccess: return true
        case .standard:
            guard provider == .claude, let tool else { return false }
            return ["Read", "Glob", "Grep", "WebSearch", "WebFetch"].contains(tool)
        }
    }

    /// The legacy Allow and Deny: Allow is the one-time approval, Deny declines, or
    /// cancels when the provider offered no plain decline.
    private func resolveApproval(_ id: String, allow: Bool, automatic: Bool = false, reason: String? = nil) throws {
        guard let offered = presented[id]?.request else { throw AgentRuntimeError("Approval is no longer pending.") }
        let choice = allow ? offered.first(.allowOnce) : offered.first(.decline) ?? offered.first(.cancel)
        guard let choice else {
            throw AgentRuntimeError("\(provider.name) did not offer a one-time \(allow ? "approval" : "rejection"). Choose one of the request's own options.")
        }
        try resolve(id, decision: choice.id, automatic: automatic, reason: reason)
    }

    /// Sends the provider's own value for `decision` and records it on the request's row.
    private func resolve(_ id: String, decision: String, automatic: Bool = false, reason: String? = nil,
                         answers: [String: [String]]? = nil) throws {
        guard let approval = approvals[id] ?? questions[id]?.wire, let presentation = presented[id],
              let choice = presentation.request.decision(decision), let value = presentation.offered[decision] else {
            throw AgentRuntimeError("That option isn't offered for this request.")
        }
        if provider == .claude {
            let input = approval["input"] as? [String: Any] ?? [:]
            let allow = choice.kind.allows
            var response: [String: Any] = ["behavior": allow ? "allow" : "deny"]
            let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if allow { response["updatedInput"] = input }
            else { response["message"] = reason.isEmpty ? "User declined tool execution." : "User declined tool execution: " + reason }
            if let toolID = approval["tool_use_id"] { response["toolUseID"] = toolID }
            try write(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
            if choice.kind == .allowAlways, let tool = approval["tool_name"] as? String {
                alwaysAllowedTools.insert(tool)
            }
        } else {
            let wireID = approval["wireID"] ?? id
            switch approval["method"] as? String {
            case "item/permissions/requestApproval":
                try write(["id": wireID, "result": AgentProviderRequests.codexPermissionsResponse(decision: decision, offered: value)])
            case "mcpServer/elicitation/request":
                var result: [String: Any] = ["action": value]
                if choice.kind == .submit {
                    guard let form = presentation.form else { throw AgentRuntimeError("This request has no form.") }
                    let answers = answers ?? [:]
                    do { try form.validate(answers: answers, cancelled: false) } catch { throw AgentRuntimeError("Answer each required question first.") }
                    result["content"] = try AgentProviderRequests.elicitationContent(answers, fields: presentation.fields)
                }
                try write(["id": wireID, "result": result])
            default:
                try write(["id": wireID, "result": ["decision": value]])
            }
        }
        if choice.kind.allows, approval["tool_name"] as? String == "ExitPlanMode" {
            planMode = false; appliedClaudePlanMode = false
            onEvent(.planMode(false))
        }
        approvals.removeValue(forKey: id)
        questions.removeValue(forKey: id)
        if id.utf8.count <= 1024, completedApprovals.insert(id).inserted {
            completedApprovalOrder.append(id)
            if completedApprovalOrder.count > 512 {
                completedApprovals.remove(completedApprovalOrder.removeFirst())
            }
        }
        let text = automatic ? "Automatically approved" : AgentProviderRequests.outcomeText(choice.kind, title: choice.title)
        settle(id, text: text, outcome: .init(decision: choice.id, kind: choice.kind, title: choice.title,
                                              source: automatic ? .automatic : .user))
        if choice.kind == .allowAlways, provider == .claude, let tool = approval["tool_name"] as? String, !automatic {
            onEvent(.item(AgentChatItem(kind: .notice, text: "\(tool) runs without asking for the rest of this conversation.")))
            try allowPendingAutomatically()
        }
        onEvent(.status(approvals.isEmpty && questions.isEmpty ? (busy ? .working : .idle) : .waiting))
    }

    /// Answers a pending request with one of the decisions it offered.
    func decide(request id: String, decision: String, answers: [String: [String]]?) async throws {
        try await perform {
            if let reason = self.expiredRequests[id] { throw AgentRuntimeError(reason) }
            guard self.approvals[id] != nil || self.questions[id] != nil else {
                if self.completedApprovals.contains(id) || self.answeredQuestions.contains(id) { return }
                throw AgentRuntimeError("This request is no longer pending.")
            }
            guard self.presented[id]?.request.decision(decision) != nil else {
                throw AgentRuntimeError("That option isn't offered for this request.")
            }
            try self.resolve(id, decision: decision, answers: answers)
            if self.questions[id] == nil { self.answeredQuestions.insert(id) }
        }
    }

    /// Records how a request ended on its row, keeping what it asked for.
    private func settle(_ id: String, text: String, outcome: AgentApprovalRequest.Outcome) {
        var row = pendingRows.removeValue(forKey: id) ?? AgentChatItem(id: id, kind: .approval, text: text)
        row.text = text
        row.isComplete = true
        row.updatedAt = nil
        if var request = presented.removeValue(forKey: id)?.request ?? row.approval {
            request.outcome = outcome
            row.approval = request
        }
        for (key, value) in requestKeys where value == id { requestKeys.removeValue(forKey: key) }
        onEvent(.item(row))
    }

    /// A key for a new provider request that no pending one uses: a string ID equal to a
    /// pending number's text gets a suffix rather than answering the other request.
    private func requestKey(_ raw: AgentProviderRequestID) -> String {
        if let existing = requestKeys[raw] { return existing }
        let key = raw.text
        guard approvals[key] != nil || questions[key] != nil || requestKeys.values.contains(key) else { return key }
        return key + (raw.isNumber ? "#number" : "#string")
    }

    private func refuseCodex(_ wireID: Any, method: String, reason: String) throws {
        try write(["id": wireID, "error": ["code": -32601, "message": "Tab does not support this request: \(reason)"]])
        onEvent(.item(AgentChatItem(kind: .notice, text: "Unsupported Codex request (\(method)): \(reason)")))
    }

    func interrupt() async throws {
        try await perform {
            guard self.busy else { return }
            self.interruptRequested = true
            if self.provider == .claude {
                if !self.unconsumedClaudeInputs.isEmpty {
                    self.resumeSession = self.claude.sessionID ?? self.resumeSession
                    self.processGeneration = UUID()
                    self.process?.stop()
                    self.process = nil
                    let stopped = self.claude.endProcess()
                    if stopped > 0 {
                        self.onEvent(.item(AgentChatItem(kind: .notice, text: Self.stoppedAgents(stopped, because: "Claude was restarted to stop the response"))))
                    }
                    self.ready = false
                    let count = self.unconsumedClaudeInputs.count
                    self.unconsumedClaudeInputs.removeAll()
                    self.onEvent(.item(AgentChatItem(kind: .notice, text: "Stopped Claude and cancelled \(count) unconsumed follow-up(s). Delivered prompts remain in the transcript; review them before retrying.")))
                    self.resolvePending(AgentRuntimeError("Interrupted"))
                    self.completeTurn()
                    return
                }
                try self.request("interrupt", params: [:], completion: self.interruptAcknowledged)
            } else if let threadID = self.threadID, let turnID = self.turnID {
                try self.request("turn/interrupt", params: ["threadId": threadID, "turnId": turnID],
                                 completion: self.interruptAcknowledged)
            } else { self.close() }
        }
    }

    /// A refused or unanswered stop isn't a failure: the turn may have just finished, and one
    /// that keeps running is stopped by its session after a bounded wait.
    private func interruptAcknowledged(_ result: Result<[String: Any], Error>) {
        if case .failure(let error) = result {
            ServerLog.error("\(provider.name) did not acknowledge an interrupt: \(error.localizedDescription)")
        }
    }

    func stop() {
        queue.async { self.close() }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        process?.stop()
        resolvePending(AgentRuntimeError("Agent stopped."))
        resolveDeferredSends(AgentRuntimeError("Agent stopped."))
        finishApprovals()
        onEvent(.status(.closed))
    }

    func prepare(_ launch: AgentLaunch) {
        queue.sync { self.launch = launch }
    }

    private func perform(_ action: @escaping () throws -> Void) async throws {

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard !self.closed, !self.failed else { throw AgentRuntimeError("Agent is not running.") }
                    try action()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func write(_ message: [String: Any]) throws {
        guard let process, !closed, !failed else { throw AgentRuntimeError("Agent process is not running.") }
        try process.write(message)
    }

    private func request(_ method: String, params: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        sequence += 1
        let id = String(sequence)
        if provider == .claude {
            var request = params
            request["subtype"] = method
            try write(["type": "control_request", "request_id": id, "request": request])
        } else { try write(["id": sequence, "method": method, "params": params]) }
        pending[id] = completion
        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard let self, let completion = self.pending.removeValue(forKey: id) else { return }
            completion(.failure(AgentRuntimeError("\(self.provider.name) timed out responding to \(method). Check CLI authentication and updates; on macOS, also check whether system security is blocking the executable.")))
        }
    }

    private func receive(_ data: Data) {
        guard !closed, !failed else { return }
        do {
            guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentRuntimeError("Expected a JSON object from agent.")
            }
            let source = AgentProviderJSON(data: data)
            if provider == .claude { try receiveClaude(message, source: source) } else { try receiveCodex(message, source: source) }
        } catch { fail("Invalid \(provider.name) protocol: \(error.localizedDescription)") }
    }

    private func receiveClaude(_ message: [String: Any], source: AgentProviderJSON) throws {
        let type = message["type"] as? String
        if type == "control_response", let response = message["response"] as? [String: Any],
           let id = response["request_id"] as? String, let completion = pending.removeValue(forKey: id) {
            if response["subtype"] as? String == "error" {
                completion(.failure(AgentRuntimeError(response["error"] as? String ?? "Claude control request failed.")))
            } else { completion(.success(response["response"] as? [String: Any] ?? [:])) }
            return
        }
        if type == "control_request", let id = message["request_id"] as? String,
           let request = message["request"] as? [String: Any] {
            guard request["subtype"] as? String == "can_use_tool" else {
                try write(["type": "control_response", "response": ["subtype": "error", "request_id": id,
                            "error": "Tab supports tool approvals only; this interactive request is unsupported."]])
                onEvent(.item(AgentChatItem(kind: .notice, text: "Unsupported Claude interaction: \(request["subtype"] as? String ?? "unknown")")))
                return
            }
            if request["tool_name"] as? String == "AskUserQuestion" {
                let input = request["input"] as? [String: Any] ?? [:]
                try presentQuestions(id: id, form: AgentQuestionParser.parse(input, claude: true), wire: request,
                                     approval: AgentApprovalRequest(kind: "question", decisions: [], origin: claudeOrigin(id, request: request)))
                return
            }
            if request["tool_name"] as? String == "ExitPlanMode" {
                // Capture actual supplied proposal content without changing this
                // native provider's existing approval/permission behavior.
                claude.capturePlan(nativeID: request["tool_use_id"] as? String ?? id, name: "ExitPlanMode", input: request["input"])
            }
            approvals[id] = request
            let presentation = AgentProviderRequests.claude(request, origin: claudeOrigin(id, request: request))
            presented[id] = presentation
            if automaticallyAllows(request) {
                try resolveApproval(id, allow: true, automatic: true)
                return
            }
            let row = AgentChatItem(id: id, kind: .approval, text: request["tool_name"] as? String ?? "Tool approval",
                                    detail: agentRuntimeJSON(request["input"]), isComplete: false,
                                    workContext: .init(requestKind: agentClaudeApprovalKind(request["tool_name"] as? String ?? "")),
                                    approval: presentation.request)
            pendingRows[id] = row
            onEvent(.item(row))
            onEvent(.status(.waiting))
            return
        }
        if type == "control_cancel_request", let id = message["request_id"] as? String {
            if questions.removeValue(forKey: id) != nil || approvals.removeValue(forKey: id) != nil {
                if expiredRequests.count >= 512 { expiredRequests.removeAll() }
                expiredRequests[id] = "Claude cancelled this request; nothing was sent."
                settle(id, text: "Cancelled", outcome: .init(title: "Cancelled by Claude", source: .provider))
                onEvent(.status(approvals.isEmpty && questions.isEmpty ? .working : .waiting))
            }
            return
        }
        observeClaudeChildren(message)
        if type == "user", message["isReplay"] as? Bool == true, let input = message["uuid"] as? String {
            unconsumedClaudeInputs.remove(input.lowercased())
        }
        // Output with no turn running is a turn Claude began itself, such as its answer
        // to a background agent that finished. It gets a turn, so it can be watched and stopped.
        if !busy, ready, type == "stream_event" || type == "assistant",
           message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] is NSNull {
            busy = true
            providerInitiatedTurn = true
            interruptRequested = false
            claude.beginTurn()
            let reason = claude.lastFinishedBackground.map { "Background agent “\($0.description)” finished" }
                ?? "Claude continued on its own"
            onEvent(.providerTurn(reason: reason))
            onEvent(.status(.working))
        }
        claude.interrupted = interruptRequested
        if type == "rate_limit_event", let info = message["rate_limit_info"] as? [String: Any] {
            onEvent(.activity(Self.rateLimitActivity(info)))
        }
        claude.receive(message, source: source)
        if type == "result" {
            if message["is_error"] as? Bool == true, !interruptRequested {
                fail((message["errors"] as? [String])?.joined(separator: "\n") ?? message["result"] as? String ?? "Claude turn failed.")
            } else { completeTurn() }
        }
    }

    private func receiveCodex(_ message: [String: Any], source: AgentProviderJSON) throws {
        let method = message["method"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        if method == nil, let wireID = message["id"], let completion = pending.removeValue(forKey: agentRuntimeID(wireID)) {
            if let error = message["error"] as? [String: Any] {
                completion(.failure(AgentRuntimeError(error["message"] as? String ?? "Codex request failed.")))
            } else { completion(.success(message["result"] as? [String: Any] ?? [:])) }
            return
        }
        if let method, let wireID = message["id"] {
            let raw = AgentProviderRequestID(wireID)
            let id = requestKey(raw)
            let origin = codexOrigin(raw, params: params)
            if method == "item/tool/requestUserInput" || method == "tool/requestUserInput" {
                var wire = params
                wire["wireID"] = wireID
                try presentQuestions(id: id, form: AgentQuestionParser.parse(params, claude: false), wire: wire,
                                     approval: AgentApprovalRequest(kind: "question", decisions: [], origin: origin))
                requestKeys[raw] = id
                return
            }
            if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval"
                || method == "item/permissions/requestApproval" {
                let presentation: AgentProviderRequests.Presented
                do {
                    presentation = method == "item/permissions/requestApproval"
                        ? try AgentProviderRequests.codexPermissions(params, origin: origin)
                        : AgentProviderRequests.codexCommandOrFile(method, params: params, origin: origin)
                } catch {
                    try refuseCodex(wireID, method: method, reason: error.localizedDescription)
                    return
                }
                guard !presentation.request.decisions.isEmpty else {
                    try refuseCodex(wireID, method: method, reason: "Codex offered no decision Tab can send.")
                    return
                }
                var approval = params
                approval["wireID"] = wireID
                approval["method"] = method
                approvals[id] = approval
                presented[id] = presentation
                requestKeys[raw] = id
                if automaticallyAllows(approval), presentation.request.first(.allowOnce) != nil {
                    try resolveApproval(id, allow: true, automatic: true)
                    return
                }
                let kind = method == "item/fileChange/requestApproval" ? "file-change" : method == "item/permissions/requestApproval" ? "permissions" : "command"
                let title = params["command"] as? String ?? params["reason"] as? String
                    ?? (kind == "permissions" ? "Grant extra permissions" : "Approve file changes")
                let row = AgentChatItem(id: id, kind: .approval, text: title,
                                        detail: agentRuntimeJSON(params), isComplete: false,
                                        workContext: .init(providerTurnID: params["turnId"] as? String, requestKind: kind),
                                        approval: presentation.request)
                pendingRows[id] = row
                onEvent(.item(row))
                onEvent(.status(.waiting))
            } else if method == "mcpServer/elicitation/request" {
                let presentation: AgentProviderRequests.Presented
                do { presentation = try AgentProviderRequests.codexElicitation(params, origin: origin) } catch {
                    try refuseCodex(wireID, method: method, reason: error.localizedDescription)
                    return
                }
                var wire = params
                wire["wireID"] = wireID
                wire["method"] = method
                presented[id] = presentation
                requestKeys[raw] = id
                if let form = presentation.form {
                    try presentQuestions(id: id, form: form, wire: wire, approval: presentation.request,
                                         title: presentation.request.summary ?? "Questions for you")
                } else {
                    approvals[id] = wire
                    let row = AgentChatItem(id: id, kind: .approval, text: presentation.request.summary ?? "Respond to an MCP server",
                                            isComplete: false, workContext: .init(providerTurnID: params["turnId"] as? String, requestKind: "elicitation"),
                                            approval: presentation.request)
                    pendingRows[id] = row
                    onEvent(.item(row))
                    onEvent(.status(.waiting))
                }
            } else {
                try write(["id": wireID, "error": ["code": -32601, "message": "Tab does not support this interaction: \(method)"]])
                onEvent(.item(AgentChatItem(kind: .notice, text: "Unsupported Codex interaction: \(method)")))
            }
            return
        }
        if method == "serverRequest/resolved", let requestID = params["requestId"] {
            let id = requestKeys[AgentProviderRequestID(requestID)] ?? agentRuntimeID(requestID)
            if questions.removeValue(forKey: id) != nil || approvals.removeValue(forKey: id) != nil {
                if expiredRequests.count >= 512 { expiredRequests.removeAll() }
                expiredRequests[id] = "This request was already settled elsewhere; nothing was sent."
                settle(id, text: "Request resolved or cancelled by the provider",
                       outcome: .init(title: "Resolved elsewhere", source: .provider))
                onEvent(.status(approvals.isEmpty && questions.isEmpty ? (busy ? .working : .idle) : .waiting))
            }
        }
        observeCodexChildren(method: method, params: params)
        // Agents Codex starts run in threads of their own; their notifications must not
        // end or fill this conversation's turn.
        if message["id"] == nil, let thread = params["threadId"] as? String, let threadID, thread != threadID { return }
        if method == "thread/tokenUsage/updated", params["threadId"] as? String != threadID { return }
        codex.receive(message, source: source)
        if method == "turn/started", let turn = params["turn"] as? [String: Any] { turnID = turn["id"] as? String }
        if method == "turn/completed" {
            let turn = params["turn"] as? [String: Any] ?? [:]
            if turn["status"] as? String == "failed", !interruptRequested {
                let error = turn["error"] as? [String: Any]
                reportCodexLimit(error)
                fail(error?["message"] as? String ?? "Codex turn failed.")
            } else { completeTurn() }
        }
        if method == "error", params["willRetry"] as? Bool == true {
            retryAttempts += 1
            let error = params["error"] as? [String: Any]
            onEvent(.activity(AgentChatActivity(kind: .retrying, attempt: retryAttempts,
                message: (error?["message"] as? String).flatMap(agentSubagentText))))
        } else if method != nil, method != "error", retryAttempts > 0 {
            // The provider got through.
            retryAttempts = 0
            onEvent(.activity(nil))
        }
        if method == "error", params["willRetry"] as? Bool != true, !interruptRequested {
            let error = params["error"] as? [String: Any]
            reportCodexLimit(error)
            fail(error?["message"] as? String ?? "Codex reported an error.")
        }
    }

    private func completeTurn() {
        if provider == .claude, !unconsumedClaudeInputs.isEmpty {
            // Claude answers the remaining follow-ups in a turn of their own.
            claude.beginTurn()
            finishApprovals()
            onEvent(.status(.working))
            return
        }
        let deferred = deferredSends
        deferredSends.removeAll()
        providerInitiatedTurn = false
        busy = false
        interruptRequested = false
        turnID = nil
        finishApprovals()
        // A send that waited for this turn starts now, so its own turn follows without
        // an idle moment in which the queue could deliver something else.
        if let next = deferred.first {
            next(nil)
            for send in deferred.dropFirst() { send(nil) }
            return
        }
        onEvent(.status(.idle))
    }

    private func resolveDeferredSends(_ error: Error) {
        let deferred = deferredSends
        deferredSends.removeAll()
        providerInitiatedTurn = false
        for send in deferred { send(error) }
    }

    /// Claude's `rate_limit_event`: a warning near the limit, a stop at it, else nothing.
    static func rateLimitActivity(_ info: [String: Any]) -> AgentChatActivity? {
        let resets = (info["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        switch info["status"] as? String {
        case "allowed_warning":
            let used = (info["utilization"] as? NSNumber).map { "\(Int(($0.doubleValue * 100).rounded()))% of the usage limit used" }
            return AgentChatActivity(kind: .rateLimitWarning, resumesAt: resets, message: used)
        case "rejected":
            return AgentChatActivity(kind: .rateLimited, resumesAt: resets, message: "Usage limit reached")
        default: return nil
        }
    }

    /// A transcript note for agents that stopped with their provider process.
    static func stoppedAgents(_ count: Int, because reason: String) -> String {
        (count == 1 ? "Stopped 1 running agent" : "Stopped \(count) running agents") + " because " + reason + "."
    }

    private func finishApprovals() {
        for id in questions.keys.sorted() {
            settle(id, text: "Question cancelled — response ended", outcome: .init(title: "The response ended", source: .expired))
        }
        questions.removeAll()
        for id in approvals.keys.sorted() {
            settle(id, text: "No longer pending", outcome: .init(title: "The response ended", source: .expired))
        }
        approvals.removeAll()
        presented.removeAll()
        pendingRows.removeAll()
        requestKeys.removeAll()
    }

    private func resolvePending(_ error: Error) {
        let completions = Array(pending.values)
        pending.removeAll()
        for completion in completions { completion(.failure(error)) }
    }

    private func fail(_ message: String) {
        guard !failed, !closed else { return }
        failed = true
        busy = false
        resolveDeferredSends(AgentRuntimeError(message))
        process?.stop()
        finishApprovals()
        onEvent(.failure(message))
        onEvent(.status(.failed))
        resolvePending(AgentRuntimeError(message))
    }

    deinit { process?.stop() }
}

internal func agentRuntimeID(_ value: Any) -> String { (value as? String) ?? String(describing: value) }

internal func agentRuntimeJSON(_ value: Any?, originalJSON: String? = nil) -> String? {
    if let value, JSONSerialization.isValidJSONObject(value), let originalJSON { return originalJSON }
    guard let value, JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return value as? String }
    return text
}

internal func agentRuntimeStructuredJSON(_ value: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { return nil }
    return string
}


extension AgentRuntime {
    private func presentQuestions(id: String, form: AgentQuestionnaire, wire: [String: Any],
                                  approval: AgentApprovalRequest? = nil, title: String = "Questions for you") throws {
        guard questions.count < 12, questions.values.reduce(0, { $0 + $1.form.transcriptByteCount }) + form.transcriptByteCount <= 128 * 1024 else { throw AgentRuntimeError("Too many pending question forms.") }
        questions[id] = (form, wire)
        if let approval, presented[id] == nil { presented[id] = .init(request: approval, offered: [:]) }
        let row = AgentChatItem(id: id, kind: .approval, text: title, isComplete: false,
                                questionnaire: form, approval: approval)
        pendingRows[id] = row
        onEvent(.item(row))
        onEvent(.status(.waiting))
    }

    func answer(request id: String, answers: [String: [String]], cancelled: Bool) async throws {
        try await perform {
            if let reason = self.expiredRequests[id] { throw AgentRuntimeError(reason) }
            guard let pending = self.questions[id] else {
                if self.answeredQuestions.contains(id) { return }
                throw AgentRuntimeError("This question is no longer pending.")
            }
            try pending.form.validate(answers: answers, cancelled: cancelled)
            if pending.wire["method"] as? String == "mcpServer/elicitation/request" {
                try self.resolve(id, decision: cancelled ? "cancel" : "accept", answers: answers)
                self.answeredQuestions.insert(id)
                return
            }
            if self.provider == .claude {
                var response: [String: Any] = ["behavior": cancelled ? "deny" : "allow"]
                if cancelled { response["message"] = "The user cancelled the questions." }
                else {
                    var input = pending.wire["input"] as? [String: Any] ?? [:]
                    input["answers"] = answers.mapValues { $0.joined(separator: ", ") }
                    response["updatedInput"] = input
                }
                if let tool = pending.wire["tool_use_id"] { response["toolUseID"] = tool }
                try self.write(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
            } else {
                let values: [String: Any] = cancelled ? [:] : answers.mapValues { ["answers": $0] }
                try self.write(["id": pending.wire["wireID"] ?? id, "result": ["answers": values]])
            }
            self.questions.removeValue(forKey: id)
            self.answeredQuestions.insert(id)
            if self.answeredQuestions.count > 512 { self.answeredQuestions = [id] }
            let summary = cancelled ? nil : pending.form.questions.map { question in
                question.title + ": " + (question.secret ? "[Private answer provided]" : (answers[question.id] ?? []).joined(separator: ", "))
            }.joined(separator: "\n")
            var row = self.pendingRows[id] ?? AgentChatItem(id: id, kind: .approval, text: "")
            row.detail = summary
            self.pendingRows[id] = row
            self.settle(id, text: cancelled ? "Questions cancelled" : "Answered \(pending.form.questions.count) question(s)",
                        outcome: .init(title: cancelled ? "Cancelled" : "Answered", source: .user))
            self.onEvent(.status(self.approvals.isEmpty && self.questions.isEmpty ? (self.busy ? .working : .idle) : .waiting))
        }
    }
}

// MARK: Request origins, child agents and usage limits

extension AgentRuntime {
    fileprivate static let maxTrackedChildren = 256

    fileprivate func claudeOrigin(_ id: String, request: [String: Any]) -> AgentRequestOrigin {
        let agent = request["agent_id"] as? String
        let tool = agent.flatMap { claudeChildren[$0] }
        return AgentRequestOrigin(providerRequestID: id, threadID: claude.sessionID ?? resumeSession,
                                  childAgentID: agent, childToolUseID: tool, childTitle: tool.flatMap { claudeAgentTitles[$0] })
    }

    fileprivate func codexOrigin(_ raw: AgentProviderRequestID, params: [String: Any]) -> AgentRequestOrigin {
        let thread = params["threadId"] as? String
        let child = thread.flatMap { thread in thread == threadID ? nil : codexChildren[thread] }
        let isChild = thread != nil && threadID != nil && thread != threadID
        return AgentRequestOrigin(providerRequestID: raw.text, numericID: raw.isNumber ? true : nil, threadID: thread,
                                  childAgentID: isChild ? thread : nil, childToolUseID: child?.toolUseID, childTitle: child?.title)
    }

    /// Learns which Agent tool call each Claude subagent belongs to, and expires a
    /// subagent's pending requests once its Agent tool call has a result.
    fileprivate func observeClaudeChildren(_ message: [String: Any]) {
        let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        if let agent = message["agent_id"] as? String, let parent = message["parent_tool_use_id"] as? String,
           claudeChildren[agent] == nil, claudeChildren.count < Self.maxTrackedChildren {
            claudeChildren[agent] = parent
        }
        let topLevel = message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] is NSNull
        guard topLevel else { return }
        for block in content {
            if block["type"] as? String == "tool_use", let id = block["id"] as? String,
               ["Agent", "Task"].contains(block["name"] as? String ?? ""),
               let description = (block["input"] as? [String: Any])?["description"] as? String,
               claudeAgentTitles.count < Self.maxTrackedChildren {
                claudeAgentTitles[id] = String(description.prefix(200))
            }
            if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String,
               claudeChildren.values.contains(id) {
                expireChildRequests(toolUseID: id, childAgentID: nil)
            }
        }
    }

    /// Learns which collab tool call started each Codex agent thread, and expires its
    /// pending requests when that thread closes or the agent ends.
    fileprivate func observeCodexChildren(method: String?, params: [String: Any]) {
        if method == "account/rateLimits/updated", let limits = params["rateLimits"] as? [String: Any] {
            let windows = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
            let exhausted = windows.filter { ($0["usedPercent"] as? NSNumber)?.intValue ?? 0 >= 100 }
            let resets = exhausted.compactMap { ($0["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
            codexLimitReset = resets.max() ?? (exhausted.isEmpty ? nil : codexLimitReset)
            return
        }
        if method == "thread/closed", let thread = params["threadId"] as? String, thread != threadID {
            expireChildRequests(toolUseID: nil, childAgentID: thread)
            return
        }
        guard method == "item/started" || method == "item/completed",
              let item = params["item"] as? [String: Any], item["type"] as? String == "collabAgentToolCall",
              let id = item["id"] as? String else { return }
        let title = (item["prompt"] as? String).map { String($0.split(whereSeparator: \.isNewline).first?.prefix(200) ?? "") }
        for thread in item["receiverThreadIds"] as? [String] ?? [] where codexChildren[thread] == nil {
            guard codexChildren.count < Self.maxTrackedChildren else { break }
            codexChildren[thread] = (id, title)
        }
        let ended: Set<String> = ["completed", "errored", "shutdown", "notFound", "interrupted"]
        for (thread, state) in item["agentsStates"] as? [String: [String: Any]] ?? [:]
            where ended.contains(state["status"] as? String ?? "") {
            expireChildRequests(toolUseID: nil, childAgentID: thread)
        }
    }

    /// A child agent ended with requests pending: nobody is left to receive an answer,
    /// so they end unanswered and a late answer is refused rather than sent elsewhere.
    fileprivate func expireChildRequests(toolUseID: String?, childAgentID: String?) {
        let ids = presented.compactMap { id, presentation -> String? in
            guard let origin = presentation.request.origin, origin.isChild else { return nil }
            let matches = (childAgentID != nil && origin.childAgentID == childAgentID)
                || (toolUseID != nil && origin.childToolUseID == toolUseID)
            return matches ? id : nil
        }
        for id in ids.sorted() {
            guard approvals.removeValue(forKey: id) != nil || questions.removeValue(forKey: id) != nil else { continue }
            let reason = "The agent that asked has ended, so this request can no longer be answered."
            if expiredRequests.count >= 512 { expiredRequests.removeAll() }
            expiredRequests[id] = reason
            settle(id, text: "No longer pending — the agent that asked ended",
                   outcome: .init(title: "The agent that asked ended", source: .expired))
        }
        if !ids.isEmpty { onEvent(.status(approvals.isEmpty && questions.isEmpty ? (busy ? .working : .idle) : .waiting)) }
    }

    /// A Codex turn that failed at a usage or rate limit reports when it resets.
    fileprivate func reportCodexLimit(_ error: [String: Any]?) {
        guard let info = error?["codexErrorInfo"] as? String, ["usageLimitExceeded", "rateLimitExceeded"].contains(info) else { return }
        onEvent(.activity(AgentChatActivity(kind: .rateLimited, resumesAt: codexLimitReset,
                                            message: (error?["message"] as? String).flatMap(agentSubagentText) ?? "Usage limit reached")))
    }
}
