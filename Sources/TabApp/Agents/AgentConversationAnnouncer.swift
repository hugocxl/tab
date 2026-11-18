import AppKit
import TabProtocol

/// Tells VoiceOver when a conversation needs the user or its turn ends, while the
/// keyboard stays in the pane's composer or transcript: an approval or question to
/// answer, a failed turn, and a finished one. Each transition is spoken once, keyed by
/// the item or turn it belongs to, so snapshots that repeat it after a refresh or a
/// reconnect stay quiet. The first snapshot a pane sees only sets what is known, so
/// opening or returning to a pane replays nothing. Streaming text and timers never
/// speak; neither does a pane without the keyboard, whose transitions are marked heard.
@MainActor
final class AgentConversationAnnouncer {
    /// Speaks `text` for `element`; tests replace it.
    var post: (String, NSView) -> Void = { text, element in
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    /// Whether the keyboard is in the pane's conversation; tests replace it.
    var hasKeyboard: (AgentPaneView) -> Bool = { $0.conversationHasKeyboard }
    private var heard: Set<String> = []
    private var order: [String] = []
    private var primed = false
    /// How many transitions are remembered; older ones can't repeat once their items left.
    static let capacity = 512

    /// The transitions `snapshot` shows, each with what VoiceOver says.
    static func transitions(_ snapshot: AgentChatSnapshot) -> [(key: String, text: String)] {
        var result: [(String, String)] = []
        for item in snapshot.items where item.kind == .approval && !item.isComplete {
            let text = item.questionnaire != nil ? "The agent has a question for you."
                : "The agent needs your approval: " + String(item.text.prefix(160))
            result.append(("approval:" + item.id, text))
        }
        let failure = snapshot.items.last { $0.kind == .notice && $0.workContext?.itemType == "error" }
        if let turns = snapshot.turns, !turns.isEmpty {
            for turn in turns.suffix(4) where turn.completedAt != nil {
                switch turn.outcome {
                case .failed?:
                    result.append(("failed:" + turn.userItemID, failureText(failure)))
                case .completed?:
                    result.append(("done:" + turn.userItemID, "The agent finished."))
                default: break
                }
            }
        } else if snapshot.status == .failed, let failure {
            // A server that predates turns still marks the failure with an error notice.
            result.append(("failed:" + failure.id, failureText(failure)))
        }
        return result
    }

    private static func failureText(_ notice: AgentChatItem?) -> String {
        guard let notice, !notice.text.isEmpty else { return "The agent's turn failed." }
        return "The agent's turn failed: " + String(notice.text.prefix(160))
    }

    /// Takes the conversation `pane` shows. While the keyboard is elsewhere, what happened
    /// is marked heard without a word.
    func observe(_ snapshot: AgentChatSnapshot, in pane: AgentPaneView) {
        let transitions = Self.transitions(snapshot)
        defer { primed = true }
        guard transitions.contains(where: { !heard.contains($0.key) }) else { return }
        let speaking = primed && hasKeyboard(pane)
        for (key, text) in transitions where !heard.contains(key) {
            remember(key)
            if speaking { post(text, pane) }
        }
    }

    private func remember(_ key: String) {
        heard.insert(key)
        order.append(key)
        if order.count > Self.capacity { heard.remove(order.removeFirst()) }
    }
}

extension AgentPaneView {
    /// Whether the keyboard is in this pane's composer or transcript, in the key window.
    var conversationHasKeyboard: Bool { window?.isKeyWindow == true && keyboardInConversation }

    /// Whether this pane's composer or transcript is its window's first responder.
    var keyboardInConversation: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === composer || responder.isDescendant(of: transcriptScroll)
    }
}
