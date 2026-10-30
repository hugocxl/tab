import AppKit
import TabProtocol

/// A thin strip on a panel edge that resizes the panel by dragging,
/// reporting the pointer's travel since the drag began.
final class EdgeResizeHandle: ThemedView {
    enum Edge { case top, leading }

    let edge: Edge
    var onBegin: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var start: NSPoint?
    private var hovered = false

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: edge == .top ? .resizeUpDown : .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(start != nil) }

    private func setHovered(_ value: Bool) {
        guard value != hovered else { return }
        hovered = value
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        theme.accent.setFill()
        switch edge {
        case .top: NSRect(x: 0, y: (bounds.height / 2).rounded(.down), width: bounds.width, height: 1).fill()
        case .leading: NSRect(x: (bounds.width / 2).rounded(.down), y: 0, width: 1, height: bounds.height).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let now = NSEvent.mouseLocation
        // Screen coordinates grow upward: dragging the top edge up or the
        // leading edge left makes the panel bigger.
        onDrag?(edge == .top ? now.y - start.y : start.x - now.x)
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        setHovered(bounds.contains(convert(event.locationInWindow, from: nil)))
        onEnd?()
    }
}

/// A 7pt dot: filled for needs input and completed, a ring for idle.
final class AgentStatusDot: ThemedView {
    var status: AgentStatus { didSet { needsDisplay = true } }

    init(status: AgentStatus) {
        self.status = status
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }

    override func draw(_ dirtyRect: NSRect) {
        let color = AgentStatusStyle.color(status, theme: theme)
        let side = min(7, bounds.width, bounds.height)
        let rect = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        if status == .idle {
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            color.setStroke()
            ring.lineWidth = 1
            ring.stroke()
        } else {
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}

@MainActor
enum AgentStatusStyle {
    static func color(_ status: AgentStatus, theme: AppTheme) -> NSColor {
        switch status {
        case .blocked: return theme.warning
        case .working, .completed: return theme.accent
        case .idle: return theme.fgDim
        }
    }

    /// A spinner while working, else the status dot, in a 16pt slot.
    static func glyph(_ status: AgentStatus) -> NSView {
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        let glyph: NSView = status == .working ? Spinner(size: .mini) : AgentStatusDot(status: status)
        slot.addSubview(glyph)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: Metrics.glyph),
            slot.heightAnchor.constraint(equalToConstant: Metrics.glyph),
            glyph.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: status == .working ? 12 : 7),
            glyph.heightAnchor.constraint(equalToConstant: status == .working ? 12 : 7),
        ])
        return slot
    }

    /// An agent's logo, 14pt, tinted for the template ones.
    static func logo(_ provider: AgentProvider, theme: AppTheme) -> NSView {
        let view = NSImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.image = AgentLogo.image(for: provider, lightBackground: theme.palette.isLight)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = theme.fgMuted
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 14),
            view.heightAnchor.constraint(equalToConstant: 14),
        ])
        return view
    }
}

/// A micro uppercase heading over a group of rows.
final class AgentsSectionLabel: ThemedView {
    private let label: NSTextField

    init(_ title: String) {
        label = makeLabel(title.uppercased(), font: AppFont.micro)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.gutter),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.gutter),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.gutter),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func themeDidChange() {
        label.textColor = theme.fgDim
    }
}

/// A row with a leading glyph, a title and an optional detail line; hover,
/// active and keyboard-selected fills.
final class AgentsPanelRow: HoverView {
    var isActive = false { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField

    init(leading: NSView, title: String, detail: String?, tooltip: String? = nil) {
        titleLabel = makeLabel(title, font: AppFont.body)
        detailLabel = makeLabel(detail ?? "", font: AppFont.footnote)
        detailLabel.isHidden = detail?.isEmpty ?? true
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tooltip
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [leading, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.controlGap
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pinEdges(to: self, insets: NSEdgeInsets(top: 5, left: Metrics.gutter, bottom: 5, right: Metrics.gutter))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func themeDidChange() {
        titleLabel.textColor = theme.fg
        detailLabel.textColor = theme.fgMuted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor?
        if isSelected || isHovered {
            fill = theme.hover
        } else if isActive {
            fill = theme.surface
        } else {
            fill = nil
        }
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
