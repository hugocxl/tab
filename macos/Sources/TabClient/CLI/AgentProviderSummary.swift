import Foundation
import TabProtocol

/// What `tab agent providers` says about one of the server's providers: who it is signed in
/// as, whether it can start an agent, how much of its subscription it has used and which
/// models it offers, so an agent can pick one for `tab pane new agent --provider`.
public struct AgentProviderSummary: Hashable, Sendable {
    public var config: AgentProviderConfig
    public var health: AgentProviderHealth?
    public var usage: AgentUsageLimits?
    /// Nil when the models weren't read, such as for a provider that can't run.
    public var models: [AgentModelDescriptor]?

    public init(config: AgentProviderConfig, health: AgentProviderHealth?, usage: AgentUsageLimits?,
                models: [AgentModelDescriptor]?) {
        self.config = config
        self.health = health
        self.usage = usage
        self.models = models
    }

    public static let columns = ["id", "kind", "name", "status", "account", "usage", "models"]

    /// How many models the line lists before `+N more`; `--json` lists them all.
    static let listedModels = 8

    /// Whether it can start an agent now, and if not why, as `tab pane new agent` would refuse.
    public func refusal(model: String?, now: Date = Date()) -> String? {
        Self.refusal(config, health: health, usage: usage, model: model, now: now)
    }

    /// `ready`, `off`, `signed out`, `not installed`, `limit reached until …`, `unchecked` and so on.
    public func status(now: Date = Date()) -> String {
        guard config.enabled else { return "off" }
        if let window = usage.flatMap({ Self.spentWindow($0, model: nil, now: now) }) {
            return "limit reached" + (window.resetsAt.map { " until \(Self.time($0))" } ?? "")
        }
        guard let health else { return "unchecked" }
        if !health.installed { return "not installed" }
        if health.auth == .signedOut { return "signed out" }
        if health.versionAdvisory?.status == .unsupported { return "needs update" }
        return health.status == .error ? "error" : "ready"
    }

    /// How it is signed in, without the email address, which only `--json` shows.
    public var account: String? {
        let plan = usage?.plan.map { $0.lowercased().contains("plan") ? $0 : "\($0) plan" }
        return health?.account ?? plan
    }

    /// `Session 42% (resets …), Weekly 88% (resets …)`, or why there is none.
    public var usageText: String { usageText(now: Date()) }

    /// A reset already past, such as Antigravity's for a window not yet started, is left out.
    public func usageText(now: Date) -> String {
        guard let usage else {
            return AgentUsageLimits.reportingKinds.contains(config.kind) ? "unknown" : "not reported"
        }
        if usage.windows.isEmpty { return "unknown" + (usage.failure.map { ": \($0)" } ?? "") }
        return usage.windows.map { window in
            "\(window.label) \(Int(window.usedPercent.rounded()))%" + (window.resetsAt.flatMap { $0 > now ? " (resets \(Self.time($0)))" : nil } ?? "")
        }.joined(separator: ", ")
    }

    public var modelsText: String? {
        guard let models else { return nil }
        let listed = models.prefix(Self.listedModels).map { $0.isDefault ? "\($0.id) (default)" : $0.id }
        let more = models.count > Self.listedModels ? ["+\(models.count - Self.listedModels) more"] : []
        return (listed + more).joined(separator: ", ")
    }

    public func record(now: Date = Date()) -> JSONValue {
        func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
        return .object([
            "id": .string(config.id),
            "kind": .string(config.kind.rawValue),
            "name": .string(config.title),
            "enabled": .bool(config.enabled),
            "status": .string(status(now: now)),
            "canStart": .bool(refusal(model: nil, now: now) == nil),
            "reason": text(refusal(model: nil, now: now)),
            "account": text(account),
            "email": text(health?.email ?? usage?.account.flatMap { $0.contains("@") ? $0 : nil }),
            "usage": .string(usageText(now: now)),
            "windows": usage.map { usage in
                .array(usage.windows.map { window in
                    .object([
                        "id": .string(window.id),
                        "label": .string(window.label),
                        "usedPercent": .double(window.usedPercent),
                        "resetsAt": text(window.resetsAt.flatMap { $0 > now ? Self.time($0) : nil }),
                    ])
                })
            } ?? .null,
            "models": models.map { models in
                .array(models.map { model in
                    .object([
                        "id": .string(model.id),
                        "title": .string(model.title),
                        "default": .bool(model.isDefault),
                        "efforts": .array(model.reasoningEfforts.map { .string($0.rawValue) }),
                    ])
                })
            } ?? .null,
        ])
    }

