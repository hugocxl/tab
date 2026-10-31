import Foundation

extension AgentChatRequest {
    public func validate() throws(ErrorCode) {
        switch self {
        case .send(_, let text, let model, let effort, _, let attachments):
            try AgentChatAttachment.validate(attachments ?? [])
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !(attachments ?? []).isEmpty {
                guard text.utf8.count <= 64 * 1024 else { throw .badRequest }
            } else {
                try Validation.message(text, limit: 64 * 1024)
            }
            if let model { try Validation.message(model, limit: 256) }
            try effort?.validate()
        case .approve(_, let request, _):
            try Validation.message(request, limit: 1024)
        case .create, .read, .interrupt, .close, .setAccess:
            break
        }
    }
}

extension AgentChatSnapshot {
    public func validate() throws(ErrorCode) {
        try reasoningEffort?.validate()
        guard items.count <= 512,
              items.reduce(0, { $0 + $1.transcriptByteCount }) <= 512 * 1024,
              items.allSatisfy({ $0.id.utf8.count <= 1024 }),
              (providerSession?.utf8.count ?? 0) <= 4096,
              (model?.utf8.count ?? 0) <= 256,
              (resolvedModel?.utf8.count ?? 0) <= 256 else { throw .badRequest }
        if let contextUsage {
            guard contextUsage.usedTokens >= 0,
                  contextUsage.contextWindow.map({ $0 > 0 }) ?? true else { throw .badRequest }
        }
        if let turns {
            let users = Set(items.filter { $0.kind == .user }.map(\.id))
            guard turns.count <= 512,
                  turns.allSatisfy({ turn in
                      users.contains(turn.userItemID) && (turn.completedAt.map { $0 >= turn.startedAt } ?? true)
                  }) else {
                throw .badRequest
            }
        }
        for turn in turns ?? [] { try turn.checkpoint?.validate() }
        for item in items {
            if let context = item.workContext {
                guard [context.runID, context.providerTurnID, context.itemType, context.sourceStatus, context.toolNonExecutionKind, context.requestKind, context.planStatus]
                    .allSatisfy({ ($0?.utf8.count ?? 0) <= 4096 && $0?.contains("\0") != true }) else { throw .badRequest }
                guard [context.beforeTokenCount, context.afterTokenCount].allSatisfy({
                    guard let count = $0 else { return true }
                    return count >= 0 && count <= 9_007_199_254_740_991
                }) else { throw .badRequest }
            }
            if let attachments = item.attachments {
                guard attachments.count <= AgentChatAttachment.maxCount else { throw .badRequest }
                for attachment in attachments { try attachment.validate() }
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
            + (attachments ?? []).reduce(0) { $0 + $1.transcriptByteCount }
            + (createdAt == nil ? 0 : 48) + (updatedAt == nil ? 0 : 48)
            + (workContext.map { context in
                400 + [context.runID, context.providerTurnID, context.itemType, context.sourceStatus, context.toolNonExecutionKind, context.requestKind, context.planStatus]
                    .reduce(0) { $0 + ($1?.utf8.count ?? 0) }
            } ?? 0)
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
        for pattern in searchPatterns ?? [] { bytes += 8 + pattern.utf8.count }
        for result in webResults ?? [] {
            bytes += 64 + (result.title?.utf8.count ?? 0) + (result.url?.utf8.count ?? 0) + (result.snippet?.utf8.count ?? 0)
        }
        if let details = fileSearchDetails {
            bytes += 64 + (details.pattern?.utf8.count ?? 0)
            for result in details.results ?? [] {
                bytes += 128 + result.fileName.utf8.count + (result.preview?.utf8.count ?? 0)
            }
        }
        if let details = fileChangeDetails {
            bytes += 128 + details.fileName.utf8.count + (details.diff?.utf8.count ?? 0)
            for operation in details.operations ?? [] {
                bytes += 128 + operation.operation.utf8.count + operation.path.utf8.count + (operation.oldPath?.utf8.count ?? 0)
                    + (operation.fileType?.utf8.count ?? 0) + (operation.mimeType?.utf8.count ?? 0)
            }
        }
        return bytes
    }
}
