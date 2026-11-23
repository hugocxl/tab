import AppKit
import TabApp
import TabCore
import TabProtocol

/// The colors and fonts every graph row draws with, made once per theme.
@MainActor
struct GraphStyle {
    static let hues: [AppTheme.IconHue] = [.blue, .purple, .pink, .orange, .teal, .yellow, .red, .green,
                                           .indigo, .cyan, .vermilion, .mint]

    let lanes: [NSColor]
    let fg: NSColor
    let muted: NSColor
    let dim: NSColor
    let panel: NSColor
    let accent: NSColor
    let subject: [NSAttributedString.Key: Any]
    let workInProgress: [NSAttributedString.Key: Any]
    let meta: [NSAttributedString.Key: Any]
    let hash: [NSAttributedString.Key: Any]
    let pillFont = AppFont.system(10, weight: .medium)

    init(theme: AppTheme) {
        lanes = Self.hues.map { hue in
            let hex = theme.iconHex(hue).dropFirst()
            return NSColor(hex: UInt32(hex, radix: 16) ?? 0x808080)
        }
        fg = theme.fg
        muted = theme.fgMuted
        dim = theme.fgDim
        panel = NativeStyle.panel(theme)
        accent = theme.accent
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        subject = [.font: AppFont.small, .foregroundColor: theme.fg, .paragraphStyle: truncating]
        workInProgress = [.font: AppFont.system(12, weight: .medium), .foregroundColor: theme.fgMuted,
                          .paragraphStyle: truncating]
        meta = [.font: AppFont.footnote, .foregroundColor: theme.fgMuted, .paragraphStyle: truncating]
        hash = [.font: AppFont.mono(10), .foregroundColor: theme.fgDim]
    }

    func lane(_ color: UInt16) -> NSColor { lanes[Int(color) % lanes.count] }
}

/// Where lanes sit horizontally, shared by every row so lines meet.
struct GraphGeometry: Equatable {
    static let inset: CGFloat = 10
    static let widestSpacing: CGFloat = 12
    static let narrowestSpacing: CGFloat = 6

    var spacing: CGFloat = widestSpacing
    /// The graph column's width; lanes past it are cut off.
    var width: CGFloat = inset * 2 + widestSpacing

    /// Fits `lanes` lanes into at most `fraction` of `rowWidth`, narrowing
    /// lanes before cutting them off.
    init(lanes: Int, rowWidth: CGFloat, fraction: CGFloat = 0.35) {
        let lanes = max(lanes, 1)
        let available = max(rowWidth * fraction, Self.inset * 2 + Self.widestSpacing) - Self.inset * 2
        spacing = min(Self.widestSpacing, max(Self.narrowestSpacing, (available / CGFloat(lanes)).rounded(.down)))
        width = min(available, CGFloat(lanes) * spacing) + Self.inset * 2
    }

    init() {}

    func x(_ lane: UInt16) -> CGFloat {
        Self.inset + CGFloat(lane) * spacing + spacing / 2
    }
}

/// What one graph row shows.
struct GraphRowContent {
    enum Kind {
        case commit(GitCommit, labels: [GraphRefLabel], isHead: Bool, date: String)
        case workInProgress(changed: Int)
    }

    var kind: Kind
    var row: GraphRow
    var edges: [GraphEdge]
}

/// The table's row: draws its selection in the theme's colors.
final class GitGraphTableRowView: NSTableRowView {
    var selectionColor: NSColor = .clear

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            for view in subviews { view.needsDisplay = true }
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        selectionColor.setFill()
        bounds.fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// One commit of the graph: its lanes and node on the left, then its
/// branch labels and subject over its author, age and short hash.
/// Everything is drawn in `draw(_:)` from values set in `configure`.
final class GitGraphCell: NSView {
    static let rowHeight: CGFloat = 36
    static let identifier = NSUserInterfaceItemIdentifier("graphRow")

    private var content: GraphRowContent?
    private var style: GraphStyle?
    private var geometry = GraphGeometry()

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ content: GraphRowContent, style: GraphStyle, geometry: GraphGeometry) {
        self.content = content
        self.style = style
        self.geometry = geometry
        switch content.kind {
        case .commit(let commit, let labels, _, let date):
            let names = labels.map(\.name).joined(separator: ", ")
            toolTip = [commit.subject, "\(commit.authorName) · \(commit.authorDate.prefix(10)) · \(commit.shortHash)",
                       names].filter { !$0.isEmpty }.joined(separator: "\n")
            setAccessibilityLabel([names, commit.subject, commit.authorName, date].filter { !$0.isEmpty }
                .joined(separator: ", "))
        case .workInProgress(let changed):
            toolTip = nil
            setAccessibilityLabel("Uncommitted changes, \(Self.files(changed))")
        }
        needsDisplay = true
    }

