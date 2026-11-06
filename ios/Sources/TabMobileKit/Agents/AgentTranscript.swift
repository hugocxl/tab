import Foundation
import TabProtocol

/// One row of an agent transcript as the phone shows it.
public enum TranscriptRow: Hashable, Sendable, Identifiable {
    case user(AgentChatItem)
    case assistant(AgentChatItem)
    case tool(AgentChatItem)
    case thinking(AgentChatItem)
    /// An approval still waiting for an answer.
    case approval(AgentChatItem)
    /// An answered approval, or a notice from the agent or the server.
    case notice(AgentChatItem, isError: Bool)
    /// A finished turn's tool steps, folded.
    case work(turn: String, steps: Int, duration: TimeInterval?, expanded: Bool)
    /// The agent is working on a turn that started at `since`.
    case working(since: Date?)

    /// Which cell shows the row.
    public var kind: Int {
        switch self {
        case .user: 0
        case .assistant: 1
        case .tool: 2
        case .thinking: 3
        case .approval: 4
        case .notice: 5
        case .work: 6
        case .working: 7
        }
    }

    public var id: String {
        switch self {
        case .user(let item), .assistant(let item), .tool(let item), .thinking(let item), .approval(let item):
            item.id
        case .notice(let item, _): item.id
        case .work(let turn, _, _, _): "work-\(turn)"
        case .working: "working"
        }
    }
}

public enum AgentTranscript {
    /// The rows for `snapshot`. A finished turn's tool and thinking steps fold
    /// into one row unless the turn is in `expanded`; the running turn and
    /// turns with pending approvals stay open.
    public static func rows(_ snapshot: AgentChatSnapshot?, expanded: Set<String>) -> [TranscriptRow] {
        guard let snapshot else { return [] }
        let turns = Dictionary((snapshot.turns ?? []).map { ($0.userItemID, $0) }, uniquingKeysWith: { _, last in last })
        var rows: [TranscriptRow] = []
        var currentTurn: AgentChatTurn?
        var folded: (index: Int, steps: Int)?

        for item in snapshot.items {
            if item.kind == .user {
                currentTurn = turns[item.id]
                folded = nil
                rows.append(.user(item))
                continue
            }
            let isStep = item.kind == .tool && !isCard(item)
            if isStep, let turn = currentTurn, turn.completedAt != nil, !expanded.contains(turn.userItemID) {
                let duration = turn.completedAt.map { $0.timeIntervalSince(turn.startedAt) }
                if let open = folded {
                    folded = (open.index, open.steps + 1)
                    rows[open.index] = .work(turn: turn.userItemID, steps: open.steps + 1, duration: duration,
                                             expanded: false)
                } else {
                    folded = (rows.count, 1)
                    rows.append(.work(turn: turn.userItemID, steps: 1, duration: duration, expanded: false))
                }
                continue
            }
            if isStep, let turn = currentTurn, turn.completedAt != nil, folded == nil {
                folded = (rows.count, 0)
                rows.append(.work(turn: turn.userItemID, steps: 0, duration: turn.completedAt.map {
                    $0.timeIntervalSince(turn.startedAt)
                }, expanded: true))
            }
            if let row = row(for: item) { rows.append(row) }
        }
        // Expanded folds count their steps too.
        for index in rows.indices {
            guard case .work(let turn, 0, let duration, true) = rows[index] else { continue }
            let steps = stepCount(snapshot, turn: turn)
            rows[index] = .work(turn: turn, steps: steps, duration: duration, expanded: true)
        }
        if snapshot.status == .working {
            let since = snapshot.turns?.last(where: { $0.completedAt == nil })?.startedAt
            rows.append(.working(since: since))
        }
        return rows
    }

    private static func row(for item: AgentChatItem) -> TranscriptRow? {
        switch item.kind {
        case .user: return .user(item)
        case .assistant: return item.text.isEmpty ? nil : .assistant(item)
        case .approval: return item.isComplete ? .notice(item, isError: false) : .approval(item)
        case .notice: return .notice(item, isError: item.workContext?.itemType == "error")
        case .tool:
            switch item.workContext?.itemType {
            case "reasoning": return .thinking(item)
            case "error": return .notice(item, isError: true)
            case "compaction", "system_notice": return .notice(item, isError: false)
            default: return .tool(item)
            }
        }
    }

    /// Tool items that read as messages, never folded away.
    private static func isCard(_ item: AgentChatItem) -> Bool {
        ["error", "compaction", "system_notice", "proposed_plan", "todo_list"].contains(item.workContext?.itemType ?? "")
    }

    private static func stepCount(_ snapshot: AgentChatSnapshot, turn: String) -> Int {
        var counting = false
        var count = 0
        for item in snapshot.items {
            if item.kind == .user {
                counting = item.id == turn
                continue
            }
            if counting, item.kind == .tool, !isCard(item) { count += 1 }
        }
        return count
    }
}
