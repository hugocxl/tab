import Foundation

/// Provider-reported context for the latest model request, not cumulative billed usage.
public struct AgentContextUsage: Codable, Hashable, Sendable {
    public var usedTokens: Int
    /// Nil when the provider has not reported a capacity; clients must not invent a percentage.
    public var contextWindow: Int?

    public init(usedTokens: Int, contextWindow: Int? = nil) {
        self.usedTokens = usedTokens
        self.contextWindow = contextWindow
    }
}
