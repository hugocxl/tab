import Foundation

/// A local draft comment anchored to immutable checkpoint lines, never the working tree.
struct AgentReviewComment: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var checkpoint: String
    var path: String
    var old: Bool
    var firstLine: UInt64
    var lastLine: UInt64
    var source: String
    var text: String

    var location: String { "\(path) · \(old ? "old" : "new") lines \(firstLine)–\(lastLine)" }

    static func prompt(_ comments: [Self]) -> String {
        "Please address these comments on the recorded turn changes:\n\n" + comments.map { comment in
            "File: \(comment.path)\nCheckpoint: \(comment.checkpoint)\nSide: \(comment.old ? "old" : "new")\nLines: \(comment.firstLine)–\(comment.lastLine)\n"
                + "Recorded source:\n" + comment.source.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
                + "\n\nComment:\n\(comment.text)"
        }.joined(separator: "\n\n---\n\n")
    }
}

struct DiffReviewSelection: Equatable {
    var rows: ClosedRange<Int>
    var old: Bool

    func lines(in document: DiffDocument) -> (first: UInt64, last: UInt64, source: String)? {
        guard document.rows.indices.contains(rows.lowerBound), document.rows.indices.contains(rows.upperBound) else { return nil }
        let selected = document.rows[rows]
        guard !selected.contains(where: { $0.kind == .hunk }) else { return nil }
        let numbered = selected.compactMap { row -> (UInt64, String)? in
            guard let line = old ? row.oldLineNumber : row.newLineNumber else { return nil }
            return (line, DiffDocument.content(row, old: old))
        }
        guard let first = numbered.first?.0, let last = numbered.last?.0 else { return nil }
        let source = numbered.map(\.1).joined(separator: "\n")
        let excerpt = String(source.prefix(8_000)) + (source.count > 8_000 ? "\n[excerpt truncated]" : "")
        return (first, last, excerpt)
    }
}
