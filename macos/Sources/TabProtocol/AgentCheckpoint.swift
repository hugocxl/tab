import Foundation

/// Fetches an immutable turn comparison, independently of bounded chat history.
public struct AgentCheckpointRequest: Codable, Hashable, Sendable {
    public var session: SessionId
    public var checkpoint: String
    public var path: String?
    public var offset: Int
    /// Unchanged lines around each change in `path`'s diff, read from the checkpoint's own
    /// old and new files; nil for the usual three. Servers that predate it ignore it, and
    /// their reply's `context` stays nil.
    public var context: Int?
    public init(session: SessionId, checkpoint: String, path: String? = nil, offset: Int = 0, context: Int? = nil) {
        self.session = session; self.checkpoint = checkpoint; self.path = path; self.offset = offset; self.context = context
    }
    /// Enough context to show every line of any file a diff can hold.
    public static let wholeFile = 1_000_000
    public func validate() throws(ErrorCode) {
        guard UUID(uuidString: checkpoint) != nil, offset >= 0, context.map({ (0...Self.wholeFile).contains($0) }) ?? true,
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
    /// The context lines `diff` was read with, when the server honors `context`.
    public var context: Int?
    public init(checkpoint: String, files: [AgentTurnCheckpoint.File], totalFiles: Int,
                nextOffset: Int? = nil, path: String? = nil, diff: GitDiff? = nil, context: Int? = nil) {
        self.checkpoint = checkpoint; self.files = files; self.totalFiles = totalFiles
        self.nextOffset = nextOffset; self.path = path; self.diff = diff; self.context = context
    }
    public func validate() throws(ErrorCode) {
        guard UUID(uuidString: checkpoint) != nil, files.count <= 128, totalFiles >= files.count,
              nextOffset.map({ $0 > 0 && $0 < totalFiles }) ?? true,
              (try? WireJSON.encode(self).count).map({ $0 < Limits.maxFrame - 1024 }) ?? false else { throw .badRequest }
    }
}
