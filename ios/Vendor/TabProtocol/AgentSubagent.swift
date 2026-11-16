import Foundation

/// An agent the conversation's agent started, such as one Claude Code's Agent tool runs,
/// with its latest reported progress. Background agents keep running after the turn ends.
public struct AgentSubagent: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Hashable, Sendable {
        case running, completed, failed, stopped
    }

    /// The provider's task ID.
    public var id: String
    /// The transcript's tool row that started this agent.
    public var toolUseID: String?
    public var description: String
    /// The provider's agent type, such as `general-purpose` or `Explore`.
    public var agentType: String?
    public var background: Bool
    public var status: Status
    /// What the agent is doing now, such as "Running tests".
    public var activity: String?
    public var toolUses: Int?
    public var tokens: Int?
    public var startedAt: Date?
    /// When a finished agent stopped. A server keeps finished agents in the snapshot until
    /// the next prompt so their outcome stays visible; builds that predate this show
    /// running agents only.
    public var finishedAt: Date?
    /// How many of the agent's own steps the server holds; it changes as the agent
    /// works, so a client showing them knows to read them again.
    public var steps: Int?

    public init(id: String, toolUseID: String? = nil, description: String, agentType: String? = nil,
                background: Bool = false, status: Status = .running, activity: String? = nil,
                toolUses: Int? = nil, tokens: Int? = nil, startedAt: Date? = nil, finishedAt: Date? = nil, steps: Int? = nil) {
        self.id = id; self.toolUseID = toolUseID; self.description = description; self.agentType = agentType
        self.background = background; self.status = status; self.activity = activity
        self.toolUses = toolUses; self.tokens = tokens; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case id, toolUseID, description, agentType, background, status, activity, toolUses, tokens, startedAt, finishedAt, steps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        toolUseID = try c.decodeIfPresent(String.self, forKey: .toolUseID)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        agentType = try c.decodeIfPresent(String.self, forKey: .agentType)
        background = try c.decodeIfPresent(Bool.self, forKey: .background) ?? false
        // A newer server's status this build doesn't know still reads as finished.
        status = try c.decodeIfPresent(String.self, forKey: .status).map { Status(rawValue: $0) ?? .completed } ?? .running
        activity = try c.decodeIfPresent(String.self, forKey: .activity)
        toolUses = try c.decodeIfPresent(Int.self, forKey: .toolUses)
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        steps = try c.decodeIfPresent(Int.self, forKey: .steps)
    }

    /// Wire bounds a snapshot's subagents stay within.
    public static let maxCount = 64
    /// Finished agents a snapshot keeps beside the running ones.
    public static let maxFinished = 16

    public func validate() throws(ErrorCode) {
        guard [id, toolUseID, description, agentType, activity].allSatisfy({ ($0?.utf8.count ?? 0) <= 1024 }),
              (toolUses ?? 0) >= 0, (tokens ?? 0) >= 0, (steps ?? 0) >= 0 else { throw .badRequest }
    }
}
