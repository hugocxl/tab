import Foundation

/// Fetches an immutable turn comparison, independently of bounded chat history.
public struct AgentCheckpointRequest: Codable, Hashable, Sendable {
    public var session: SessionId
    public var checkpoint: String
    public var path: String?
    public var offset: Int
    public init(session: SessionId, checkpoint: String, path: String? = nil, offset: Int = 0) {
        self.session = session; self.checkpoint = checkpoint; self.path = path; self.offset = offset
    }
    public func validate() throws(ErrorCode) {
        guard UUID(uuidString: checkpoint) != nil, offset >= 0,
              path.map({ !$0.isEmpty && $0.utf8.count <= 16 * 1024 && !$0.contains("\0") }) ?? true else { throw .badRequest }
    }
}

public struct AgentCheckpointReply: Codable, Hashable, Sendable {
    public var checkpoint: String
    public var files: [AgentTurnCheckpoint.File]
    public var totalFiles: Int
    public var nextOffset: Int?
    public var path: String?
    public var diff: GitDiff?
    public init(checkpoint: String, files: [AgentTurnCheckpoint.File], totalFiles: Int,
                nextOffset: Int? = nil, path: String? = nil, diff: GitDiff? = nil) {
        self.checkpoint = checkpoint; self.files = files; self.totalFiles = totalFiles
        self.nextOffset = nextOffset; self.path = path; self.diff = diff
    }
    public func validate() throws(ErrorCode) {
        guard UUID(uuidString: checkpoint) != nil, files.count <= 128, totalFiles >= files.count,
              nextOffset.map({ $0 > 0 && $0 < totalFiles }) ?? true,
              (try? WireJSON.encode(self).count).map({ $0 < Limits.maxFrame - 1024 }) ?? false else { throw .badRequest }
    }
}