    /// The tab-separated line's fields.
    public func row(now: Date = Date()) -> JSONValue {
        func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
        return .object([
            "id": .string(config.id),
            "kind": .string(config.kind.rawValue),
            "name": .string(config.title),
            "status": .string(status(now: now)),
            "account": text(account),
            "usage": .string(usageText(now: now)),
            "models": text(modelsText),
        ])
    }

    // MARK: Rules

    /// Why `config` can't start an agent on `model` now: off, missing, signed out, or out of
    /// usage until a window resets. Nil when it can, or when nothing says otherwise.
    public static func refusal(_ config: AgentProviderConfig, health: AgentProviderHealth?, usage: AgentUsageLimits?,
                               model: String?, now: Date = Date()) -> String? {
        let name = "\(config.title) (\(config.id))"
        guard config.enabled else { return "\(name) is off; turn it on in Settings › Agents" }
        if let health, !health.installed {
            return "\(name) isn't installed on this server; install it in Settings › Agents"
        }
        if let health, health.auth == .signedOut {
            let command = health.signInCommand.map { ": `\($0)`" } ?? " in Settings › Agents"
            return "\(name) is signed out; the user has to sign it in\(command)"
        }
        if let usage, let window = spentWindow(usage, model: model, now: now) {
            let until = window.resetsAt.map { " until \(time($0))" } ?? ""
            return "\(name) has used its \(window.label) limit\(until); tab agent providers lists the others"
        }
        return nil
    }

    /// The window that stops `model` from running: used up and not yet reset, the one
    /// that resets last. A window for one model, such as `Weekly · Fable`, stops only that
    /// model; a spend cap stops nothing, since the plan's own windows still apply.
    public static func spentWindow(_ usage: AgentUsageLimits, model: String?, now: Date = Date()) -> AgentUsageWindow? {
        usage.windows.filter { window in
            guard window.usedPercent >= 100, window.kind != .monthly || !window.id.contains("spend"),
                  window.resetsAt.map({ $0 > now }) ?? true else { return false }
            guard let scope = scope(window) else { return true }
            guard let model else { return false }
            return token(model).contains(scope)
        }.max { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
    }

    /// The model a window is for, from a label such as `Weekly · Fable`; nil for the whole plan.
    static func scope(_ window: AgentUsageWindow) -> String? {
        guard let range = window.label.range(of: " · ") else { return nil }
        let name = token(String(window.label[range.upperBound...]))
        return name.isEmpty ? nil : name
    }

    private static func token(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The reading of `config`'s account: its own, else that of a provider signed in to
    /// the same account, since the server reads each account once.
    public static func usage(for config: AgentProviderConfig, in limits: [AgentUsageLimits],
                             providers: [AgentProviderConfig]) -> AgentUsageLimits? {
        if let own = limits.first(where: { $0.providerId == config.id }) { return own }
        let sharing = Set(providers.filter { $0.id != config.id && $0.sharesSignIn(with: config) }.map(\.id))
        if let shared = limits.first(where: { $0.providerId.map(sharing.contains) ?? false }) { return shared }
        // Servers that read one account per kind name no provider.
        return limits.first { $0.providerId == nil && $0.provider == config.kind && config.isBuiltIn }
    }

    /// A date in the server's time zone, as `2026-11-28T15:10+01:00`.
    static func time(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate,
                                   .withTimeZone, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }
}
