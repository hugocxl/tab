import Foundation

extension AgentChatRequest {
    public func validate() throws(ErrorCode) {
        switch self {
        case .send(_, let text, let model, let effort, let provider):
            try Validation.message(text, limit: 64 * 1024)
            if let model { try Validation.message(model, limit: 256) }
            if let effort, let provider,
               !AgentReasoningEffort.supported(provider: provider, model: model).contains(effort) { throw .badRequest }
        case .approve(_, let request, _):
            try Validation.message(request, limit: 1024)
        case .create, .read, .interrupt, .close, .setAccess:
            break
        }
    }
}

extension AgentChatSnapshot {
    public func validate() throws(ErrorCode) {
        guard items.count <= 512,
              items.reduce(0, { $0 + $1.transcriptByteCount }) <= 512 * 1024,
              items.allSatisfy({ $0.id.utf8.count <= 1024 }),
              (providerSession?.utf8.count ?? 0) <= 4096,
              (model?.utf8.count ?? 0) <= 256 else { throw .badRequest }
        if let turns {
            let users = Set(items.filter { $0.kind == .user }.map(\.id))
            guard turns.count <= 512,
                  turns.allSatisfy({ turn in
                      users.contains(turn.userItemID) && (turn.completedAt.map { $0 >= turn.startedAt } ?? true)
                  }) else {
                throw .badRequest
            }
        }
        // Include JSON escaping and leave room for the reply envelope.
        guard let encoded = try? WireJSON.encode(self), encoded.count < Limits.maxFrame - 1024 else {
            throw .badRequest
        }
    }
}

extension AgentChatItem {
    /// Counts duplicated compatibility text and structured metadata, not just visible prose.
    public var transcriptByteCount: Int {
        text.utf8.count + (detail?.utf8.count ?? 0) + (tool?.transcriptByteCount ?? 0)
    }
}

extension AgentToolActivity {
    /// Includes a conservative allowance for JSON keys, dates and collection structure.
    public var transcriptByteCount: Int {
        var bytes = 512 + (name?.utf8.count ?? 0) + (input?.utf8.count ?? 0) + (output?.utf8.count ?? 0)
        for path in filePaths ?? [] { bytes += 8 + path.utf8.count }
        for url in urls ?? [] { bytes += 8 + url.utf8.count }
        for change in fileChanges ?? [] {
            bytes += 64 + change.path.utf8.count + (change.diff?.utf8.count ?? 0) + (change.kind?.utf8.count ?? 0)
        }
        return bytes
    }
}
