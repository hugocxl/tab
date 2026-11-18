import AppKit
import TabProtocol

/// What an approval card says, from the request the provider sent.
enum AgentApprovalPresentation {
    /// The card's lines below its title: the provider's reason, what it asks for, and
    /// which agent asked when it isn't the conversation's own.
    static func details(_ request: AgentApprovalRequest) -> String {
        var lines: [String] = []
        if let origin = request.origin, origin.isChild {
            lines.append("Asked by agent: " + (origin.childTitle ?? origin.childAgentID ?? "a subagent"))
        }
        if let summary = request.summary, !summary.isEmpty { lines.append(summary) }
        for field in request.requested { lines.append(field.label + ": " + field.value) }
        if let outcome = request.outcome {
            switch outcome.source {
            case .user: lines.append("Chose: " + outcome.title)
            case .automatic: lines.append("Answered automatically: " + outcome.title)
            case .provider: lines.append(outcome.title)
            default: lines.append(outcome.title)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The card's heading while it waits.
    static func pendingTitle(_ request: AgentApprovalRequest?) -> String {
        guard let request else { return "Approval needed" }
        if let origin = request.origin, origin.isChild {
            return "Approval needed · " + (origin.childTitle.map { "agent “\($0)”" } ?? "a subagent")
        }
        return request.kind == "elicitation" ? "Response needed" : "Approval needed"
    }

    /// The decision a keyboard shortcut stands for: Allow is only a one-time approval and
    /// Deny only a plain decline, so a shortcut never sends a broader or harsher answer.
    static func shortcutDecision(_ request: AgentApprovalRequest, allow: Bool) -> AgentApprovalDecision? {
        request.first(allow ? .allowOnce : .decline)
    }
}

/// The decisions a provider offered, as buttons in its order, wrapping when narrow.
@MainActor
final class AgentApprovalDecisionBar: NSView {
    var onDecision: ((String) -> Void)?
    private(set) var buttons: [PillButton] = []
    private var decisions: [AgentApprovalDecision] = []
    private static let height: CGFloat = 26
    private static let spacing: CGFloat = 8

    override var isFlipped: Bool { true }

    func update(_ decisions: [AgentApprovalDecision], theme: AppTheme) {
        if decisions != self.decisions {
            self.decisions = decisions
            buttons.forEach { $0.removeFromSuperview() }
            buttons = decisions.map { decision in
                let allows = decision.kind.allows
                let button = PillButton(decision.title, style: allows && decision.kind != .allowAlways && decision.kind != .allowForSession ? .primary : .normal)
                button.toolTip = decision.consequence
                button.setAccessibilityHelp(decision.consequence)
                button.translatesAutoresizingMaskIntoConstraints = true
                button.onPress = { [weak self] in self?.onDecision?(decision.id) }
                addSubview(button)
                return button
            }
            needsLayout = true
        }
        for (button, decision) in zip(buttons, decisions) where decision.kind == .cancel {
            button.setTitleColor(theme.danger)
        }
    }

    var isEnabled = true { didSet { buttons.forEach { $0.isEnabled = isEnabled } } }

    func height(for width: CGFloat) -> CGFloat {
        CGFloat(place(width: width, apply: false)) * (Self.height + 6) - 6
    }

    override func layout() {
        super.layout()
        _ = place(width: bounds.width, apply: true)
    }

    /// Positions the buttons in rows; returns how many rows they need.
    private func place(width: CGFloat, apply: Bool) -> Int {
        guard !buttons.isEmpty else { return 0 }
        var x: CGFloat = 0, row = 0
        for button in buttons {
            let size = min(max(1, width), ceil(button.fittingSize.width) + 12)
            if x > 0, x + size > width { x = 0; row += 1 }
            if apply { button.frame = NSRect(x: x, y: CGFloat(row) * (Self.height + 6), width: size, height: Self.height) }
            x += size + Self.spacing
        }
        return row + 1
    }
}

/// How the Continue Conversation list describes a closed Tab conversation.
enum AgentSavedConversationText {
    static func detail(_ conversation: AgentSavedConversation, formatter: RelativeDateTimeFormatter, now: Date = Date()) -> String {
        var parts = [(conversation.archived ? "Cleared in Tab" : "Closed in Tab") + " · " + conversation.provider.name]
        if let date = conversation.closedAt ?? conversation.updatedAt { parts.append(formatter.localizedString(for: date, relativeTo: now)) }
        if let expires = conversation.expiresAt {
            parts.append("Deleted " + formatter.localizedString(for: expires, relativeTo: now))
        } else {
            parts.append(conversation.retention.title)
        }
        if conversation.needsReview == true { parts.append("Prompts need review") }
        return parts.joined(separator: " · ")
    }
}

extension AgentPaneController {
    /// A usage-limit stop says when the limit resets and offers Resume at Reset; a retry
    /// the server holds for then shows its time, and Retry sends it now.
    func updateRateLimitControls(blocked: String?) {
        let scheduled = snapshot?.scheduledRetry
        let limit = rateLimitStop
        let resets = limit?.resetsAt
        let showsRetry = !surface.retryTurn.isHidden
        surface.resumeAtReset.isHidden = !showsRetry || (scheduled == nil && (resets.map { $0 <= Date() } ?? true))
        surface.resumeAtReset.isEnabled = surface.retryTurn.isEnabled || scheduled != nil
        if let scheduled, let at = scheduled.scheduledAt {
            surface.resumeAtReset.title = "Cancel Resume"
            surface.resumeAtReset.toolTip = "Don't send the prompt when the limit resets"
            surface.retryTurn.title = "Retry Now"
            surface.retryTurn.isEnabled = true
            surface.retryTurn.toolTip = "Send the scheduled prompt now"
            if showsRetry { surface.feedback.stringValue = "Usage limit reached. The prompt is sent again " + AgentTurnTime.moment(at) + "." }
        } else {
            surface.resumeAtReset.title = "Resume at Reset"
            surface.resumeAtReset.toolTip = resets.map { "Send the prompt again when the limit resets, " + AgentTurnTime.moment($0) }
            surface.retryTurn.title = "Retry"
            if showsRetry, let limit, blocked == nil {
                surface.feedback.stringValue = (limit.message ?? "Usage limit reached") + "."
                    + (resets.map { " Resets " + AgentTurnTime.moment($0) + "." } ?? " The provider didn't say when it resets.")
            }
        }
        surface.feedback.toolTip = surface.feedback.stringValue
        surface.feedback.setAccessibilityValue(surface.feedback.stringValue)
    }
}
