import Foundation

/// Server-observed timing and outcome for one accepted user message.
public struct AgentChatTurn: Codable, Hashable, Sendable {
    public var userItemID: String
    public var startedAt: Date
    public var completedAt: Date?
    public var status: AgentChatStatus

    public init(userItemID: String, startedAt: Date, completedAt: Date? = nil, status: AgentChatStatus = .working) {
        self.userItemID = userItemID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
    }
}
