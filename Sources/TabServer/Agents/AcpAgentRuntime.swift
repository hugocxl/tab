import Foundation
import TabCore
import TabProtocol

// Agent Client Protocol (https://agentclientprotocol.com): JSON-RPC 2.0, one message a line
// on stdio. Behavioral reference: the provider source's packages/provider-acp
// AcpSessionRuntime.ts (initialize, authenticate, session/new|load|resume, set_mode only
// without a mode option, set_config_option, set_model, prompt, cancel) and adapter.ts
// (request_permission outcomes), checked against Gemini CLI 0.70.0 and OpenCode 2.3.2.

/// What an ACP agent lets a session choose: a model, a reasoning level and a mode, as
/// `configOptions` (newer agents) or `models` and `modes` (older ones, such as Gemini CLI).
struct AcpSessionOptions: Equatable {
    struct Choice: Equatable {
        var id: String
        var name: String
        var description: String?
    }

    struct Option: Equatable {
        var id: String
        var category: String?
        var current: String?
        var choices: [Choice]
    }

    var configOptions: [Option] = []
    var models: [Choice] = []
    var currentModel: String?
    var modes: [Choice] = []
    var currentMode: String?

    init() {}

    init(_ response: [String: Any]) {
        update(response)
    }

    mutating func update(_ response: [String: Any]) {
        if let options = response["configOptions"] as? [[String: Any]] { configOptions = options.compactMap(Self.option) }
        if let models = response["models"] as? [String: Any] {
            self.models = (models["availableModels"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["modelId"] as? String, !id.isEmpty else { return nil }
                return Choice(id: id, name: ($0["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                              description: $0["description"] as? String)
            }
            currentModel = models["currentModelId"] as? String ?? currentModel
        }
        if let modes = response["modes"] as? [String: Any] {
            self.modes = (modes["availableModes"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? String, !id.isEmpty else { return nil }
                return Choice(id: id, name: $0["name"] as? String ?? id, description: $0["description"] as? String)
            }
            currentMode = modes["currentModeId"] as? String ?? currentMode
        }
    }

    private static func option(_ row: [String: Any]) -> Option? {
        guard let id = row["id"] as? String, row["type"] as? String ?? "select" == "select" else { return nil }
        var choices: [Choice] = []
        for entry in row["options"] as? [[String: Any]] ?? [] {
            if let value = entry["value"] as? String {
                choices.append(Choice(id: value, name: entry["name"] as? String ?? value, description: entry["description"] as? String))
            } else if let group = entry["options"] as? [[String: Any]] {
                // A grouped select lists its choices under each group.
                for nested in group {
                    guard let value = nested["value"] as? String else { continue }
                    choices.append(Choice(id: value, name: nested["name"] as? String ?? value, description: nested["description"] as? String))
                }
            }
        }
        return Option(id: id, category: row["category"] as? String, current: row["currentValue"] as? String, choices: choices)
    }

    func option(_ category: String) -> Option? {
        configOptions.first { $0.category == category } ?? configOptions.first { $0.id == category }
    }

    /// The models to offer, as the option or the model list has them.
    var modelChoices: [Choice] { option("model")?.choices ?? models }
    var model: String? { option("model")?.current ?? currentModel }
    var modeChoices: [Choice] { option("mode")?.choices ?? modes }
    var mode: String? { option("mode")?.current ?? currentMode }
    var effortChoices: [Choice] { option("thought_level")?.choices ?? [] }

    /// The agent's plan mode, when it has one.
    var planMode: String? {
        modeChoices.first { $0.id.lowercased() == "plan" }?.id
            ?? modeChoices.first { $0.id.lowercased().contains("plan") || $0.name.lowercased().contains("plan") }?.id
    }

    /// The mode that approves every tool itself, such as Gemini's `yolo`.
    var fullAccessMode: String? {
        let names = ["yolo", "bypasspermissions", "full-access", "fullaccess", "full_access", "autopilot", "dangerously"]
        return modeChoices.first { choice in names.contains { choice.id.lowercased().contains($0) || choice.name.lowercased().contains($0) } }?.id
    }

    /// The descriptors the model menu lists, each with the reasoning levels the agent offers.
    /// The reasoning option lists only the current model's levels; where the model list also
    /// names each family's variants, such as Antigravity's `gemini-4-neon-xhigh`, those say
    /// which levels each family has.
    func descriptors() -> [AgentModelDescriptor] {
        let levels: [AgentReasoningEffort] = [.init(rawValue: "minimal"), .low, .medium, .high, .xhigh, .max]
        let efforts = effortChoices.map(\.id).filter { $0 != "default" && $0 != "auto" }
            .map(AgentReasoningEffort.init(rawValue:)).filter { (try? $0.validate()) != nil }
        let defaultEffort = option("thought_level")?.current.flatMap { $0 == "default" ? nil : AgentReasoningEffort(rawValue: $0) }
        let variants = option("model") == nil ? [] : models.map(\.id)
        var seen = Set<String>()
        return modelChoices.compactMap { choice in
            guard seen.insert(choice.id).inserted else { return nil }
            let named = levels.filter { variants.contains(choice.id + "-" + $0.rawValue) }
            let efforts = named.isEmpty ? efforts : named
            let descriptor = AgentModelDescriptor(id: choice.id, title: choice.name, reasoningEfforts: efforts,
                                                  defaultReasoningEffort: defaultEffort, isDefault: choice.id == model)
            return (try? AgentModelCatalogReply(models: [descriptor]).validate()) == nil ? nil : descriptor
        }
    }
}

/// A conversation with an agent that speaks the Agent Client Protocol, such as Gemini CLI.
/// All protocol state is confined to `queue`; process readers never call client code directly.
internal final class AcpAgentRuntime: AgentSessionRuntime, @unchecked Sendable {
    private let queue = DispatchQueue(label: "tab.acp-runtime")
    private let provider: AgentChatProvider
    private let directory: String
    private var resumeSession: String?
    private let onEvent: @Sendable (AgentRuntimeEvent) -> Void
    private let launchOverride: AgentProcess.Launch?
    private let requestTimeout: TimeInterval
    private var launch = AgentLaunch()
    private var process: AgentProcess?
    private var processGeneration = UUID()
    /// The process's own temporary folder, for agents that unpack into it.
    private var scratch: URL?
    private var closed = false
    private var failed = false
    private var sequence = 0
    private var pending: [String: (Result<Any, Error>) -> Void] = [:]

    private var initialized: [String: Any]?
    private var sessionID: String?
    private var options = AcpSessionOptions()
    /// The selection the session started with, which an empty choice returns to.
    private var initialModel: String?
    private var initialEffort: String?
    private var initialMode: String?
    /// The first prompt of a new session carries Tab's instructions.
    private var sentInstructions = false
    private var starting: [(Result<Void, Error>) -> Void]?

    private var busy = false
    private var interruptRequested = false
    private var planMode = false
    private var accessMode: AgentAccessMode = .standard
    private var noticedModel = false
    private lazy var updates = AcpSessionUpdates(onEvent: onEvent)

    private struct Permission {
        var wireID: Any
        var toolKind: String?
        var row: AgentChatItem
        var request: AgentApprovalRequest
    }
    private var permissions: [String: Permission] = [:]
    private var settledRequests: Set<String> = []

    private var name: String { (launch.provider ?? .builtIn(provider)).title }

    init(provider: AgentChatProvider, directory: String, resumeSession: String?,
         onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) {
        self.provider = provider
        self.directory = directory
        self.resumeSession = resumeSession
        self.onEvent = onEvent
        launchOverride = nil
        requestTimeout = 60
    }

    /// Test seam: a local fake agent, never a real provider or account.
    init(provider: AgentChatProvider, directory: String, resumeSession: String?, launch: AgentProcess.Launch,
         requestTimeout: TimeInterval = 30, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) {
        self.provider = provider
        self.directory = directory
        self.resumeSession = resumeSession
        self.onEvent = onEvent
        launchOverride = launch
        self.requestTimeout = requestTimeout
    }

    func prepare(_ launch: AgentLaunch) {
        queue.sync { self.launch = launch }
    }

    // MARK: Sending

    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        try await send(text: text, model: model, reasoningEffort: reasoningEffort, attachments: [])
    }

    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?,
              attachments: [StagedAgentAttachment]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed, !self.failed else {
                    continuation.resume(throwing: AgentRuntimeError("Agent is closed or failed; open a new agent pane to resume."))
                    return
                }
                guard !self.busy else {
                    continuation.resume(throwing: AgentRuntimeError("Wait for the current turn or interrupt it first."))
                    return
                }
                self.busy = true
                self.interruptRequested = false
                self.onEvent(.status(.working))
                self.ensureSession { result in
                    do {
                        try result.get()
                        self.select(model: model, effort: reasoningEffort) { result in
                            do {
                                try result.get()
                                try self.prompt(text: text, attachments: attachments)
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
    }

    private func prompt(text: String, attachments: [StagedAgentAttachment]) throws {
        guard let sessionID else { throw AgentRuntimeError("\(name) has no session.") }
        let capabilities = (initialized?["agentCapabilities"] as? [String: Any])?["promptCapabilities"] as? [String: Any]
        let images = capabilities?["image"] as? Bool == true
        let embedded = capabilities?["embeddedContext"] as? Bool == true
        var content: [[String: Any]] = []
        var paths: [StagedAgentAttachment] = []
        for staged in attachments {
            let mime = staged.attachment.mimeType.lowercased()
            if images, AgentAttachments.imageTypes.contains(mime) {
                content.append(["type": "image", "mimeType": mime, "data": staged.attachment.data.base64EncodedString()])
            } else if embedded, mime.hasPrefix("text/") || mime == "application/json",
                      let text = String(data: staged.attachment.data, encoding: .utf8) {
                content.append(["type": "resource", "resource": ["uri": staged.url.absoluteString, "mimeType": mime, "text": text]])
            } else {
                // Files the agent can't take as content go as paths it reads itself.
                paths.append(staged)
            }
        }
        var blocks: [[String: Any]] = []
        // ACP has no system prompt, so a new session's first prompt carries Tab's instructions.
        if !sentInstructions, resumeSession == nil, let instructions = launch.instructions {
            blocks.append(["type": "text", "text": "<system-reminder>\n\(instructions)\n</system-reminder>"])
        }
        sentInstructions = true
        blocks.append(["type": "text", "text": AgentAttachments.prompt(text: text, attachments: paths)])
        blocks += content
        updates.beginTurn()
        try request("session/prompt", params: ["sessionId": sessionID, "prompt": blocks], timeout: nil) { [weak self] result in
            self?.finishTurn(result)
        }
    }

    private func finishTurn(_ result: Result<Any, Error>) {
        guard busy else { return }
        switch result {
        case .success(let value):
            let response = value as? [String: Any] ?? [:]
            let reason = response["stopReason"] as? String ?? "end_turn"
            let cancelled = reason == "cancelled" || interruptRequested
            updates.endTurn(interrupted: cancelled)
            let usage = response["usage"] as? [String: Any]
            onEvent(.turnUsage(AgentTurnUsage(inputTokens: agentTokenCount(usage?["inputTokens"]),
                                              outputTokens: agentTokenCount(usage?["outputTokens"]),
                                              model: options.model, stopReason: reason)))
            switch reason {
            case "refusal": onEvent(.item(AgentChatItem(kind: .notice, text: "\(name) refused to continue this request.")))
            case "max_tokens": onEvent(.item(AgentChatItem(kind: .notice, text: "\(name) stopped at its output limit.")))
            case "max_turn_requests": onEvent(.item(AgentChatItem(kind: .notice, text: "\(name) stopped after its most model requests in one turn.")))
            default: break
            }
            completeTurn()
        case .failure(let error):
            if interruptRequested {
                updates.endTurn(interrupted: true)
                completeTurn()
            } else {
                updates.endTurn(interrupted: false, failed: true)
                fail(error.localizedDescription)
            }
        }
    }

    private func completeTurn() {
        busy = false
        interruptRequested = false
        cancelPermissions(reason: "The response ended")
        onEvent(.status(.idle))
    }

    /// The protocol has no way to add to a running prompt, so a follow-up waits in the queue.
    func steer(text: String, attachments: [StagedAgentAttachment]) async throws {
        let name = queue.sync { self.name }
        throw AgentRuntimeError("\(name) can't take a message while it works. Queue it, or send it when this response ends.")
    }

    func interrupt() async throws {
        try await perform {
            guard self.busy, let sessionID = self.sessionID else { return }
            self.interruptRequested = true
            // The protocol answers pending permission requests with `cancelled` on cancel.
            self.cancelPermissions(reason: "The response was stopped")
            try self.notify("session/cancel", params: ["sessionId": sessionID])
        }
    }

    func stop() {
        queue.async { self.close() }
    }

    // MARK: Session

    private func ensureSession(_ completion: @escaping (Result<Void, Error>) -> Void) {
        if sessionID != nil { return completion(.success(())) }
        if starting != nil { starting?.append(completion); return }
        starting = [completion]
        let finish: (Result<Void, Error>) -> Void = { result in
            let waiting = self.starting ?? []
            self.starting = nil
            for completion in waiting { completion(result) }
        }
        do {
            try startProcess()
            try request("initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "tab", "title": "Tab", "version": Release.version],
            ]) { result in
                do {
                    let response = try result.get() as? [String: Any] ?? [:]
                    self.initialized = response
                    self.openSession(authenticated: false, completion: finish)
                } catch { finish(.failure(error)) }
            }
        } catch { finish(.failure(error)) }
    }

    private func startProcess() throws {
        var environment = AgentProcess.environment()
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "TAB_SESSION_ID")
        let config = launch.provider ?? .builtIn(provider)
        environment = AgentProviderLaunch.environment(config, base: environment)
        environment.merge(launch.environment) { _, tab in tab }
        if let path = launch.path { environment["PATH"] = [path, environment["PATH"]].compactMap { $0 }.joined(separator: ":") }
        scratch = AgentProviderLaunch.scratchDirectory(config)
        if let scratch { environment["TMPDIR"] = scratch.path }
        let arguments = AgentProviderLaunch.sessionArguments(config)
        let launch = try launchOverride ?? AgentProcess.Launch(
            executable: AgentProviderLaunch.executable(config, environment: environment),
            arguments: arguments, environment: environment)
        let generation = processGeneration
        let scratch = scratch
        process = try AgentProcess(launch: launch, directory: directory, onLine: { [weak self] line in
            self?.queue.async { [weak self] in
                guard let self, self.processGeneration == generation else { return }
                self.receive(line)
            }
        }, onExit: { [weak self] code, stderr in
            AgentProviderLaunch.removeScratch(scratch)
            self?.queue.async { [weak self] in
                guard let self, !self.closed, !self.failed, self.processGeneration == generation else { return }
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                self.fail("\(self.name) exited (\(code)). " + (detail.isEmpty
                    ? "Check that it is installed, signed in and new enough in Settings › Agents." : String(detail.suffix(2000))))
            }
        })
    }

    /// Resumes the conversation's session when the agent can, else starts a new one.
    private func openSession(authenticated: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        let capabilities = initialized?["agentCapabilities"] as? [String: Any] ?? [:]
        let sessionCapabilities = capabilities["sessionCapabilities"] as? [String: Any] ?? [:]
        var params: [String: Any] = ["cwd": directory, "mcpServers": [Any]()]
        let method: String
        // Antigravity resumes without replaying, as the provider source has it do.
        let prefersResume = provider == .antigravity && sessionCapabilities["resume"] != nil
        if let resumeSession {
            params["sessionId"] = resumeSession
            if capabilities["loadSession"] as? Bool == true, !prefersResume {
                method = "session/load"
            } else if sessionCapabilities["resume"] != nil {
                method = "session/resume"
            } else {
                onEvent(.item(AgentChatItem(kind: .notice, text: "\(name) can't resume its earlier session, so this message starts a new one.")))
                params.removeValue(forKey: "sessionId")
                self.resumeSession = nil
                method = "session/new"
            }
        } else {
            method = "session/new"
        }
        if method == "session/new", let instructions = launch.instructions, appendsSystemPrompt {
            params["_meta"] = ["antigravity": ["systemPrompt": ["append": instructions]]]
            sentInstructions = true
        }
        do {
            try request(method, params: params) { result in
                do {
                    let response = try result.get() as? [String: Any] ?? [:]
                    let id = response["sessionId"] as? String ?? self.resumeSession
                    guard let id, !id.isEmpty else { throw AgentRuntimeError("\(self.name) did not return a session ID.") }
                    self.sessionID = id
                    self.options = AcpSessionOptions(response)
                    self.initialModel = self.options.model
                    self.initialEffort = self.options.option("thought_level")?.current
                    self.initialMode = self.options.mode.flatMap { $0 == self.options.planMode || $0 == self.options.fullAccessMode ? nil : $0 }
                        ?? self.options.modeChoices.first { $0.id != self.options.planMode && $0.id != self.options.fullAccessMode }?.id
                    self.onEvent(.providerSession(id))
                    if let model = self.options.model { self.onEvent(.resolvedModel(model)) }
                    completion(.success(()))
                } catch {
                    if !authenticated, let method = self.headlessAuthMethod(error) {
                        self.authenticate(method) { result in
                            if case .failure(let error) = result { return completion(.failure(error)) }
                            self.openSession(authenticated: true, completion: completion)
                        }
                        return
                    }
                    completion(.failure(self.explain(error)))
                }
            }
        } catch { completion(.failure(error)) }
    }

    /// Whether the agent takes Tab's instructions as an addition to its system prompt, as
    /// Antigravity does, rather than in the first prompt.
    private var appendsSystemPrompt: Bool {
        let meta = (initialized?["agentCapabilities"] as? [String: Any])?["_meta"] as? [String: Any]
        let systemPrompt = (meta?["antigravity"] as? [String: Any])?["systemPrompt"] as? [String: Any]
        return systemPrompt?["append"] as? Bool == true
    }

    /// An auth method that needs no browser or terminal. `nil` leaves the agent signed out.
    private func headlessAuthMethod(_ error: Error) -> String? {
        guard (error as? AcpError)?.isAuthRequired == true else { return nil }
        let config = launch.provider ?? .builtIn(provider)
        let environment = AgentProviderLaunch.environment(config, base: ProcessInfo.processInfo.environment)
        let hasKey = provider.spec.apiKeyVariables.contains { environment[$0]?.isEmpty == false }
        return AcpAuthentication.method(initialized?["authMethods"] as? [[String: Any]] ?? [], provider: provider, hasKey: hasKey)
    }

    private func authenticate(_ method: String, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try request("authenticate", params: ["methodId": method], timeout: 30) { result in
                // Any failure here is a sign-in the agent couldn't make by itself.
                completion(result.map { _ in () }.mapError { self.explain(AcpError(code: -32000, message: $0.localizedDescription)) })
            }
        } catch { completion(.failure(error)) }
    }

    /// An auth failure says how to sign in; others say what the agent said.
    private func explain(_ error: Error) -> Error {
        guard (error as? AcpError)?.isAuthRequired == true else { return error }
        let config = launch.provider ?? .builtIn(provider)
        return AgentRuntimeError("\(name) isn't signed in. \(AgentProviderStore.signInMessage(config)) (\(error.localizedDescription))")
    }

    // MARK: Model, effort and mode

    /// Sets the model, reasoning level and mode the next prompt runs with, one request at a time.
    private func select(model: String?, effort: AgentReasoningEffort?, completion: @escaping (Result<Void, Error>) -> Void) {
        var steps: [(@escaping (Result<Void, Error>) -> Void) throws -> Void] = []
        let targetModel = model ?? initialModel
        if let targetModel, targetModel != options.model {
            if let option = options.option("model") {
                steps.append { done in try self.setOption(option.id, value: targetModel, done) }
            } else if !options.models.isEmpty, let sessionID {
                steps.append { done in
                    try self.request("session/set_model", params: ["sessionId": sessionID, "modelId": targetModel]) { result in
                        if case .success = result { self.options.currentModel = targetModel }
                        done(result.map { _ in () })
                    }
                }
            } else if model != nil, !noticedModel {
                noticedModel = true
                onEvent(.item(AgentChatItem(kind: .notice, text: "\(name) doesn't let Tab choose its model, so it uses the one it is set up with.")))
            }
        }
        if let option = options.option("thought_level") {
            let target = effort?.rawValue ?? initialEffort
            if let target, target != option.current, option.choices.contains(where: { $0.id == target }) {
                steps.append { done in try self.setOption(option.id, value: target, done) }
            }
        }
        let mode: String?
        if planMode {
            guard let plan = options.planMode else {
                return completion(.failure(AgentRuntimeError("\(name) has no plan mode. Turn Plan off to send.")))
            }
            mode = plan
        } else if accessMode == .fullAccess, let full = options.fullAccessMode {
            mode = full
        } else {
            mode = initialMode
        }
        if let mode, mode != options.mode {
            if let option = options.option("mode") {
                steps.append { done in try self.setOption(option.id, value: mode, done) }
            } else if !options.modes.isEmpty, let sessionID {
                steps.append { done in
                    try self.request("session/set_mode", params: ["sessionId": sessionID, "modeId": mode]) { result in
                        if case .success = result { self.options.currentMode = mode }
                        done(result.map { _ in () })
                    }
                }
            }
        }
        func next(_ index: Int) {
            guard index < steps.count else {
                if let model = options.model { onEvent(.resolvedModel(model)) }
                return completion(.success(()))
            }
            do {
                let step = steps[index]
                try step { result in
                    if case .failure(let error) = result { return completion(.failure(error)) }
                    next(index + 1)
                }
            } catch { completion(.failure(error)) }
        }
        next(0)
    }

    private func setOption(_ id: String, value: String, _ done: @escaping (Result<Void, Error>) -> Void) throws {
        guard let sessionID else { throw AgentRuntimeError("\(name) has no session.") }
        try request("session/set_config_option", params: ["sessionId": sessionID, "configId": id, "value": value]) { result in
            switch result {
            case .success(let response):
                if let response = response as? [String: Any], response["configOptions"] != nil {
                    self.options.update(response)
                } else if let index = self.options.configOptions.firstIndex(where: { $0.id == id }) {
                    self.options.configOptions[index].current = value
                }
                done(.success(()))
            case .failure(let error):
                done(.failure(error))
            }
        }
    }

    func setPlan(_ enabled: Bool) async throws {
        try await perform { self.planMode = enabled }
    }

    func setAccess(_ mode: AgentAccessMode) async throws {
        try await perform {
            self.accessMode = mode
            for id in self.permissions.keys.sorted() {
                guard let permission = self.permissions[id], self.allowsAutomatically(permission.toolKind),
                      let choice = permission.request.first(.allowOnce) ?? permission.request.first(.allowForSession) else { continue }
                try self.resolve(id, decision: choice.id, automatic: true)
            }
        }
    }

    // MARK: Permissions

    private func allowsAutomatically(_ toolKind: String?) -> Bool {
        switch accessMode {
        case .fullAccess: true
        case .ask: false
        case .standard: ["read", "search", "fetch", "think"].contains(toolKind ?? "")
        }
    }

    private func presentPermission(wireID: Any, params: [String: Any]) throws {
        let key = "acp-permission:" + agentRuntimeID(wireID)
        let tool = params["toolCall"] as? [String: Any] ?? [:]
        let title = (tool["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Tool approval"
        let toolKind = tool["kind"] as? String
        var requested: [AgentApprovalRequest.Field] = [.init(label: "Tool", value: title)]
        if let raw = tool["rawInput"] as? [String: Any] {
            if let command = raw["command"] as? String { requested.append(.init(label: "Command", value: command)) }
            if let path = (raw["path"] ?? raw["file_path"] ?? raw["filePath"]) as? String { requested.append(.init(label: "Path", value: path)) }
            if let url = raw["url"] as? String { requested.append(.init(label: "URL", value: url)) }
        }
        for location in (tool["locations"] as? [[String: Any]] ?? []).prefix(8) {
            if let path = location["path"] as? String, !requested.contains(where: { $0.value == path }) {
                requested.append(.init(label: "Path", value: path))
            }
        }
        var decisions: [AgentApprovalDecision] = []
        for option in params["options"] as? [[String: Any]] ?? [] {
            guard let id = option["optionId"] as? String, !id.isEmpty, decisions.count < 16,
                  !decisions.contains(where: { $0.id == id }) else { continue }
            let label = (option["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            switch option["kind"] as? String {
            case "allow_once":
                decisions.append(.init(id: id, kind: .allowOnce, title: label ?? "Allow once", consequence: "\(name) runs this tool this time."))
            case "allow_always":
                decisions.append(.init(id: id, kind: .allowForSession, title: label ?? "Always allow",
                                       consequence: "\(name) runs matching tools without asking again."))
            case "reject_once":
                decisions.append(.init(id: id, kind: .decline, title: label ?? "Decline", consequence: "\(name) skips this tool and carries on."))
            case "reject_always":
                decisions.append(.init(id: id, kind: .decline, title: label ?? "Always decline",
                                       consequence: "\(name) skips matching tools without asking again."))
            default:
                continue
            }
        }
        guard !decisions.isEmpty else {
            try write(["jsonrpc": "2.0", "id": wireID, "result": ["outcome": ["outcome": "cancelled"]]])
            onEvent(.item(AgentChatItem(kind: .notice, text: "\(name) asked to run \(title) without offering a choice Tab can send, so it was declined.")))
            return
        }
        let request = AgentApprovalRequest(kind: "tool", summary: title == "Tool approval" ? nil : title, requested: requested,
                                           decisions: decisions,
                                           origin: AgentRequestOrigin(providerRequestID: agentRuntimeID(wireID),
                                                                      numericID: wireID is NSNumber ? true : nil, threadID: sessionID))
        let row = AgentChatItem(id: key, kind: .approval, text: title, detail: agentRuntimeJSON(tool["rawInput"]), isComplete: false,
                                workContext: .init(providerTurnID: updates.turnID, requestKind: toolKind == "execute" ? "command"
                                                   : ["edit", "delete", "move"].contains(toolKind ?? "") ? "file-change" : "tool"),
                                approval: request)
        permissions[key] = Permission(wireID: wireID, toolKind: toolKind, row: row, request: request)
        if allowsAutomatically(toolKind), let choice = request.first(.allowOnce) ?? request.first(.allowForSession) {
            try resolve(key, decision: choice.id, automatic: true)
            return
        }
        onEvent(.item(row))
        onEvent(.status(.waiting))
    }

    func approve(request: String, allow: Bool) async throws {
        try await approve(request: request, allow: allow, always: false, reason: nil)
    }

    func approve(request id: String, allow: Bool, always: Bool, reason: String?) async throws {
        try await perform {
            if self.settledRequests.contains(id), self.permissions[id] == nil { return }
            guard let permission = self.permissions[id] else { throw AgentRuntimeError("Approval is no longer pending.") }
            guard reason == nil else { throw AgentRuntimeError("\(self.name) can't take a reason with a denial.") }
            let request = permission.request
            let choice = allow ? (always ? request.first(.allowForSession) ?? request.first(.allowAlways) : request.first(.allowOnce))
                : request.first(.decline)
            guard let choice else {
                throw AgentRuntimeError(allow && always ? "This request can only be allowed once." : "\(self.name) didn't offer that choice.")
            }
            try self.resolve(id, decision: choice.id)
        }
    }

    func decide(request id: String, decision: String, answers: [String: [String]]?) async throws {
        try await perform {
            if self.settledRequests.contains(id), self.permissions[id] == nil { return }
            guard self.permissions[id]?.request.decision(decision) != nil else {
                throw AgentRuntimeError(self.permissions[id] == nil ? "This request is no longer pending." : "That option isn't offered for this request.")
            }
            try self.resolve(id, decision: decision)
        }
    }

    func setAlwaysAllowed(_ tools: Set<String>) async throws {}

    private func resolve(_ id: String, decision: String, automatic: Bool = false) throws {
        guard let permission = permissions.removeValue(forKey: id), let choice = permission.request.decision(decision) else {
            throw AgentRuntimeError("That option isn't offered for this request.")
        }
        try write(["jsonrpc": "2.0", "id": permission.wireID, "result": ["outcome": ["outcome": "selected", "optionId": decision]]])
        let text = automatic ? "Automatically approved" : AgentProviderRequests.outcomeText(choice.kind, title: choice.title)
        settle(permission, text: text, outcome: .init(decision: choice.id, kind: choice.kind, title: choice.title,
                                                       source: automatic ? .automatic : .user))
        onEvent(.status(permissions.isEmpty ? (busy ? .working : .idle) : .waiting))
    }

    /// Answers every pending request `cancelled`, as the protocol asks when a turn ends or stops.
    private func cancelPermissions(reason: String) {
        for id in permissions.keys.sorted() {
            guard let permission = permissions.removeValue(forKey: id) else { continue }
            try? write(["jsonrpc": "2.0", "id": permission.wireID, "result": ["outcome": ["outcome": "cancelled"]]])
            settle(permission, text: "No longer pending", outcome: .init(title: reason, source: .expired))
        }
    }

    private func settle(_ permission: Permission, text: String, outcome: AgentApprovalRequest.Outcome) {
        var row = permission.row
        row.text = text
        row.isComplete = true
        row.approval?.outcome = outcome
        if settledRequests.count > 512 { settledRequests.removeAll() }
        settledRequests.insert(row.id)
        onEvent(.item(row))
    }

    // MARK: Protocol

    private func receive(_ data: Data) {
        guard !closed, !failed else { return }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Some agents log to stdout before they start; only JSON is protocol. A sign-in link
            // means the agent wants a browser sign-in, which belongs in its own terminal.
            if AcpAuthentication.asksForBrowser(data) {
                let config = launch.provider ?? .builtIn(provider)
                fail("\(name) isn't signed in. \(AgentProviderStore.signInMessage(config))")
            }
            return
        }
        let method = message["method"] as? String
        if method == nil, let wireID = message["id"] {
            guard let completion = pending.removeValue(forKey: agentRuntimeID(wireID)) else { return }
            if let error = message["error"] as? [String: Any] {
                completion(.failure(AcpError(error)))
            } else {
                completion(.success(message["result"] ?? NSNull()))
            }
            return
        }
        guard let method else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if let wireID = message["id"] {
            do {
                switch method {
                case "session/request_permission":
                    try presentPermission(wireID: wireID, params: params)
                default:
                    try write(["jsonrpc": "2.0", "id": wireID, "error": ["code": -32601, "message": "Tab does not support \(method)."]])
                }
            } catch { fail("Couldn't answer \(name): \(error.localizedDescription)") }
            return
        }
        guard method == "session/update", let update = params["update"] as? [String: Any] else { return }
        if let id = params["sessionId"] as? String, let sessionID, id != sessionID { return }
        // A session being loaded replays its history, which the transcript already holds.
        guard sessionID != nil else { return }
        switch update["sessionUpdate"] as? String {
        case "available_commands_update", "usage_update":
            updates.receive(update)
        case "current_mode_update":
            options.currentMode = update["currentModeId"] as? String ?? options.currentMode
            agentChangedMode()
        case "config_option_update":
            let before = options.model
            options.update(["configOptions": update["configOptions"] ?? []])
            if let model = options.model, model != before { onEvent(.resolvedModel(model)) }
            agentChangedMode()
        default:
            guard busy else { return }
            updates.receive(update)
        }
    }

    /// The agent left plan mode by itself, as when the user approves its plan.
    private func agentChangedMode() {
        guard let plan = options.planMode, let mode = options.mode else { return }
        let inPlan = mode == plan
        guard inPlan != planMode else { return }
        planMode = inPlan
        onEvent(.planMode(inPlan))
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

    private func notify(_ method: String, params: [String: Any]) throws {
        try write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Sends a request; `timeout` nil waits as long as it takes, as a prompt does.
    private func request(_ method: String, params: [String: Any], timeout: TimeInterval? = 0,
                         completion: @escaping (Result<Any, Error>) -> Void) throws {
        sequence += 1
        let id = String(sequence)
        try write(["jsonrpc": "2.0", "id": sequence, "method": method, "params": params])
        pending[id] = completion
        guard let wait = timeout.map({ $0 == 0 ? requestTimeout : $0 }) else { return }
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, let completion = self.pending.removeValue(forKey: id) else { return }
            completion(.failure(AgentRuntimeError("\(self.name) timed out responding to \(method). Check that it is signed in and up to date in Settings › Agents.")))
        }
    }

    private func resolvePending(_ error: Error) {
        let completions = Array(pending.values)
        pending.removeAll()
        for completion in completions { completion(.failure(error)) }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        cancelPermissions(reason: "The agent stopped")
        process?.stop()
        resolvePending(AgentRuntimeError("Agent stopped."))
        onEvent(.status(.closed))
    }

    private func fail(_ message: String) {
        guard !failed, !closed else { return }
        cancelPermissions(reason: "The agent stopped")
        failed = true
        busy = false
        process?.stop()
        onEvent(.failure(message))
        onEvent(.status(.failed))
        resolvePending(AgentRuntimeError(message))
    }

    deinit {
        process?.stop()
        AgentProviderLaunch.removeScratch(scratch, after: 5)
    }
}

/// A JSON-RPC error an ACP agent answered with.
struct AcpError: LocalizedError {
    var code: Int
    var message: String

    init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    init(_ error: [String: Any]) {
        code = (error["code"] as? NSNumber)?.intValue ?? 0
        let data = (error["data"] as? [String: Any])?["details"] as? String ?? error["data"] as? String
        message = [error["message"] as? String ?? "The agent reported an error.", data].compactMap { $0 }.joined(separator: ": ")
    }

    /// ACP's `auth_required`, -32000, which Gemini CLI also sends when a session can't sign in.
    var isAuthRequired: Bool { code == -32000 }

    var errorDescription: String? { message }
}

/// How Tab signs an ACP agent in without a browser or a terminal.
enum AcpAuthentication {
    /// An API key method when the provider's variables hold a key; for Antigravity, its Google
    /// sign-in, which reuses the account `agy` keeps in the keychain. Nil leaves it signed out.
    static func method(_ methods: [[String: Any]], provider: AgentChatProvider, hasKey: Bool) -> String? {
        let ids = methods.compactMap { $0["id"] as? String }
        if hasKey, let key = ids.first(where: { $0.lowercased().contains("api-key") || $0.lowercased().contains("api_key") }) {
            return key
        }
        if provider == .antigravity, ids.contains("oauth-personal") { return "oauth-personal" }
        return nil
    }

    /// Whether a line the agent printed asks the user to open a Google sign-in page.
    static func asksForBrowser(_ line: Data) -> Bool {
        let text = String(decoding: line.prefix(4096), as: UTF8.self)
        return text.contains("https://accounts.google.com/") || text.hasPrefix("Open the following link to authenticate")
    }
}
