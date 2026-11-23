import Foundation
import TabCore
import TabProtocol

/// Reads the subscription limits of the agents signed in on this server by asking
/// each CLI the way its own `/usage` does: Claude Code's `get_usage` control request
/// and Codex's `account/rateLimits/read`. Nothing starts a conversation.
actor AgentUsageLimitsService {
    /// The providers whose CLIs report limits.
    static let providers: [AgentChatProvider] = [.claude, .codex]
    /// How long a reading answers requests before the CLIs are asked again.
    static let freshness: TimeInterval = 60

    typealias Probe = @Sendable (AgentChatProvider, AgentProviderConfig) async -> AgentUsageLimits?

    private let configs: @Sendable (AgentChatProvider) -> AgentProviderConfig
    private let probe: Probe
    private let now: @Sendable () -> Date
    private var cached: (Date, AgentUsageLimitsReply)?
    private var pending: Task<AgentUsageLimitsReply, Never>?

    init(providers: @escaping @Sendable (AgentChatProvider) -> AgentProviderConfig,
         now: @escaping @Sendable () -> Date = { Date() },
         probe: Probe? = nil) {
        self.configs = providers
        self.now = now
        self.probe = probe ?? { provider, config in await AgentUsageLimitsProbe.read(provider, config: config) }
    }

    func handle(_ request: AgentUsageLimitsRequest) async -> AgentUsageLimitsReply {
        if !request.forceRefresh, let cached, now().timeIntervalSince(cached.0) < Self.freshness { return cached.1 }
        if let pending { return await pending.value }
        let configs = Self.providers.map { ($0, self.configs($0)) }.filter { $0.1.enabled }
        let probe = probe
        let task = Task.detached { () -> AgentUsageLimitsReply in
            await withTaskGroup(of: (Int, AgentUsageLimits?).self) { group in
                for (index, (provider, config)) in configs.enumerated() {
                    group.addTask { (index, await probe(provider, config)) }
                }
                var results: [(Int, AgentUsageLimits)] = []
                for await (index, limits) in group {
                    if let limits { results.append((index, limits)) }
                }
                return AgentUsageLimitsReply(providers: results.sorted { $0.0 < $1.0 }.map(\.1))
            }
        }
        pending = task
        let reply = await task.value
        pending = nil
        cached = (now(), reply)
        return reply
    }

    // MARK: Parsing

    private static let sessionMinutes = 5 * 60
    private static let weekMinutes = 7 * 24 * 60
    private static let monthMinutes = 30 * 24 * 60

    /// Claude Code's `get_usage` reply: percentages are 0–100 and resets ISO 8601.
    static func claudeLimits(_ response: [String: Any], checkedAt: Date) -> AgentUsageLimits {
        guard response["rate_limits_available"] as? Bool == true,
              let limits = response["rate_limits"] as? [String: Any] else {
            return AgentUsageLimits(provider: .claude, failure: response["rate_limits_available"] as? Bool == false
                ? "Claude Code has no subscription limits. Sign in with a Claude plan using `claude /login`."
                : "Claude Code did not report its limits.", checkedAt: checkedAt)
        }
        var windows: [AgentUsageWindow] = []
        for (id, kind, label, minutes) in [("five_hour", AgentUsageWindow.Kind.session, "Session", sessionMinutes),
                                           ("seven_day", .weekly, "Weekly", weekMinutes)] {
            guard let window = limits[id] as? [String: Any], let used = number(window["utilization"]) else { continue }
            windows.append(.init(id: id, kind: kind, label: label, usedPercent: used, windowDurationMinutes: minutes,
                                 resetsAt: isoDate(window["resets_at"])))
        }
        for scoped in limits["model_scoped"] as? [[String: Any]] ?? [] {
            guard let name = scoped["display_name"] as? String, !name.isEmpty,
                  let used = number(scoped["utilization"]) else { continue }
            let token = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
            let id = "seven_day_" + token
            guard !windows.contains(where: { $0.id == id }) else { continue }
            windows.append(.init(id: id, kind: .weekly, label: "Weekly · \(name)", usedPercent: used,
                                 windowDurationMinutes: weekMinutes, resetsAt: isoDate(scoped["resets_at"])))
        }
        if let spend = spendPercent(limits) {
            windows.append(.init(id: "monthly_spend", kind: .monthly, label: "Monthly spend", usedPercent: spend))
        }
        return AgentUsageLimits(provider: .claude, windows: Array(windows.prefix(AgentUsageLimitsReply.maxWindows)),
                                checkedAt: checkedAt)
    }

    private static func spendPercent(_ limits: [String: Any]) -> Double? {
        if let spend = limits["spend"] as? [String: Any], spend["enabled"] as? Bool == true,
           let used = spend["used"] as? [String: Any], let limit = spend["limit"] as? [String: Any],
           used["currency"] as? String == limit["currency"] as? String,
           number(used["exponent"]) == number(limit["exponent"]),
           let usedAmount = number(used["amount_minor"]), let limitAmount = number(limit["amount_minor"]), limitAmount > 0 {
            return usedAmount / limitAmount * 100
        }
        guard let extra = limits["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true else { return nil }
        if let used = number(extra["used_credits"]), let limit = number(extra["monthly_limit"]), limit > 0 {
            return used / limit * 100
        }
        return number(extra["utilization"])
    }

    /// Codex's `account/rateLimits/read` result: `primary` and `secondary` are positions,
    /// with resets in epoch seconds. Model-specific buckets stay out of the main rows.
    static func codexLimits(_ result: [String: Any], checkedAt: Date) -> AgentUsageLimits {
        let snapshot = ((result["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any])
            ?? (result["rateLimits"] as? [String: Any]) ?? [:]
        let plan = snapshot["planType"] as? String
        let monthlyPlan = plan == "free" || plan == "go"
        var windows: [AgentUsageWindow] = []
        for (id, fallback) in [("primary", monthlyPlan ? monthMinutes : sessionMinutes), ("secondary", weekMinutes)] {
            guard let window = snapshot[id] as? [String: Any], let used = number(window["usedPercent"]) else { continue }
            let minutes = number(window["windowDurationMins"]).map { Int($0) }.flatMap { $0 > 0 ? $0 : nil } ?? fallback
            let kind: AgentUsageWindow.Kind = minutes >= monthMinutes ? .monthly : minutes >= weekMinutes ? .weekly : .session
            let label = kind == .session ? "Session" : kind == .weekly ? "Weekly" : "Monthly"
            windows.append(.init(id: id, kind: kind, label: label, usedPercent: used, windowDurationMinutes: minutes,
                                 resetsAt: epochDate(window["resetsAt"])))
        }
        if let individual = snapshot["individualLimit"] as? [String: Any], let remaining = number(individual["remainingPercent"]) {
            windows.append(.init(id: "individual", kind: .monthly, label: "Monthly credit limit", usedPercent: 100 - remaining,
                                 resetsAt: epochDate(individual["resetsAt"])))
        }
        guard !windows.isEmpty else {
            return AgentUsageLimits(provider: .codex, failure: "Codex did not report its limits.", checkedAt: checkedAt)
        }
        return AgentUsageLimits(provider: .codex, windows: windows, checkedAt: checkedAt)
    }

    /// A short reason for a failed Codex read, with sign-in problems said plainly.
    static func codexFailure(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("token_expired")
            || lower.contains("not logged in") || lower.contains("requires openai auth") || lower.contains("authentication") {
            return "Codex CLI is not authenticated. Run `codex login` and try again."
        }
        return "Codex could not read usage: \(String(message.prefix(300)))"
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !(value is Bool) else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func epochDate(_ value: Any?) -> Date? {
        guard let seconds = number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// One bounded, short-lived CLI that answers a single limits request. All mutable
/// state lives on its queue.
private final class AgentUsageLimitsProbe: @unchecked Sendable {
    static let timeout: TimeInterval = 20
    private static let maxBytes = 4 * 1024 * 1024

    private let queue = DispatchQueue(label: "tab.agent-usage-limits")
    private let provider: AgentChatProvider
    private var process: AgentProcess?
    private var continuation: CheckedContinuation<AgentUsageLimits?, Never>?
    private var bytes = 0

    private init(provider: AgentChatProvider) {
        self.provider = provider
    }

    /// Nil when the CLI isn't installed, so the provider is left out.
    static func read(_ provider: AgentChatProvider, config: AgentProviderConfig) async -> AgentUsageLimits? {
        var environment = AgentProviderLaunch.environment(config, base: AgentProcess.environment())
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "TAB_SESSION_ID")
        guard let executable = try? AgentProviderLaunch.executable(config, environment: environment) else { return nil }
        let arguments = provider == .codex ? ["app-server"]
            : ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
               "--no-session-persistence", "--safe-mode", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
               "--tools", ""]
        let launch = AgentProcess.Launch(executable: executable, arguments: arguments, environment: environment)
        let probe = AgentUsageLimitsProbe(provider: provider)
        return await withCheckedContinuation { continuation in
            probe.queue.async { probe.start(launch, continuation: continuation) }
        }
    }

    private func start(_ launch: AgentProcess.Launch, continuation: CheckedContinuation<AgentUsageLimits?, Never>) {
        self.continuation = continuation
        queue.asyncAfter(deadline: .now() + Self.timeout) { [self] in
            fail("\(provider.name) did not answer the usage request.")
        }
        do {
            process = try AgentProcess(launch: launch, directory: NSHomeDirectory(), onLine: { [self] data in
                queue.async { self.receive(data) }
            }, onExit: { [self] _, stderr in
                queue.async {
                    let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.fail(self.provider == .codex && !detail.isEmpty ? AgentUsageLimitsService.codexFailure(detail)
                              : "\(self.provider.name) exited before it reported usage.")
                }
            })
            if provider == .codex {
                try process?.write(["id": 1, "method": "initialize", "params": [
                    "clientInfo": ["name": "tab", "version": Release.version]]])
            } else {
                try process?.write(["type": "control_request", "request_id": "usage",
                                    "request": ["subtype": "get_usage"]])
            }
        } catch {
            fail("\(provider.name) could not be started to read usage.")
        }
    }

    private func receive(_ data: Data) {
        guard continuation != nil else { return }
        bytes += data.count
        guard bytes <= Self.maxBytes else { fail("\(provider.name) sent too much while reading usage."); return }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if provider == .claude {
            guard message["type"] as? String == "control_response",
                  let response = message["response"] as? [String: Any],
                  response["request_id"] as? String == "usage" else { return }
            guard response["subtype"] as? String == "success", let body = response["response"] as? [String: Any] else {
                fail("Claude Code could not read usage: \(response["error"] as? String ?? "unknown error")")
                return
            }
            finish(AgentUsageLimitsService.claudeLimits(body, checkedAt: Date()))
            return
        }
        guard let id = message["id"] as? Int else { return }
        if let error = message["error"] as? [String: Any] {
            fail(AgentUsageLimitsService.codexFailure(error["message"] as? String ?? "unknown error"))
            return
        }
        guard let result = message["result"] as? [String: Any] else { return }
        if id == 1 {
            do {
                try process?.write(["method": "initialized"])
                try process?.write(["id": 2, "method": "account/rateLimits/read"])
            } catch { fail("Codex stopped before it reported usage.") }
        } else if id == 2 {
            finish(AgentUsageLimitsService.codexLimits(result, checkedAt: Date()))
        }
    }

    private func fail(_ reason: String) {
        finish(AgentUsageLimits(provider: provider, failure: reason))
    }

    private func finish(_ limits: AgentUsageLimits) {
        guard let continuation else { return }
        self.continuation = nil
        process?.stop()
        process = nil
        continuation.resume(returning: limits)
    }
}
