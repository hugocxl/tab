import AppKit
import TabProtocol

/// Builds immutable previews from the tool snapshot, never by diffing the current worktree.
@MainActor
enum AgentToolDiff {
    static func parse(_ source: String) -> GitDiff {
        var result = GitDiff(rows: [])
        var old: UInt64?, new: UInt64?
        let hasHunks = source.contains("@@ ")
        for line in source.components(separatedBy: "\n") {
            if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") { result.binary = true; continue }
            if line.hasPrefix("@@ ") {
                let fields = line.split(separator: " ")
                func start(_ index: Int) -> UInt64? {
                    guard fields.indices.contains(index) else { return nil }
                    return fields[index].dropFirst().split(separator: ",").first.flatMap { UInt64($0) }
                }
                old = start(1); new = start(2)
                result.rows.append(.init(kind: .hunk, text: line)); continue
            }
            if line.hasPrefix("diff --git ") { old = nil; new = nil; continue }
            if old == nil && new == nil && (line.hasPrefix("--- ") || line.hasPrefix("+++ ")) { continue }
            guard !hasHunks || old != nil || new != nil,
                  let first = line.first, ["+", "-", " "].contains(first) else { continue }
            let kind: GitDiffKind = first == "+" ? .addition : first == "-" ? .deletion : .context
            let content = String(line.dropFirst())
            result.rows.append(.init(kind: kind, oldLineNumber: kind == .addition ? nil : old,
                newLineNumber: kind == .deletion ? nil : new, oldText: kind == .addition ? nil : content,
                newText: kind == .deletion ? nil : content, text: line))
            if kind != .addition, let number = old { old = number < UInt64.max ? number + 1 : nil }
            if kind != .deletion, let number = new { new = number < UInt64.max ? number + 1 : nil }
            if kind == .addition { result.additions += 1 }; if kind == .deletion { result.deletions += 1 }
        }
        return result
    }

    static func makeWindow(session: SessionId, activity: AgentToolActivity, theme: AppTheme) -> AgentCheckpointDiffWindow {
        let checkpoint = UUID().uuidString
        var changes = activity.fileChanges ?? []
        if let details = activity.fileChangeDetails, let diff = details.diff, !diff.isEmpty {
            let parsed = parse(diff)
            if !parsed.rows.isEmpty || parsed.binary || changes.isEmpty {
                if let index = changes.firstIndex(where: { $0.path == details.fileName }) { changes[index].diff = diff }
                else { changes.insert(.init(path: details.fileName, diff: diff), at: 0) }
            }
        }
        if changes.isEmpty, let path = activity.fileChangeDetails?.fileName { changes = [.init(path: path)] }
        let captured = changes
        let window = AgentCheckpointDiffWindow(session: session, checkpoint: checkpoint, path: captured.first?.path, theme: theme) { request in
            let parsed = captured.map { ($0.path, parse($0.diff ?? "")) }
            let files = parsed.map { AgentTurnCheckpoint.File(path: $0.0, additions: $0.1.additions, deletions: $0.1.deletions) }
            var diff: GitDiff?
            if let path = request.path {
                guard let match = parsed.first(where: { $0.0 == path }), !match.1.rows.isEmpty || match.1.binary else {
                    throw NSError(domain: "AgentToolDiff", code: 1, userInfo: [NSLocalizedDescriptionKey: "The tool did not provide a recorded patch for this file."])
                }
                diff = match.1
            }
            return .init(checkpoint: checkpoint, files: files, totalFiles: files.count, path: request.path, diff: diff)
        }
        window.window?.title = "Tool changes"
        return window
    }
}
