import Foundation
import TabCore
import TabProtocol

/// Reads the subscription limits of the agents signed in on this server by asking
/// each CLI the way its own `/usage` does: Claude Code's `get_usage` control request,
/// Codex's `account/rateLimits/read`, Antigravity's `/usage`, OpenCode's usage limits
/// and Grok's `x.ai/billing`. Nothing starts a conversation.
actor AgentUsageLimitsService {
    /// The providers whose CLIs report limits.
    static let providers = AgentUsageLimits.reportingKinds
    /// How long a reading answers requests before the CLIs are asked again.
    static let freshness: TimeInterval = 60

    typealias Probe = @Sendable (AgentProviderConfig) async -> AgentUsageLimits?

    private let configs: @Sendable () -> [AgentProviderConfig]
    private let probe: Probe
    private let now: @Sendable () -> Date
    private var cached: (Date, AgentUsageLimitsReply)?
    private var pending: Task<AgentUsageLimitsReply, Never>?
    /// Each account's last successful reading, shown again when a later read times out.
    private var lastRead: [String: AgentUsageLimits] = [:]

    init(providers: @escaping @Sendable () -> [AgentProviderConfig],
         now: @escaping @Sendable () -> Date = { Date() },
         probe: Probe? = nil) {
        self.configs = providers
        self.now = now
        self.probe = probe ?? { config in await AgentUsageLimitsProbe.read(config) }
    }

    /// Forgets the cached reading, as after configured providers change.
    func invalidate() {
        cached = nil
        lastRead = [:]
    }

    func handle(_ request: AgentUsageLimitsRequest) async -> AgentUsageLimitsReply {
        if !request.forceRefresh, let cached, now().timeIntervalSince(cached.0) < Self.freshness { return cached.1 }
        if let pending { return await pending.value }
        let accounts = Self.accounts(configs())
        guard !accounts.isEmpty else {
            let reply = AgentUsageLimitsReply(providers: [])
            cached = (now(), reply)
            return reply
        }
        let probe = probe
        let task = Task.detached { () -> AgentUsageLimitsReply in
            await withTaskGroup(of: (Int, AgentUsageLimits?).self) { group in
                for (index, config) in accounts.enumerated() {
                    group.addTask {
                        guard var limits = await probe(config) else { return (index, nil) }
                        limits.providerId = config.id
                        limits.providerName = config.name.flatMap { $0.isEmpty ? nil : $0 }
                        return (index, limits)
                    }
                }
                var results: [(Int, AgentUsageLimits)] = []
                for await (index, limits) in group {
                    if let limits { results.append((index, limits)) }
                }
                return AgentUsageLimitsReply(providers: results.sorted { $0.0 < $1.0 }.map(\.1))
            }
        }
        pending = task
        let reply = keepingLastRead(await task.value)
        pending = nil
        cached = (now(), reply)
        return reply
    }

    /// A CLI that is only slow to answer keeps its last reading instead of showing an error.
    private func keepingLastRead(_ reply: AgentUsageLimitsReply) -> AgentUsageLimitsReply {
        var reply = reply
        reply.providers = reply.providers.map { limits in
            let key = limits.providerId ?? limits.provider.rawValue
            if limits.failure == nil {
                lastRead[key] = limits
                return limits
            }
            if limits.failure == AgentUsageLimitsProbe.timeoutFailure(limits.provider), let last = lastRead[key] { return last }
            return limits
        }
        return reply
    }

    /// The enabled providers to read, by kind, each signed-in account once: providers
    /// that share a sign-in folder, such as two Antigravity providers, are one account.
    static func accounts(_ configs: [AgentProviderConfig]) -> [AgentProviderConfig] {
        var seen = Set<String>()
        return providers.flatMap { kind in configs.filter { $0.kind == kind && $0.enabled } }.filter { config in
            seen.insert("\(config.kind.rawValue)\n\(AgentProviderLaunch.effectiveHome(config) ?? "")").inserted
        }
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
        return AgentUsageLimits(provider: .claude, plan: planName(response["subscription_type"]),
                                windows: Array(windows.prefix(AgentUsageLimitsReply.maxWindows)), checkedAt: checkedAt)
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
        return AgentUsageLimits(provider: .codex, plan: planName(plan), windows: windows, checkedAt: checkedAt)
    }

    /// `agy -p /usage --output-format json`: each model group has a five-hour and a weekly
    /// bucket, with the remaining share as a 0–1 fraction and resets in ISO 8601.
    static func antigravityLimits(_ output: [String: Any], checkedAt: Date) -> AgentUsageLimits {
        let data = (output["command"] as? [String: Any])?["data"] as? [String: Any]
        var windows: [AgentUsageWindow] = []
        for group in data?["groups"] as? [[String: Any]] ?? [] {
            let name = (group["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var buckets: [AgentUsageWindow] = []
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let id = bucket["id"] as? String, !id.isEmpty,
                      let remaining = number(bucket["remaining_fraction"]) else { continue }
                let (kind, minutes): (AgentUsageWindow.Kind, Int?) = switch bucket["window"] as? String {
                case "5h": (.session, sessionMinutes)
                case "weekly": (.weekly, weekMinutes)
                case "monthly": (.monthly, monthMinutes)
                default: (.unknown, nil)
                }
                let label = switch kind {
                case .session: "Session"
                case .weekly: "Weekly"
                case .monthly: "Monthly"
                case .unknown: bucket["name"] as? String ?? id
                }
                buckets.append(.init(id: id, kind: kind, label: name.map { "\(label) · \($0)" } ?? label,
                                     usedPercent: (1 - remaining) * 100, windowDurationMinutes: minutes,
                                     resetsAt: isoDate(bucket["reset_time"])))
            }
            windows += buckets.sorted { order($0.kind) < order($1.kind) }
        }
        guard !windows.isEmpty else {
            return AgentUsageLimits(provider: .antigravity, failure: "Antigravity did not report its limits.", checkedAt: checkedAt)
        }
        return AgentUsageLimits(provider: .antigravity, windows: Array(windows.prefix(AgentUsageLimitsReply.maxWindows)),
                                checkedAt: checkedAt)
    }

    /// `opencode api experimental.usage.limits`: the OpenCode Go plan's rolling, weekly and
    /// monthly windows as used percentages, and the Console workspace's spend budgets.
    /// Nil when OpenCode isn't signed in to an OpenCode Console workspace, which has no plan.
    static func openCodeLimits(_ output: [String: Any], checkedAt: Date) -> AgentUsageLimits? {
        guard let data = output["data"] as? [String: Any] else { return nil }
        var windows: [AgentUsageWindow] = []
        let go = data["go"] as? [String: Any] ?? [:]
        for (id, kind, label, minutes) in [("rolling", AgentUsageWindow.Kind.session, "Session", Int?.none),
                                           ("weekly", .weekly, "Weekly", weekMinutes),
                                           ("monthly", .monthly, "Monthly", monthMinutes)] {
            guard let window = go[id] as? [String: Any], let used = number(window["percent"]) else { continue }
            windows.append(.init(id: id, kind: kind, label: label, usedPercent: window["limited"] as? Bool == true ? 100 : used,
                                 windowDurationMinutes: minutes, resetsAt: anyDate(window["resetsAt"])))
        }
        for budget in data["budgets"] as? [[String: Any]] ?? [] {
            guard let id = budget["id"] as? String, !id.isEmpty, let limit = number(budget["limit"]), limit > 0,
                  let spent = number(budget["spent"]) else { continue }
            let per = budget["per"] as? String
            let kind: AgentUsageWindow.Kind = per == "month" ? .monthly : per == "week" ? .weekly : .unknown
            windows.append(.init(id: "budget_" + id, kind: kind, label: per.map { "Spend limit · per \($0)" } ?? "Spend limit",
                                 usedPercent: spent / limit * 100, resetsAt: anyDate(budget["resetsAt"])))
        }
        guard !windows.isEmpty else { return nil }
        let workspace = data["workspace"] as? [String: Any]
        return AgentUsageLimits(provider: .openCode, plan: go.isEmpty ? nil : "Go",
                                account: (workspace?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                windows: Array(windows.prefix(AgentUsageLimitsReply.maxWindows)), checkedAt: checkedAt)
    }

    /// Grok's `x.ai/billing` reply: the credits used in the current weekly or monthly
    /// period as a percentage, plus on-demand spend against its cap in cents.
    static func grokLimits(_ result: [String: Any], checkedAt: Date) -> AgentUsageLimits {
        let config = result["config"] as? [String: Any] ?? [:]
        let period = config["currentPeriod"] as? [String: Any]
        var windows: [AgentUsageWindow] = []
        let weekly = (period?["type"] as? String)?.hasSuffix("WEEKLY") == true
        if let used = number(config["creditUsagePercent"]) {
            let start = isoDate(period?["start"]), end = isoDate(period?["end"])
            let minutes = start.flatMap { start in end.map { Int($0.timeIntervalSince(start) / 60) } }.flatMap { $0 > 0 ? $0 : nil }
            windows.append(.init(id: "credits", kind: weekly ? .weekly : .monthly, label: weekly ? "Weekly" : "Monthly",
                                 usedPercent: used, windowDurationMinutes: minutes ?? (weekly ? weekMinutes : monthMinutes),
                                 resetsAt: end))
        } else if let used = cents(config["used"]), let limit = cents(config["monthlyLimit"]), limit > 0 {
            windows.append(.init(id: "credits", kind: .monthly, label: "Monthly", usedPercent: used / limit * 100,
                                 windowDurationMinutes: monthMinutes, resetsAt: isoDate(config["billingPeriodEnd"])))
        }
        if result["on_demand_enabled"] as? Bool != false, let cap = cents(config["onDemandCap"]), cap > 0 {
            windows.append(.init(id: "on_demand", kind: .monthly, label: "On-demand spend",
                                 usedPercent: (cents(config["onDemandUsed"]) ?? 0) / cap * 100))
        }
        guard !windows.isEmpty else {
            return AgentUsageLimits(provider: .grok, failure: "Grok did not report its limits.", checkedAt: checkedAt)
        }
        return AgentUsageLimits(provider: .grok, plan: planName(result["subscription_tier"]), windows: windows,
                                checkedAt: checkedAt)
    }

    /// A plan as people say it: `team` and "Claude Team" read "Team"; "SuperGrok Heavy" stays.
    static func planName(_ value: Any?) -> String? {
        guard var name = (value as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if name.hasPrefix("Claude ") { name.removeFirst("Claude ".count) }
        guard name == name.lowercased() else { return String(name.prefix(64)) }
        return String(name.replacingOccurrences(of: "_", with: " ").capitalized.prefix(64))
    }

    private static func cents(_ value: Any?) -> Double? {
        number((value as? [String: Any])?["val"])
    }

    private static func order(_ kind: AgentUsageWindow.Kind) -> Int {
        switch kind {
        case .session: 0
        case .weekly: 1
        case .monthly: 2
        case .unknown: 3
        }
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
        // `is Bool` also matches the numbers 0 and 1, so ask Core Foundation which it is.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
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

    /// An ISO 8601 string, or epoch seconds or milliseconds.
    private static func anyDate(_ value: Any?) -> Date? {
        if let date = isoDate(value) { return date }
        guard let number = number(value), number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
    }
}

/// One bounded, short-lived CLI that answers a single limits request. All mutable
/// state lives on its queue.
final class AgentUsageLimitsProbe: @unchecked Sendable {
    /// Claude Code can take more than 20 seconds to send a usage reply it already has.
    static let timeout: TimeInterval = 45
    private static let maxBytes = 4 * 1024 * 1024

    private let queue = DispatchQueue(label: "tab.agent-usage-limits")
    private let provider: AgentChatProvider
    private var process: AgentProcess?
    private var continuation: CheckedContinuation<AgentUsageLimits?, Never>?
    private var bytes = 0

    /// How a CLI is asked for its limits.
    private enum Request {
        /// Claude Code's stream-json `get_usage` control request.
        case claudeControl
        /// Codex's `app-server` JSON-RPC `account/rateLimits/read`.
        case codexRPC
        /// An Agent Client Protocol extension method, called after `initialize` without a session.
        case acpExtension(String, parse: @Sendable ([String: Any]) -> AgentUsageLimits)
        /// A command that prints one JSON reply and exits. `parse` returns nil when
        /// the account has no plan limits, so the provider is left out.
        case command([String], parse: @Sendable ([String: Any]) -> AgentUsageLimits?)
    }

    private static func request(_ provider: AgentChatProvider) -> Request? {
        switch provider {
        case .claude: .claudeControl
        case .codex: .codexRPC
        case .antigravity:
            .command(["--print", "/usage", "--output-format", "json"]) { output in
                AgentUsageLimitsService.antigravityLimits(output, checkedAt: Date())
            }
        case .openCode:
            // A private server, so reading limits doesn't leave OpenCode's background service running.
            .command(["--standalone", "api", "experimental.usage.limits"]) { output in
                AgentUsageLimitsService.openCodeLimits(output, checkedAt: Date())
            }
        case .grok:
            .acpExtension("_x.ai/billing") { result in
                AgentUsageLimitsService.grokLimits(result, checkedAt: Date())
            }
        // Gemini CLI and Kiro report their quota only as text in an interactive session.
        case .gemini, .kiro, .acp: nil
        }
    }

    private let request: Request
    private var output = Data()
    /// Who is signed in and on which plan, from Claude Code's `initialize` or Codex's `account/read`.
    private var identity: (account: String?, plan: String?)?
    /// Codex's limits, held until `account/read` answers too.
    private var heldLimits: AgentUsageLimits?

    private init(provider: AgentChatProvider, request: Request) {
        self.provider = provider
        self.request = request
    }

    /// Nil when the CLI reports no plan limits, so the provider is left out. A CLI that
    /// isn't installed reads as a failure, so an added provider doesn't vanish from AI usage
    /// on a computer that lacks it.
    static func read(_ config: AgentProviderConfig) async -> AgentUsageLimits? {
        let provider = config.kind
        guard let request = request(provider) else { return nil }
        var environment = AgentProviderLaunch.environment(config, base: AgentProcess.environment())
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "TAB_SESSION_ID")
        if provider == .codex { try? AgentProviderLaunch.prepareShadowHome(config) }
        guard let executable = try? AgentProviderLaunch.executable(config, environment: environment) else {
            return AgentUsageLimits(provider: provider, failure: "\(provider.name) isn't installed on this computer.")
        }
        let arguments: [String] = switch request {
        case .claudeControl:
            ["--print", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
             "--no-session-persistence", "--safe-mode", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
             "--tools", ""]
        case .codexRPC: ["app-server"] + AgentProviderLaunch.homeArguments(config)
        case .acpExtension: provider.spec.sessionArguments
        case .command(let arguments, _): arguments
        }
        let launch = AgentProcess.Launch(executable: executable, arguments: arguments, environment: environment)
        let probe = AgentUsageLimitsProbe(provider: provider, request: request)
        return await withCheckedContinuation { continuation in
            probe.queue.async { probe.start(launch, continuation: continuation) }
        }
    }

    static func timeoutFailure(_ provider: AgentChatProvider) -> String {
        "\(provider.name) did not answer the usage request."
    }

    private func start(_ launch: AgentProcess.Launch, continuation: CheckedContinuation<AgentUsageLimits?, Never>) {
        self.continuation = continuation
        queue.asyncAfter(deadline: .now() + Self.timeout) { [self] in
            fail(Self.timeoutFailure(provider))
        }
        do {
            process = try AgentProcess(launch: launch, directory: NSHomeDirectory(), onLine: { [self] data in
                queue.async { self.receive(data) }
            }, onExit: { [self] status, stderr in
                queue.async { self.exited(status: status, stderr: stderr) }
            })
            switch request {
            case .claudeControl:
                try process?.write(["type": "control_request", "request_id": "initialize",
                                    "request": ["subtype": "initialize"]])
            case .codexRPC:
                try process?.write(["id": 1, "method": "initialize", "params": [
                    "clientInfo": ["name": "tab", "version": Release.version]]])
            case .acpExtension:
                try process?.write(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                    "protocolVersion": 1, "clientCapabilities": [String: Any](),
                    "clientInfo": ["name": "tab", "title": "Tab", "version": Release.version]]])
            case .command:
                break
            }
        } catch {
            fail("\(provider.name) could not be started to read usage.")
        }
    }

    private func exited(status: Int32, stderr: String) {
        guard continuation != nil else { return }
        if let heldLimits { return finish(heldLimits) }
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        switch request {
        case .codexRPC where !detail.isEmpty:
            fail(AgentUsageLimitsService.codexFailure(detail))
        case .command(_, let parse):
            guard status == 0,
                  let reply = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
                // Antigravity exits 2 for an API key, which has no account quota.
                if provider == .antigravity, status == 2 { return finish(nil) }
                return fail(detail.isEmpty ? "\(provider.name) exited before it reported usage."
                            : "\(provider.name) could not read usage: \(String(detail.prefix(300)))")
            }
            finish(parse(reply))
        default:
            fail("\(provider.name) exited before it reported usage.")
        }
    }

    private func receive(_ data: Data) {
        guard continuation != nil else { return }
        bytes += data.count
        guard bytes <= Self.maxBytes else { fail("\(provider.name) sent too much while reading usage."); return }
        if case .command = request {
            output.append(data)
            output.append(10)
            return
        }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if case .claudeControl = request {
            guard message["type"] as? String == "control_response",
                  let response = message["response"] as? [String: Any] else { return }
            if response["request_id"] as? String == "initialize" {
                let account = (response["response"] as? [String: Any])?["account"] as? [String: Any]
                identity = (account?["email"] as? String, AgentUsageLimitsService.planName(account?["subscriptionType"]))
                do {
                    try process?.write(["type": "control_request", "request_id": "usage", "request": ["subtype": "get_usage"]])
                } catch { fail("Claude Code stopped before it reported usage.") }
                return
            }
            guard response["request_id"] as? String == "usage" else { return }
            guard response["subtype"] as? String == "success", let body = response["response"] as? [String: Any] else {
                fail("Claude Code could not read usage: \(response["error"] as? String ?? "unknown error")")
                return
            }
            finish(AgentUsageLimitsService.claudeLimits(body, checkedAt: Date()))
            return
        }
        guard let id = message["id"] as? Int else { return }
        if case .acpExtension(let method, let parse) = request {
            if let error = message["error"] as? [String: Any] { return acpFailed(error) }
            guard let result = message["result"] as? [String: Any] else { return }
            if id == 1 {
                do { try process?.write(["jsonrpc": "2.0", "id": 2, "method": method, "params": [String: Any]()]) }
                catch { fail("\(provider.name) stopped before it reported usage.") }
            } else if id == 2 {
                finish(parse(result))
            }
            return
        }
        if id == 3 {
            // An older Codex without `account/read` still reports its limits.
            let account = (message["result"] as? [String: Any])?["account"] as? [String: Any]
            identity = (account?["email"] as? String, AgentUsageLimitsService.planName(account?["planType"]))
            if let heldLimits { finish(heldLimits) }
            return
        }
        if let error = message["error"] as? [String: Any] {
            fail(AgentUsageLimitsService.codexFailure(error["message"] as? String ?? "unknown error"))
            return
        }
        guard let result = message["result"] as? [String: Any] else { return }
        if id == 1 {
            do {
                try process?.write(["method": "initialized"])
                try process?.write(["id": 2, "method": "account/rateLimits/read"])
                try process?.write(["id": 3, "method": "account/read", "params": [String: Any]()])
            } catch { fail("Codex stopped before it reported usage.") }
        } else if id == 2 {
            let limits = AgentUsageLimitsService.codexLimits(result, checkedAt: Date())
            if identity != nil { finish(limits) } else { heldLimits = limits }
        }
    }

    /// Grok answers `auth_required` both when signed out and when signed in with an
    /// API key, which has no plan; the key is left out.
    private func acpFailed(_ error: [String: Any]) {
        let detail = error["data"] as? String ?? error["message"] as? String ?? "unknown error"
        if detail.contains("requires auth with grok.com") { return finish(nil) }
        if (error["code"] as? Int) == -32000, let signIn = provider.spec.signInCommand {
            return fail("\(provider.name) is not signed in. Run `\(signIn)` and try again.")
        }
        fail("\(provider.name) could not read usage: \(String(detail.prefix(300)))")
    }

    private func fail(_ reason: String) {
        finish(AgentUsageLimits(provider: provider, failure: reason))
    }

    private func finish(_ limits: AgentUsageLimits?) {
        guard let continuation else { return }
        var limits = limits
        if let identity, var known = limits {
            known.account = known.account ?? identity.account.flatMap { $0.isEmpty ? nil : String($0.prefix(256)) }
            known.plan = identity.plan ?? known.plan
            limits = known
        }
        self.continuation = nil
        process?.stop()
        process = nil
        continuation.resume(returning: limits)
    }
}
