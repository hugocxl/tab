import AppKit
import TabProtocol

/// A finished turn's work folded into one summary line above its answer; opening it
/// shows the tool calls and messages in place.
@MainActor
final class AgentCompletedWorkRow: AgentTimelineRow {
    var turn: AgentChatTurn?
    private var expanded = false
    private let disclosure = PillButton("", style: .plain)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosure.translatesAutoresizingMaskIntoConstraints = true
        disclosure.alignment = .left
        disclosure.font = AppFont.system(14)
        addSubview(disclosure)
        disclosure.onPress = { [weak self] in
            guard let self else { return }
            self.expanded.toggle()
            self.updateDisclosure()
            self.onDisclosure?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Set when the turn has no answer to show its duration below, so the summary says it.
    var duration: TimeInterval?
    private var toolCount = 0
    private var messageCount = 0
    private var icons: [AgentConversationIcon] = []

    override func update(_ items: [AgentChatItem]) {
        toolCount = items.filter { $0.kind == .tool }.count
        messageCount = items.filter { $0.kind == .assistant }.count
        var icons: [AgentConversationIcon] = []
        for item in items where item.kind == .tool {
            let icon = Self.icon(item.tool?.category)
            if !icons.contains(icon) { icons.append(icon) }
        }
        self.icons = Array(icons.prefix(4))
        updateDisclosure()
    }

    /// `10 tool calls, 4 messages`, naming only what the work holds.
    var summary: String {
        var parts: [String] = []
        if toolCount > 0 { parts.append("\(toolCount) tool call" + (toolCount == 1 ? "" : "s")) }
        if messageCount > 0 { parts.append("\(messageCount) message" + (messageCount == 1 ? "" : "s")) }
        var label = parts.isEmpty ? "Completed work" : parts.joined(separator: ", ")
        if let duration { label += " · " + AgentTurnTime.duration(duration) }
        if turn?.status == .failed { label += " · Failed" }
        return label
    }

    static func icon(_ category: AgentToolActivity.Category?) -> AgentConversationIcon {
        switch category {
        case .command: return .terminal
        case .read: return .eye
        case .search: return .search
        case .edit: return .edit
        case .web: return .globe
        case .subagent: return .bot
        default: return .wrench
        }
    }

    private func updateDisclosure() {
        let label = summary
        let title = NSMutableAttributedString()
        func append(_ icon: AgentConversationIcon, size: CGFloat, gap: CGFloat) {
            let attachment = NSTextAttachment()
            attachment.image = icon.image(size: size, color: theme.fgDim)?.tiffRepresentation.flatMap(NSImage.init(data:))
            attachment.bounds = NSRect(x: 0, y: -2, width: size, height: size)
            title.append(NSAttributedString(attachment: attachment))
            let space = NSTextAttachment()
            space.bounds = NSRect(x: 0, y: 0, width: gap, height: 1)
            title.append(NSAttributedString(attachment: space))
        }
        append(expanded ? .chevronDown : .chevronRight, size: 12, gap: 10)
        title.append(NSAttributedString(string: label))
        if !icons.isEmpty {
            let space = NSTextAttachment()
            space.bounds = NSRect(x: 0, y: 0, width: 10, height: 1)
            title.append(NSAttributedString(attachment: space))
            for icon in icons { append(icon, size: 14, gap: 4) }
        }
        title.addAttributes([.font: disclosure.font ?? AppFont.system(14), .foregroundColor: theme.fgDim],
                           range: NSRange(location: 0, length: title.length))
        disclosure.attributedTitle = title
        disclosure.contentTintColor = theme.fgDim
        disclosure.setAccessibilityLabel((expanded ? "Collapse " : "Expand ") + label)
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat { 30 }

    override func layoutRow(width: CGFloat) {
        disclosure.frame = NSRect(x: -8, y: 3, width: min(width, ceil(disclosure.cell?.cellSize.width ?? 180)), height: 24)
    }

    override func themeDidChange() { updateDisclosure() }

    override func captureState() -> AgentTimelineRowState { AgentTimelineRowState(expanded: expanded) }

    override func restoreState(_ state: AgentTimelineRowState) {
        expanded = state.expanded
        updateDisclosure()
    }
}
