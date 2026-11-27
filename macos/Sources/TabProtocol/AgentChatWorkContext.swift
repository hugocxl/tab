import Foundation

/// Provider/app identities used by the pinned conversation timeline. Missing data
/// remains unknown; display labels never manufacture retry or item boundaries.
public struct AgentChatWorkContext: Codable, Hashable, Sendable {
    /// The server's accepted native turn identity, distinct from a provider turn ID.
    public var runID: String?
    public var providerTurnID: String?
    public var itemType: String?
    public var sourceStatus: String?
    public var toolNonExecutionKind: String?
    public var requestKind: String?
    public var beforeTokenCount: Int?
    public var afterTokenCount: Int?
    /// Presentation state of an observed plan; never a provider run/attempt ID.
    public var planStatus: String?
    public init(runID: String? = nil, providerTurnID: String? = nil,
                itemType: String? = nil, sourceStatus: String? = nil, toolNonExecutionKind: String? = nil, requestKind: String? = nil,
                beforeTokenCount: Int? = nil, afterTokenCount: Int? = nil, planStatus: String? = nil) {
        self.runID = runID; self.providerTurnID = providerTurnID
        self.itemType = itemType
        self.sourceStatus = sourceStatus; self.toolNonExecutionKind = toolNonExecutionKind; self.requestKind = requestKind
        self.beforeTokenCount = beforeTokenCount; self.afterTokenCount = afterTokenCount
        self.planStatus = planStatus
    }
}
