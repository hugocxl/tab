import Foundation

/// Asks the server for its signed-in agents' subscription limits, as the
/// providers' own CLIs report them. Replies `agentUsageLimits`.
public struct AgentUsageLimitsRequest: Hashable, Codable, Sendable {
    /// Asks the CLIs again instead of answering from the last minute's reading.
    public var forceRefresh: Bool

    public init(forceRefresh: Bool = false) {
        self.forceRefresh = forceRefresh
    }

    private enum CodingKeys: String, CodingKey { case forceRefresh }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        forceRefresh = try container.decodeIfPresent(Bool.self, forKey: .forceRefresh) ?? false
    }
}

/// One rate-limit window of a provider's plan, such as its five-hour session.
public struct AgentUsageWindow: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case session, weekly, monthly, unknown

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// Stable within a provider, such as `five_hour` or `seven_day_fable`.
    public var id: String
    public var kind: Kind
    /// What the window is called, such as "Weekly · Fable".
    public var label: String
    /// How much of the window is spent, 0–100.
    public var usedPercent: Double
    /// How long the window lasts, when known; lets clients compare spending with time.
    public var windowDurationMinutes: Int?
    public var resetsAt: Date?

    public init(id: String, kind: Kind, label: String, usedPercent: Double,
                windowDurationMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.usedPercent = min(max(usedPercent.isFinite ? usedPercent : 0, 0), 100)
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey { case id, kind, label, usedPercent, windowDurationMinutes, resetsAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .unknown
        label = try container.decode(String.self, forKey: .label)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        windowDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .windowDurationMinutes)
        resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
    }
}

/// One agent account's limits, or why they could not be read.
public struct AgentUsageLimits: Hashable, Codable, Sendable {
    public var provider: AgentChatProvider
    /// The provider configuration the limits belong to, such as `claude-work`, when the
    /// server has several of one kind. Nil from servers that read one per kind.
    public var providerId: String?
    /// The configuration's own name, such as "Side project", when it has one.
    public var providerName: String?
    /// The plan the CLI reports, such as "Team", "Plus" or "SuperGrok Heavy".
    public var plan: String?
    /// Who is signed in: an email address or a workspace name.
    public var account: String?
    public var windows: [AgentUsageWindow]
    /// Why the windows are missing, such as a signed-out CLI. Nil when they were read.
    public var failure: String?
    public var checkedAt: Date

    public init(provider: AgentChatProvider, providerId: String? = nil, providerName: String? = nil,
                plan: String? = nil, account: String? = nil, windows: [AgentUsageWindow] = [],
                failure: String? = nil, checkedAt: Date = Date()) {
        self.provider = provider
        self.providerId = providerId
        self.providerName = providerName
        self.plan = plan
        self.account = account
        self.windows = windows
        self.failure = failure
        self.checkedAt = checkedAt
    }

    private enum CodingKeys: String, CodingKey {
        case provider, providerId, providerName, plan, account, windows, failure, checkedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(AgentChatProvider.self, forKey: .provider)
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId)
        providerName = try container.decodeIfPresent(String.self, forKey: .providerName)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        windows = try container.decodeIfPresent([AgentUsageWindow].self, forKey: .windows) ?? []
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        checkedAt = try container.decodeIfPresent(Date.self, forKey: .checkedAt) ?? Date()
    }
}

public struct AgentUsageLimitsReply: Hashable, Codable, Sendable {
    public static let maxProviders = 128
    public static let maxWindows = 32
    /// Providers this build doesn't know are left out rather than failing the reply.
    public var providers: [AgentUsageLimits]

    public init(providers: [AgentUsageLimits]) {
        self.providers = providers
    }

    private enum CodingKeys: String, CodingKey { case providers }

    private struct Lossy: Decodable {
        var value: AgentUsageLimits?
        init(from decoder: Decoder) throws { value = try? AgentUsageLimits(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = (try container.decodeIfPresent([Lossy].self, forKey: .providers) ?? []).compactMap(\.value)
    }

    public func validate() throws(ErrorCode) {
        guard providers.count <= Self.maxProviders else { throw .badRequest }
        for limits in providers {
            guard limits.windows.count <= Self.maxWindows, (limits.failure?.utf8.count ?? 0) <= 1024,
                  [limits.providerId, limits.providerName, limits.plan, limits.account]
                      .allSatisfy({ ($0?.utf8.count ?? 0) <= 256 }) else { throw .badRequest }
            var ids = Set<String>()
            for window in limits.windows {
                guard !window.id.isEmpty, window.id.utf8.count <= 128, !window.label.isEmpty, window.label.utf8.count <= 256,
                      window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                      (window.windowDurationMinutes ?? 1) > 0,
                      ids.insert(window.id).inserted else { throw .badRequest }
            }
        }
    }
}
