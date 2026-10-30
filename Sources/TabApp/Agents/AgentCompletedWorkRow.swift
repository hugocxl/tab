import AppKit
import TabProtocol

/// T3's completed-work disclosure keeps the final answer outside the work log.
@MainActor
final class AgentCompletedWorkRow: AgentTimelineRow {
    var turn: AgentChatTurn?
    private var expanded = false
    private let disclosure = PillButton("", style: .plain)
    private let document = AgentTranscriptDocument(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private var items: [AgentChatItem] = []
    private var savedChildren: [String: AgentTimelineRowState] = [:]
    private var savedOffset: NSPoint = .zero
    private var loaded = false
    private var reflowing = false
    private var boundsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosure.translatesAutoresizingMaskIntoConstraints = true
        disclosure.alignment = .left
        disclosure.font = AppFont.small
        document.isNested = true
        addSubview(disclosure)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateViewport() }
        }
        document.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
        document.onDisclosure = { [weak self] in self?.onDisclosure?() }
        document.onApproval = { [weak self] id, allow in self?.onApproval?(id, allow) }
        disclosure.onPress = { [weak self] in
            guard let self else { return }
            self.expanded.toggle()
            if self.expanded { self.load() }
            else { self.unload() }
            self.updateDisclosure()
            self.onDisclosure?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    override func update(_ items: [AgentChatItem]) {
        self.items = items
        if expanded { load() }
        updateDisclosure()
    }

    private func load() {
        document.update(items, omittedCount: 0)
        if !loaded { document.rowStates = savedChildren }
        loaded = true
    }

    private func unload() {
        guard loaded else { return }
        savedChildren = document.rowStates
        savedOffset = scroll.contentView.bounds.origin
        document.update([], omittedCount: 0)
        loaded = false
    }

    private func updateViewport() {
        guard expanded, !reflowing else { return }
        reflowing = true
        defer { reflowing = false }
        document.updateViewport(scroll.contentView.bounds, followingEnd: false)
    }

    private func updateDisclosure() {
        var label = "Completed work"
        if let turn, let end = turn.completedAt {
            let seconds = max(0, Int(end.timeIntervalSince(turn.startedAt)))
            let duration = seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
            label = "Worked for \(duration)"
            if turn.status == .failed { label += " · Failed" }
        }
        disclosure.title = (expanded ? "⌄  " : "›  ") + label
        disclosure.setTitleColor(theme.fgDim)
        disclosure.setAccessibilityLabel((expanded ? "Collapse " : "Expand ") + label)
        scroll.isHidden = !expanded
    }

    override func preferredHeight(for width: CGFloat) -> CGFloat {
        guard expanded else { return 24 }
        reflowing = true
        defer { reflowing = false }
        document.reflow(viewportWidth: max(1, width - 16))
        document.updateViewport(NSRect(x: 0, y: scroll.contentView.bounds.minY,
                                       width: max(1, width - 16), height: 360), followingEnd: false)
        return 36 + min(360, document.frame.height)
    }

    override func layoutRow(width: CGFloat) {
        disclosure.frame = NSRect(x: -4, y: 0, width: width + 4, height: 24)
        scroll.frame = NSRect(x: 16, y: 36, width: max(1, width - 16), height: max(0, bounds.height - 36))
        if savedOffset != .zero {
            scroll.contentView.scroll(to: savedOffset)
            savedOffset = .zero
        }
        updateViewport()
    }

    override func setApprovalsEnabled(_ enabled: Bool) { document.setApprovalsEnabled(enabled) }

    override func themeDidChange() {
        document.theme = theme
        document.themeDidChange()
        updateDisclosure()
    }

    override func captureState() -> AgentTimelineRowState {
        AgentTimelineRowState(expanded: expanded, children: loaded ? document.rowStates : savedChildren,
                              scrollOffset: loaded ? scroll.contentView.bounds.origin : savedOffset)
    }

    override func restoreState(_ state: AgentTimelineRowState) {
        expanded = state.expanded
        savedChildren = state.children
        savedOffset = state.scrollOffset
        if expanded {
            load()
            document.rowStates = savedChildren
        } else { unload() }
        updateDisclosure()
    }
}
