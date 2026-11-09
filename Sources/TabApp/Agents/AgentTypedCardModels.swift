import Foundation
import TabProtocol

/// Transcript items shown as typed cards rather than generic tool rows. The
/// classification follows the removed web projection: errors first, then plans,
/// then todo lists with valid steps, then notices and compaction boundaries.
enum AgentTypedCardKind: Equatable {
    case plan, todo, compaction, error, notice
    /// Another agent: a worker this conversation started, its report, or a message it sent.
    case peer(AgentPeerCardRow.Mode)

    static func classify(_ item: AgentChatItem) -> AgentTypedCardKind? {
        classify(item) { AgentTodoList(detail: $0) != nil }
    }

    /// Classifies with `isValidTodoList` deciding whether a `todo_list` item's detail decodes.
    static func classify(_ item: AgentChatItem, isValidTodoList: (String?) -> Bool) -> AgentTypedCardKind? {
        if item.peer != nil {
            switch (item.kind, item.workContext?.itemType) {
            case (.notice, AgentPeerItemType.workerStarted): return .peer(.worker)
            case (.user, AgentPeerItemType.workerReport): return .peer(.report)
            case (.user, _): return .peer(.message)
            default: break
            }
        }
        guard item.kind == .tool || item.kind == .notice else { return nil }
        switch item.workContext?.itemType {
        case "error": return .error
        case "proposed_plan": return .plan
        case "todo_list" where isValidTodoList(item.detail): return .todo
        default: break
        }
        if item.kind == .notice { return .notice }
        return item.workContext?.itemType == "compaction" ? .compaction : nil
    }

    /// Errors and started workers stay visible below a folded turn; every other card
    /// folds like a tool row.
    var folds: Bool { self != .error && self != .peer(.worker) }
}

/// Classifies transcript items for one document, remembering whether each todo list's
/// detail decodes so snapshots that leave an item unchanged do not parse its JSON again.
/// The memo holds at most `limit` items and is cleared when full.
@MainActor
final class AgentTypedCardClassifier {
    static let limit = 256
    private struct Memo { var detail: String?; var valid: Bool }
    private var todoMemo: [String: Memo] = [:]
    /// Decodes a todo detail; replaceable to count parses.
    var parseTodo: (String?) -> Bool = { AgentTodoList(detail: $0) != nil }
    /// JSON parses performed over the classifier's lifetime.
    private(set) var parseCount = 0

    func classify(_ item: AgentChatItem) -> AgentTypedCardKind? {
        AgentTypedCardKind.classify(item) { detail in
            if let memo = todoMemo[item.id], memo.detail == detail { return memo.valid }
            parseCount += 1
            let valid = parseTodo(detail)
            if todoMemo.count >= Self.limit { todoMemo.removeAll(keepingCapacity: true) }
            todoMemo[item.id] = Memo(detail: detail, valid: valid)
            return valid
        }
    }
}

/// A todo list decoded from `{ "steps": [{ "id", "text", "status" }], "explanation"? }`.
/// One invalid step invalidates the list, so the item falls back to generic tool output.
struct AgentTodoList: Equatable {
    enum Status: String { case pending, running, completed }

    struct Step: Equatable {
        var id: String
        var text: String
        var status: Status
    }

    var steps: [Step]
    var explanation: String?

    init?(detail: String?) {
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
        let explanation = (object["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.explanation = explanation?.isEmpty == false ? explanation : nil
    }

    var completedCount: Int { steps.filter { $0.status == .completed }.count }

    /// The header's progress, such as "2 of 5 done".
    var progress: String { "\(completedCount) of \(steps.count) done" }
}

/// The presentation state of a proposed plan; an absent or unknown status is a proposal.
enum AgentPlanStatus: String, Equatable {
    case proposed, active, completed, superseded

    init(_ raw: String?) {
        self = raw.flatMap(AgentPlanStatus.init(rawValue:)) ?? .proposed
    }

    var title: String { rawValue.capitalized }
}

/// Markdown export and workspace file naming for proposed plans.
enum AgentPlanExport {
    /// The plan as saved or copied: trimmed, ending in one newline.
    static func markdown(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// The text of the first ATX heading, if any.
    static func title(_ markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            let rest = trimmed.dropFirst(hashes)
            guard hashes <= 6, rest.isEmpty || rest.first == " " else { continue }
            let text = rest.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Lowercase ASCII letters and digits joined by single hyphens; "plan" when nothing remains.
    static func slug(_ text: String?) -> String {
        let folded = (text ?? "").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var result = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if !result.isEmpty, !result.hasSuffix("-") {
                result.append("-")
            }
            if result.count >= 60 { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "plan" : result
    }

    static func fileName(_ markdown: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return slug(title(markdown)) + "-" + formatter.string(from: date) + ".md"
    }

    /// Relative to the conversation's working directory.
    static func workspacePath(_ markdown: String, date: Date) -> String {
        "plans/" + fileName(markdown, date: date)
    }
}

/// The quiet compaction row's label.
enum AgentCompactionPresentation {
    static func providerName(_ provider: AgentChatProvider?) -> String? {
        switch provider {
        case .claude: "Claude Agent"
        case .codex: "Codex"
        case nil: nil
        }
    }

    /// 950, 5.8k, 148k, 1.3M.
    static func tokens(_ count: Int) -> String {
        let value = max(0, count)
        func trimmed(_ number: Double, suffix: String) -> String {
            let text = String(format: "%.1f", number)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        if value < 1_000 { return String(value) }
        if value < 10_000 { return trimmed(Double(value) / 1_000, suffix: "k") }
        if value < 999_500 { return String(Int((Double(value) / 1_000).rounded())) + "k" }
        return trimmed(Double(value) / 1_000_000, suffix: "M")
    }

    static func tokenSummary(before: Int?, after: Int?) -> String? {
        switch (before, after) {
        case let (before?, after?): tokens(before) + " → " + tokens(after) + " tokens"
        case let (before?, nil): tokens(before) + " tokens before"
        case let (nil, after?): tokens(after) + " tokens after"
        case (nil, nil): nil
        }
    }

    static func label(_ item: AgentChatItem, provider: AgentChatProvider?) -> String {
        let title = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([title.isEmpty ? "Context compacted" : title, providerName(provider),
                 tokenSummary(before: item.workContext?.beforeTokenCount, after: item.workContext?.afterTokenCount)]
            .compactMap { $0 }).joined(separator: " · ")
    }
}

/// The error card's body: trimmed, at most 4096 characters, monospaced for traces.
enum AgentErrorPresentation {
    static let limit = 4_096

    static func message(_ text: String) -> String {
        let clipped = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        return clipped.isEmpty ? "Agent failed" : clipped
    }

    static func looksLikeStackTrace(_ text: String) -> Bool {
        if text.contains("Traceback (most recent call last)") { return true }
        let frames = text.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("at ") || trimmed.hasPrefix("File \"")
                || trimmed.range(of: #"^\d+\s+\S+\s+0x[0-9a-fA-F]+"#, options: .regularExpression) != nil
                || trimmed.range(of: #"\.(swift|rs|js|ts|py|go|java):\d+"#, options: .regularExpression) != nil
        }
        return frames.count >= 2
    }
}

/// A tool that the provider declined, cancelled or blocked, shown after the tool title.
enum AgentToolNonExecution {
    static func label(_ kind: String?) -> String? {
        guard let kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines), !kind.isEmpty else { return nil }
        switch kind {
        case "permission-rule": return "Blocked by permission rule"
        default:
            let words = kind.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}
