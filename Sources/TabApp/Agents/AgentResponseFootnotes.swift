import AppKit

@MainActor
final class AgentResponseFootnotes: AgentResponseSection {
    override var kind: Int { 4 }
    var isStreaming = false { didSet { bodies.forEach { $0.isStreaming = isStreaming } } }
    var onRunShellCommand: ((String) -> Void)? { didSet { bodies.forEach { $0.onRunShellCommand = onRunShellCommand } } }
    var onOpenFile: ((String, Int?) -> Void)?
    var onOpenFragment: ((String) -> Bool)?
    private var numbers: [AgentRichTextView] = []
    private var bodies: [AgentResponseView] = []
    private var heights: [CGFloat] = []
    private var border = NSColor.separatorColor

    var headingTargets: [AgentMarkdownHeadingTarget] {
        bodies.indices.flatMap { AgentMarkdownHeadingTarget.collect(in: numbers[$0]) + bodies[$0].headingTargets }
    }

    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard case .footnotes(let notes) = part else { return }
        border = AgentMarkdownPalette(theme: theme).border
        while bodies.count > notes.count {
            bodies.removeLast().removeFromSuperview()
            numbers.removeLast().removeFromSuperview()
        }
        while bodies.count < notes.count {
            let body = AgentResponseView(frame: .zero)
            body.compactProse = true
            let number = AgentRichTextView(frame: .zero)
            body.onHeightChanged = { [weak self] in self?.invalidateMeasurement(); self?.onHeightChanged?() }
            body.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
            body.onOpenFragment = { [weak self] id in self?.onOpenFragment?(id) ?? false }
            bodies.append(body); numbers.append(number)
            addSubview(body); addSubview(number)
        }
        for (index, note) in notes.enumerated() {
            let number = NSAttributedString(string: "\(note.number).", attributes: [
                .font: AppFont.system(12), .foregroundColor: AgentMarkdownPalette(theme: theme).muted, .agentMarkdownAnchor: note.id,
            ])
            numbers[index].setContent(number)
            numbers[index].setAccessibilityLabel("Footnote \(note.number)")
            bodies[index].lineBreaks = lineBreaks
            bodies[index].inheritedReferences = references
            bodies[index].setPreparedContent(note.blocks, theme: theme)
        }
        needsDisplay = true
    }

    override func height(for width: CGFloat) -> CGFloat {
        heights = bodies.indices.map { max(numbers[$0].height(for: 22), max(18, bodies[$0].height(for: max(1, width - 24)))) }
        return 13 + heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * AgentMarkdownLayout.compactListGap
    }

    override func layoutSection(width: CGFloat) {
        var y: CGFloat = 13
        for index in bodies.indices where heights.indices.contains(index) {
            numbers[index].frame = NSRect(x: 0, y: y, width: 22, height: 20)
            bodies[index].frame = NSRect(x: 24, y: y, width: max(1, width - 24), height: heights[index])
            bodies[index].layoutSubtreeIfNeeded()
            y += heights[index] + AgentMarkdownLayout.compactListGap
        }
    }

    override func captureState() -> AgentResponseState {
        AgentResponseState(children: Dictionary(uniqueKeysWithValues: bodies.enumerated().map { ($0.offset, $0.element.captureState()) }))
    }

    override func restoreState(_ state: AgentResponseState) {
        for (index, child) in state.children where bodies.indices.contains(index) { bodies[index].restoreState(child) }
        invalidateMeasurement()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
