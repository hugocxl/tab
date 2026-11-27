import Foundation
import TabProtocol

/// One choice in a searchable list, such as a prompt or a saved conversation.
public struct AgentPickerEntry: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }

    /// Whether `query` appears in the title or detail, ignoring case and accents.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return title.range(of: query, options: options) != nil || detail.range(of: query, options: options) != nil
    }
}

/// The conversation's prompts, as the desktop's outline lists them, and moving
/// between them by their item ids.
public enum AgentPromptNavigation {
    public static func entries(_ items: [AgentChatItem]) -> [AgentPickerEntry] {
        items.filter { $0.kind == .user }.enumerated().map { index, item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let files = item.attachments?.count ?? 0
            return AgentPickerEntry(id: item.id,
                                    title: text.isEmpty ? "Attachments" : text.replacingOccurrences(of: "\n", with: " "),
                                    detail: "Prompt \(index + 1)" + (files == 0 ? "" : files == 1 ? " · 1 attachment" : " · \(files) attachments"))
        }
    }

    /// The prompt before or after `current`; without one, the last or first
    /// prompt. Nil past either end.
    public static func destination(ids: [String], current: String?, previous: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return previous ? ids.last : ids.first }
        let next = index + (previous ? -1 : 1)
        return ids.indices.contains(next) ? ids[next] : nil
    }
}

/// The steps of a `todo_list` item, as Claude and Codex report them.
public struct AgentTodoList: Equatable, Sendable {
    public enum Status: String, Sendable { case pending, running, completed }

    public struct Step: Equatable, Sendable {
        public var id: String
        public var text: String
        public var status: Status
    }

    public var steps: [Step]

    public init?(detail: String?) {
        guard let data = detail?.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawSteps = object["steps"] as? [Any] else { return nil }
        var steps: [Step] = []
        for raw in rawSteps {
            guard let step = raw as? [String: Any],
                  let id = step["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let text = step["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let status = (step["status"] as? String).flatMap(Status.init(rawValue:)) else { return nil }
            steps.append(Step(id: id, text: text, status: status))
        }
        self.steps = steps
    }

    public var completedCount: Int { steps.filter { $0.status == .completed }.count }

    /// Such as "2 of 5 done".
    public var progress: String { "\(completedCount) of \(steps.count) done" }
}

/// The latest unfinished task list, shown above the composer. It decodes the
/// list only when its item changes, not on every streamed token.
public struct AgentTaskProgress: Sendable {
    private var itemID: String?
    private var detail: String?
    private var list: AgentTodoList?
    private var status: AgentChatStatus?
    /// Such as "2 of 5 done · Run the tests", or "Paused · …" once the agent stopped.
    public private(set) var title = ""
    /// The task list's item, or nil when there's nothing left to do.
    public private(set) var target: String?

    public init() {}

    public mutating func update(_ snapshot: AgentChatSnapshot?) {
        let item = snapshot?.items.last { $0.workContext?.itemType == "todo_list" }
        let changed = itemID != item?.id || detail != item?.detail
        guard changed || status != snapshot?.status else { return }
        status = snapshot?.status
        if changed {
            itemID = item?.id
            detail = item?.detail
            list = AgentTodoList(detail: item?.detail)
        }
        guard let list, !list.steps.isEmpty, list.completedCount < list.steps.count else {
            target = nil
            title = ""
            return
        }
        target = itemID
        let step = list.steps.first { $0.status == .running } ?? list.steps.first { $0.status == .pending }
        let paused = status != .working && status != .waiting
        title = (paused ? "Paused · " : "") + list.progress + (step.map { " · " + $0.text } ?? "")
    }
}

/// A comment on lines of a turn's recorded changes, kept with the draft until
/// it goes into a message. It points at the checkpoint, never the files as
/// they are now.
public struct AgentReviewComment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var checkpoint: String
    public var path: String
    /// The lines are the file's before the turn, not after.
    public var old: Bool
    public var firstLine: UInt64
    public var lastLine: UInt64
    /// The commented lines as recorded.
    public var source: String
    public var text: String

    public init(id: String = UUID().uuidString, checkpoint: String, path: String, old: Bool, firstLine: UInt64,
                lastLine: UInt64, source: String, text: String) {
        self.id = id
        self.checkpoint = checkpoint
        self.path = path
        self.old = old
        self.firstLine = firstLine
        self.lastLine = lastLine
        self.source = source
        self.text = text
    }

    public var lines: String { firstLine == lastLine ? "line \(firstLine)" : "lines \(firstLine)–\(lastLine)" }

    /// Such as "Sources/App.swift · new lines 4–9".
    public var location: String { "\(path) · \(old ? "old" : "new") \(lines)" }

    /// The message that asks the agent to address `comments`, as the desktop writes it.
    public static func prompt(_ comments: [Self]) -> String {
        "Please address these comments on the recorded turn changes:\n\n" + comments.map { comment in
            "File: \(comment.path)\nCheckpoint: \(comment.checkpoint)\nSide: \(comment.old ? "old" : "new")\nLines: \(comment.firstLine)–\(comment.lastLine)\n"
                + "Recorded source:\n" + comment.source.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
                + "\n\nComment:\n\(comment.text)"
        }.joined(separator: "\n\n---\n\n")
    }

    /// The source of `rows` on one side, numbered; nil when they cross a hunk
    /// header or hold no line of that side.
    public static func selection(_ rows: ArraySlice<GitDiffRow>, old: Bool) -> (first: UInt64, last: UInt64, source: String)? {
        guard !rows.contains(where: { $0.kind == .hunk }) else { return nil }
        let numbered = rows.compactMap { row -> (UInt64, String)? in
            guard let line = old ? row.oldLineNumber : row.newLineNumber else { return nil }
            return (line, content(row, old: old))
        }
        guard let first = numbered.first?.0, let last = numbered.last?.0 else { return nil }
        let source = numbered.map(\.1).joined(separator: "\n")
        let excerpt = String(source.prefix(8_000)) + (source.count > 8_000 ? "\n[excerpt truncated]" : "")
        return (first, last, excerpt)
    }

    /// A row's text on one side, without its diff marker.
    public static func content(_ row: GitDiffRow, old: Bool) -> String {
        if let text = old ? row.oldText : row.newText { return text }
        if row.kind == .hunk || row.text.isEmpty { return row.text }
        return String(row.text.dropFirst())
    }
}
