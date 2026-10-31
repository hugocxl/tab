import AppKit
import TabProtocol

/// The source renderer's completed-work disclosure keeps the final answer outside the work log.
@MainActor
final class AgentCompletedWorkRow: AgentTimelineRow {
    var turn: AgentChatTurn?
    private var expanded = false
    private let disclosure = PillButton("", style: .plain)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosure.translatesAutoresizingMaskIntoConstraints = true
        disclosure.alignment = .left
        disclosure.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        addSubview(disclosure)
        disclosure.onPress = { [weak self] in
            guard let self else { return }
            self.expanded.toggle()
            self.updateDisclosure()
            self.onDisclosure?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func update(_ items: [AgentChatItem]) { updateDisclosure() }

    private func updateDisclosure() {
        var label = "Completed work"
        if let turn, let end = turn.completedAt {
            let seconds = max(0, Int(end.timeIntervalSince(turn.startedAt)))
            let duration = seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
            label = "Worked for \(duration)"
            if turn.status == .failed { label += " · Failed" }
        }
        let title = NSMutableAttributedString(string: label, attributes: [
            .font: disclosure.font ?? AppFont.small,
            .foregroundColor: theme.fgDim,
        ])
        let gap = NSTextAttachment()
        gap.bounds = NSRect(x: 0, y: 0, width: 4, height: 1)
        title.append(NSAttributedString(attachment: gap))
        let arrow = NSTextAttachment()
        let icon = (expanded ? AgentConversationIcon.chevronDown : .chevronRight).image(size: 14, color: theme.fgDim)
        arrow.image = icon?.tiffRepresentation.flatMap(NSImage.init(data:))
        arrow.bounds = NSRect(x: 0, y: -2, width: 14, height: 14)
        title.append(NSAttributedString(attachment: arrow))
        title.addAttribute(.foregroundColor, value: theme.fgDim, range: NSRange(location: 0, length: title.length))
        disclosure.attributedTitle = title
        disclosure.contentTintColor = theme.fgDim
        disclosure.setAccessibilityLabel((expanded ? "Collapse " : "Expand ") + label)
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat { 37 }

    override func layoutRow(width: CGFloat) {
        disclosure.frame = NSRect(x: -8, y: 4, width: min(width, ceil(disclosure.cell?.cellSize.width ?? 180)), height: 23)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        theme.fg.withAlphaComponent(0.1).setFill()
        NSRect(x: 0, y: 36, width: bounds.width, height: 1).fill()
    }

    override func themeDidChange() { updateDisclosure() }

    override func captureState() -> AgentTimelineRowState { AgentTimelineRowState(expanded: expanded) }

    override func restoreState(_ state: AgentTimelineRowState) {
        expanded = state.expanded
        updateDisclosure()
    }
}
