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
    /// A notice from the agent or the server.
    case notice(AgentChatItem, isError: Bool)
    /// A finished turn's tool steps, folded.
    case work(turn: String, steps: Int, duration: TimeInterval?, expanded: Bool)
    /// The files a finished turn changed, which open its recorded diff.
    case changes(turn: String, checkpoint: AgentTurnCheckpoint)
    /// The agent is working on `turn`; its time leaves out waits for the user.
    case working(turn: AgentChatTurn?)

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
        case .changes: 8
        }
    }

    public var id: String {
        switch self {
        case .user(let item), .assistant(let item), .tool(let item), .thinking(let item), .approval(let item):
            item.id
        case .notice(let item, _): item.id
        case .work(let turn, _, _, _): "work-\(turn)"
        case .changes(let turn, _): "changes-\(turn)"
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
                appendChanges(currentTurn, to: &rows)
                currentTurn = turns[item.id]
                folded = nil
                rows.append(.user(item))
                continue
            }
            let isStep = item.kind == .tool && !isCard(item)
            if isStep, let turn = currentTurn, turn.completedAt != nil, !expanded.contains(turn.userItemID) {
                let duration = turn.completedAt.map { turn.workingTime(at: $0) }
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
                    turn.workingTime(at: $0)
                }, expanded: true))
            }
            if let row = row(for: item) { rows.append(row) }
        }
        appendChanges(currentTurn, to: &rows)
        // Expanded folds count their steps too.
        for index in rows.indices {
            guard case .work(let turn, 0, let duration, true) = rows[index] else { continue }
            let steps = stepCount(snapshot, turn: turn)
            rows[index] = .work(turn: turn, steps: steps, duration: duration, expanded: true)
        }
        // Always last, below messages sent while the agent works; it stands
        // still while the agent waits for an answer.
        let open = snapshot.turns?.last { $0.completedAt == nil }
        if snapshot.status == .working || snapshot.status == .waiting && open != nil {
            rows.append(.working(turn: open))
        }
        return rows
    }

    /// A finished turn that changed files ends with them.
    private static func appendChanges(_ turn: AgentChatTurn?, to rows: inout [TranscriptRow]) {
        guard let turn, turn.completedAt != nil, let checkpoint = turn.checkpoint, checkpoint.totalFiles > 0 else { return }
        rows.append(.changes(turn: turn.userItemID, checkpoint: checkpoint))
    }

    /// The prompt that started the turn holding `item`, when `item` is one of its steps.
    public static func turn(holding item: String, in snapshot: AgentChatSnapshot?) -> String? {
        var turn: String?
        for candidate in snapshot?.items ?? [] {
            if candidate.kind == .user { turn = candidate.id }
            if candidate.id == item { return candidate.kind == .user ? nil : turn }
        }
        return nil
    }

    private static func row(for item: AgentChatItem) -> TranscriptRow? {
        switch item.kind {
        case .user: return .user(item)
        case .assistant: return item.text.isEmpty ? nil : .assistant(item)
        // Answered approvals, automatic ones included, leave the transcript, as on the desktop.
        // A question is answered in its form above the composer, not here.
        case .approval: return item.isComplete || item.questionnaire != nil ? nil : .approval(item)
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