    private static func files(_ count: Int) -> String {
        count == 1 ? "1 changed file" : "\(count) changed files"
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let content, let style, let context = NSGraphicsContext.current?.cgContext else { return }
        let height = bounds.height
        let mid = (height / 2).rounded()
        let nodeX = min(geometry.x(content.row.lane), geometry.width - GraphGeometry.inset)
        let laneColor: NSColor
        if case .workInProgress = content.kind { laneColor = style.muted } else { laneColor = style.lane(content.row.color) }

        // A faint band in the commit's lane color from its node across the row.
        let selected = (superview as? NSTableRowView)?.isSelected ?? false
        laneColor.withAlphaComponent(selected ? 0.12 : 0.045).setFill()
        NSRect(x: nodeX, y: 1, width: bounds.width - nodeX, height: height - 2).fill()

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: geometry.width, height: height))
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for edge in content.edges {
            drawEdge(edge, in: context, style: style, mid: mid, height: height,
                     dashed: edge.kind == .outgoing && { if case .workInProgress = content.kind { return true }; return false }())
        }
        context.restoreGState()

        drawNode(content, at: CGPoint(x: nodeX, y: mid), color: laneColor, style: style, in: context)
        drawText(content, style: style, laneColor: laneColor)
    }

    private func drawEdge(_ edge: GraphEdge, in context: CGContext, style: GraphStyle, mid: CGFloat, height: CGFloat,
                          dashed: Bool) {
        let color = dashed ? style.muted : style.lane(edge.color)
        context.setStrokeColor(color.cgColor)
        context.setLineDash(phase: 0, lengths: dashed ? [2, 3] : [])
        let from = geometry.x(edge.from)
        let to = geometry.x(edge.to)
        let path = CGMutablePath()
        switch edge.kind {
        case .through:
            path.move(to: CGPoint(x: from, y: 0))
            path.addLine(to: CGPoint(x: from, y: height))
        case .incoming:
            // Down the lane, then a rounded turn across into the node.
            path.move(to: CGPoint(x: from, y: 0))
            if from == to {
                path.addLine(to: CGPoint(x: to, y: mid))
            } else {
                let radius = min(mid, abs(to - from), geometry.spacing)
                let direction: CGFloat = to < from ? -1 : 1
                path.addLine(to: CGPoint(x: from, y: mid - radius))
                path.addQuadCurve(to: CGPoint(x: from + direction * radius, y: mid), control: CGPoint(x: from, y: mid))
                path.addLine(to: CGPoint(x: to, y: mid))
            }
        case .outgoing:
            // Across from the node, then a rounded turn down the lane.
            path.move(to: CGPoint(x: from, y: mid))
            if from == to {
                path.addLine(to: CGPoint(x: to, y: height))
            } else {
                let radius = min(height - mid, abs(to - from), geometry.spacing)
                let direction: CGFloat = to < from ? -1 : 1
                path.addLine(to: CGPoint(x: to - direction * radius, y: mid))
                path.addQuadCurve(to: CGPoint(x: to, y: mid + radius), control: CGPoint(x: to, y: mid))
                path.addLine(to: CGPoint(x: to, y: height))
            }
        }
        context.addPath(path)
        context.strokePath()
    }

    private func drawNode(_ content: GraphRowContent, at center: CGPoint, color: NSColor, style: GraphStyle,
                          in context: CGContext) {
        context.setLineDash(phase: 0, lengths: [])
        switch content.kind {
        case .workInProgress:
            let rect = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
            context.setFillColor(style.panel.cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(style.muted.cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [2, 2])
            context.strokeEllipse(in: rect)
        case .commit(let commit, _, let isHead, _):
            if isHead {
                // HEAD: a ring around a dot, so "you are here" stands out.
                let ring = CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)
                context.setFillColor(style.panel.cgColor)
                context.fillEllipse(in: ring.insetBy(dx: -1.5, dy: -1.5))
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(2)
                context.strokeEllipse(in: ring)
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: ring.insetBy(dx: 3, dy: 3))
            } else {
                let radius: CGFloat = commit.parentHashes.count > 1 ? 3 : 4.5
                let dot = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.setFillColor(style.panel.cgColor)
                context.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: dot)
            }
        }
    }

    private func drawText(_ content: GraphRowContent, style: GraphStyle, laneColor: NSColor) {
        let left = geometry.width + 4
        let right = bounds.width - 8
        guard right - left > 24 else { return }
        let topLine = NSRect(x: left, y: 3, width: right - left, height: 16)
        let bottomLine = NSRect(x: left, y: 19, width: right - left, height: 14)
        switch content.kind {
        case .workInProgress(let changed):
            ("// WIP" as NSString).draw(with: topLine, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: style.workInProgress)
            (Self.files(changed) as NSString).draw(with: bottomLine,
                                                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                   attributes: style.meta)
        case .commit(let commit, let labels, _, let date):
            var x = left
            if !labels.isEmpty {
                x = drawLabels(labels, from: x, limit: left + (right - left) * 0.55, y: topLine.minY + 1,
                               style: style, laneColor: laneColor)
            }
            if right - x > 12 {
                (commit.subject as NSString).draw(with: NSRect(x: x, y: topLine.minY, width: right - x, height: topLine.height),
                                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                  attributes: style.subject)
            }
            let hash = commit.shortHash as NSString
            let hashWidth = ceil(hash.size(withAttributes: style.hash).width)
            let showsHash = bottomLine.width - hashWidth > 80
            if showsHash {
                hash.draw(at: NSPoint(x: right - hashWidth, y: bottomLine.minY + 1), withAttributes: style.hash)
            }
            let metaWidth = bottomLine.width - (showsHash ? hashWidth + 8 : 0)
            ("\(commit.authorName) · \(date)" as NSString).draw(
                with: NSRect(x: left, y: bottomLine.minY, width: metaWidth, height: bottomLine.height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: style.meta)
        }
    }

    /// Draws up to two label pills and a "+N" for the rest, returning where
    /// the subject starts.
    private func drawLabels(_ labels: [GraphRefLabel], from start: CGFloat, limit: CGFloat, y: CGFloat,
                            style: GraphStyle, laneColor: NSColor) -> CGFloat {
        let height: CGFloat = 15
        let padding: CGFloat = 5
        var x = start
        let shown = labels.prefix(2)
        for (index, label) in shown.enumerated() {
            let remaining = limit - x
            guard remaining > 30 else { break }
            let rest = labels.count - index - 1
            let reserve: CGFloat = index == shown.count - 1 && rest > 0 ? 26 : 0
            let (fill, stroke, text, weight) = Self.pillColors(label.kind, lane: laneColor, style: style)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: AppFont.system(10, weight: weight), .foregroundColor: text,
                .paragraphStyle: Self.truncatingCenter,
            ]
            let name = label.name as NSString
            let textWidth = ceil(name.size(withAttributes: attributes).width)
            let width = min(textWidth + padding * 2, max(30, remaining - reserve))
            let pill = NSRect(x: x, y: y, width: width, height: height)
            let path = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            if let fill {
                fill.setFill()
                path.fill()
            }
            if let stroke {
                stroke.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            name.draw(with: pill.insetBy(dx: padding, dy: 1.5),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
            x = pill.maxX + 4
        }
        let hidden = labels.count - min(shown.count, labels.count)
        if hidden > 0 {
            let more = "+\(hidden)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: style.pillFont, .foregroundColor: style.muted]
            let width = ceil(more.size(withAttributes: attributes).width)
            more.draw(at: NSPoint(x: x, y: y + 1), withAttributes: attributes)
            x += width + 6
        }
        return x
    }

    private static let truncatingCenter: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }()

    private static func pillColors(_ kind: GraphRefLabel.Kind, lane: NSColor, style: GraphStyle)
        -> (fill: NSColor?, stroke: NSColor?, text: NSColor, weight: NSFont.Weight) {
        switch kind {
        case .current: return (lane.withAlphaComponent(0.32), lane, style.fg, .semibold)
        case .local(let synced): return (lane.withAlphaComponent(0.22), synced ? lane.withAlphaComponent(0.6) : nil, style.fg, .medium)
        case .remote: return (nil, lane.withAlphaComponent(0.55), style.muted, .medium)
        case .tag: return (style.fg.withAlphaComponent(0.08), nil, style.muted, .medium)
        case .head: return (style.accent.withAlphaComponent(0.25), style.accent, style.fg, .semibold)
        }
    }
}
