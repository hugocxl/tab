import Foundation
import TabCore
import TabProtocol

internal enum AgentRuntimeEvent: Sendable {
    case item(AgentChatItem)
    case textDelta(id: String, text: String)
    case status(AgentChatStatus)
    case providerSession(String)
    case contextUsage(AgentContextUsage)
    case resolvedModel(String)
    case failure(String)
}

internal struct AgentRuntimeError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// All protocol state is confined to queue; process readers never call client code directly.
// Raw control envelope reference: T3 Code
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
    private var ready = false
    private var sequence = 0
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var approvals: [String: [String: Any]] = [:]
    private var completedApprovals: Set<String> = []
    private var completedApprovalOrder: [String] = []
    private var threadID: String?
    private var turnID: String?
    private var model: String?
    private var reasoningEffort: AgentReasoningEffort?
    private var hasSubmittedTurn = false
    private var processGeneration = UUID()
    private var accessMode: AgentAccessMode = .standard
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
                guard !self.closed, !self.failed else {
                    continuation.resume(throwing: AgentRuntimeError("Agent is closed or failed; open a new Agent Tab to resume."))
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
        }
    }

    private func restartClaudeSelection() throws {
        // T3's query identity includes model and effort. Clearing effort must
        // reload provider settings, not silently retain the previous override.
        guard let session = claude.sessionID ?? resumeSession else {
            throw AgentRuntimeError("Claude has not supplied a session ID to resume after changing model or effort.")
        }
        processGeneration = UUID()
        process?.stop()
        process = nil
        pending.removeAll() // Only non-awaited interrupt acknowledgments can remain after an idle turn.
        resumeSession = session
        ready = false
    }

    private func start(model: String?, reasoningEffort: AgentReasoningEffort?,
                       completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        var environment = AgentProcess.environment()
        // A nested SDK process is intentional, not an interactive Claude session.
        environment.removeValue(forKey: "CLAUDECODE")
        var arguments = provider == .claude
            ? ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
               "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", "default"]
            : ["app-server"]
        if provider == .claude {
            if let resumeSession { arguments += ["--resume", resumeSession] }
            if let model { arguments += ["--model", model] }
            if let reasoningEffort { arguments += ["--effort", claudeWireEffort(reasoningEffort, model: model)] }
            self.model = model
            self.reasoningEffort = reasoningEffort
        }
        let launch = try launchBuilder?(arguments) ?? launchOverride ?? AgentProcess.Launch(
            executable: AgentProcess.resolve(provider == .claude ? "claude" : "codex", environment: environment),
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
                if case .success = result { self.ready = true }
                completion(result)
            })
        } else {
            try request("initialize", params: ["clientInfo": ["name": "tab", "version": Release.version]], completion: { result in
                do {
                    _ = try result.get()
                    try self.write(["method": "initialized"])
                    var params: [String: Any] = ["cwd": self.directory,
                        "approvalPolicy": self.accessMode == .fullAccess ? "never" : self.accessMode == .ask ? "untrusted" : "on-request",
                        "sandbox": self.accessMode == .fullAccess ? "danger-full-access" : self.accessMode == .ask ? "read-only" : "workspace-write"]
                    if let model { params["model"] = model }
                    if let resumeSession = self.resumeSession { params["threadId"] = resumeSession }
                    try self.request(self.resumeSession == nil ? "thread/start" : "thread/resume", params: params) { result in
                        do {
                            let response = try result.get()
                            guard let thread = response["thread"] as? [String: Any], let id = thread["id"] as? String else {
                                throw AgentRuntimeError("Codex did not return a thread ID.")
                            }
                            self.threadID = id
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
                    try self.write(["type": "user", "message": ["role": "user", "content": AgentAttachments.claudeContent(text: text, attachments: attachments)],
                                     "parent_tool_use_id": NSNull(), "session_id": self.claude.sessionID ?? self.resumeSession ?? ""])
                    self.hasSubmittedTurn = true
                    continuation.resume()
                } catch {
                    self.fail(error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
            submitUser(.success([:]))
        } else {
            guard let threadID else { throw AgentRuntimeError("Codex thread is not initialized.") }
            try codexSelection(model: model, reasoningEffort: reasoningEffort) { selection in
                do {
                    let (wireModel, effort) = try selection.get()
                    var params: [String: Any] = ["threadId": threadID, "input": AgentAttachments.codexInput(text: text, attachments: attachments)]
                    // T3 codexRuntimeModeTurnDefaults: explicitly reset on every
                    // turn so leaving Full access restores native prompting/sandboxing.
                    params["approvalPolicy"] = self.accessMode == .fullAccess ? "never" : self.accessMode == .ask ? "untrusted" : "on-request"
                    params["sandboxPolicy"] = ["type": self.accessMode == .fullAccess ? "dangerFullAccess" : self.accessMode == .ask ? "readOnly" : "workspaceWrite"]
                    if let wireModel { params["model"] = wireModel }
                    if let effort { params["effort"] = effort }
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
        // T3 manifest adapter.claudeCode.effortMap for the two legacy profiles.
        if effort == .xhigh, model.contains("opus-4-7") { return "max" }
        if effort == .max, model.contains("sonnet-4-6") { return "high" }
        return effort.rawValue
    }

    private func codexSelection(model: String?, reasoningEffort: AgentReasoningEffort?,
                                completion: @escaping (Result<(String?, String?), Error>) -> Void) throws {
        let resumedDefaults = !hasSubmittedTurn && resumeSession != nil
        let resetModel = model == nil && (resumedDefaults || (hasSubmittedTurn && self.model != nil))
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

    func approve(request: String, allow: Bool) async throws {
        try await perform {
            // A mode change may have answered the same request while a manual
            // response was in flight. Return the real, already-completed outcome.
            if self.approvals[request] == nil, self.completedApprovals.contains(request) { return }
            try self.resolveApproval(request, allow: allow)
        }
    }

    /// Changes host approvals immediately without restarting an active turn.
    /// Codex native prompting/sandbox changes are sent on its next turn/start.
    func setAccess(_ mode: AgentAccessMode) async throws {
        try await perform {
            self.accessMode = mode
            for id in self.approvals.keys.sorted() {
                guard let approval = self.approvals[id], self.automaticallyAllows(approval) else { continue }
                try self.resolveApproval(id, allow: true, automatic: true)
            }
        }
    }

    private func automaticallyAllows(_ approval: [String: Any]) -> Bool {
        let tool = approval["tool_name"] as? String
        guard tool != "AskUserQuestion" else { return false }
        switch accessMode {
        case .ask: return false
        case .fullAccess: return true
        case .standard:
            guard provider == .claude, let tool else { return false }
            return ["Read", "Glob", "Grep", "WebSearch", "WebFetch"].contains(tool)
        }
    }

    private func resolveApproval(_ id: String, allow: Bool, automatic: Bool = false) throws {
        guard let approval = approvals[id] else { throw AgentRuntimeError("Approval is no longer pending.") }
        if provider == .claude {
            let input = approval["input"] as? [String: Any] ?? [:]
            var response: [String: Any] = ["behavior": allow ? "allow" : "deny"]
            if allow { response["updatedInput"] = input } else { response["message"] = "User declined tool execution." }
            if let toolID = approval["tool_use_id"] { response["toolUseID"] = toolID }
            try write(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]])
        } else {
            let available = (approval["availableDecisions"] as? [Any])?.compactMap { $0 as? String }
            let decision = allow ? "accept" : available?.contains("decline") == false ? "cancel" : "decline"
            guard available == nil || available?.contains(decision) == true else {
                throw AgentRuntimeError("Codex did not offer a one-time \(allow ? "approval" : "rejection"). This interaction is unsupported; interrupt the turn instead.")
            }
            try write(["id": approval["wireID"] ?? id, "result": ["decision": decision]])
        }
        approvals.removeValue(forKey: id)
        if id.utf8.count <= 1024, completedApprovals.insert(id).inserted {
            completedApprovalOrder.append(id)
            if completedApprovalOrder.count > 512 {
                completedApprovals.remove(completedApprovalOrder.removeFirst())
            }
        }
        let text = automatic ? "Automatically approved" : allow ? "Approved" : "Declined"
        onEvent(.item(AgentChatItem(id: id, kind: .approval, text: text)))
        onEvent(.status(approvals.isEmpty ? (busy ? .working : .idle) : .waiting))
    }

    func interrupt() async throws {
        try await perform {
            guard self.busy else { return }
            if self.provider == .claude {
                try self.request("interrupt", params: [:]) { result in
                    if case .failure(let error) = result { self.fail(error.localizedDescription) }
                }
            } else if let threadID = self.threadID, let turnID = self.turnID {
                try self.request("turn/interrupt", params: ["threadId": threadID, "turnId": turnID]) { result in
                    if case .failure(let error) = result { self.fail(error.localizedDescription) }
                }
            } else { self.close() }
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
        finishApprovals()
        onEvent(.status(.closed))
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
            if provider == .claude { try receiveClaude(message) } else { try receiveCodex(message) }
        } catch { fail("Invalid \(provider.name) protocol: \(error.localizedDescription)") }
    }

    private func receiveClaude(_ message: [String: Any]) throws {
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
                try write(["type": "control_response", "response": ["subtype": "success", "request_id": id,
                    "response": ["behavior": "deny", "message": "Tab does not yet support structured questions. Ask the user in chat instead."]]])
                onEvent(.item(AgentChatItem(kind: .notice, text: "Claude requested a structured question. Ask it to use plain chat instead.")))
                return
            }
            approvals[id] = request
            if automaticallyAllows(request) {
                try resolveApproval(id, allow: true, automatic: true)
                return
            }
            onEvent(.item(AgentChatItem(id: id, kind: .approval, text: request["tool_name"] as? String ?? "Tool approval",
                                       detail: agentRuntimeJSON(request["input"]), isComplete: false)))
            onEvent(.status(.waiting))
            return
        }
        if type == "control_cancel_request", let id = message["request_id"] as? String {
            if approvals.removeValue(forKey: id) != nil {
                onEvent(.item(AgentChatItem(id: id, kind: .approval, text: "Cancelled")))
                onEvent(.status(approvals.isEmpty ? .working : .waiting))
            }
            return
        }
        claude.receive(message)
        if type == "result" {
            if message["is_error"] as? Bool == true {
                fail((message["errors"] as? [String])?.joined(separator: "\n") ?? message["result"] as? String ?? "Claude turn failed.")
            } else { completeTurn() }
        }
    }

    private func receiveCodex(_ message: [String: Any]) throws {
        let method = message["method"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        if method == nil, let wireID = message["id"], let completion = pending.removeValue(forKey: agentRuntimeID(wireID)) {
            if let error = message["error"] as? [String: Any] {
                completion(.failure(AgentRuntimeError(error["message"] as? String ?? "Codex request failed.")))
            } else { completion(.success(message["result"] as? [String: Any] ?? [:])) }
            return
        }
        if let method, let wireID = message["id"] {
            let id = agentRuntimeID(wireID)
            if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
                var approval = params
                approval["wireID"] = wireID
                approvals[id] = approval
                if automaticallyAllows(approval) {
                    try resolveApproval(id, allow: true, automatic: true)
                    return
                }
                onEvent(.item(AgentChatItem(id: id, kind: .approval, text: params["command"] as? String ?? params["reason"] as? String ?? "Approve file changes",
                                           detail: agentRuntimeJSON(params), isComplete: false)))
                onEvent(.status(.waiting))
            } else {
                try write(["id": wireID, "error": ["code": -32601, "message": "Tab does not support this interaction: \(method)"]])
                onEvent(.item(AgentChatItem(kind: .notice, text: "Unsupported Codex interaction: \(method)")))
            }
            return
        }
        if method == "thread/tokenUsage/updated", params["threadId"] as? String != threadID { return }
        codex.receive(message)
        if method == "turn/started", let turn = params["turn"] as? [String: Any] { turnID = turn["id"] as? String }
        if method == "turn/completed" {
            let turn = params["turn"] as? [String: Any] ?? [:]
            if turn["status"] as? String == "failed" {
                let error = turn["error"] as? [String: Any]
                fail(error?["message"] as? String ?? "Codex turn failed.")
            } else { completeTurn() }
        }
        if method == "error", params["willRetry"] as? Bool != true {
            let error = params["error"] as? [String: Any]
            fail(error?["message"] as? String ?? "Codex reported an error.")
        }
    }

    private func completeTurn() {
        busy = false
        turnID = nil
        finishApprovals()
        onEvent(.status(.idle))
    }

    private func finishApprovals() {
        for id in approvals.keys { onEvent(.item(AgentChatItem(id: id, kind: .approval, text: "No longer pending"))) }
        approvals.removeAll()
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
        process?.stop()
        finishApprovals()
        onEvent(.failure(message))
        onEvent(.status(.failed))
        resolvePending(AgentRuntimeError(message))
    }

    deinit { process?.stop() }
}

internal func agentRuntimeID(_ value: Any) -> String { (value as? String) ?? String(describing: value) }

internal func agentRuntimeJSON(_ value: Any?) -> String? {
    guard let value, JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return value as? String }
    return text
}
