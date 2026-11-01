import AppKit

/// One display-mode equation. It is as tall as the equation, centers it when
/// there is room, and scrolls horizontally when it is wider than its bounds.
final class AgentMathView: NSView {
    private struct Content: Equatable {
        var latex: String
        var fontSize: CGFloat
        var color: NSColor
        var errorColor: NSColor
    }

    private let scrollView = AgentMathScrollView()
    private let canvas = AgentMathCanvasView()
    private var content: Content?

    /// The LaTeX source currently shown.
    var latex: String { content?.latex ?? "" }

    /// The typeset equation, or nil before the first `set`.
    var result: AgentMathTypesetter.Result? { canvas.result }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = canvas
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        canvas.copyLatex = { [weak self] in self?.copyLatex() }
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    /// Shows `latex`; does nothing when nothing changed, so streaming updates stay cheap.
    func set(latex: String, fontSize: CGFloat, color: NSColor, errorColor: NSColor) {
        let next = Content(latex: latex, fontSize: fontSize, color: color, errorColor: errorColor)
        guard next != content else { return }
        content = next
        let options = AgentMathTypesetter.Options(
            displayMode: true, fontSize: fontSize, color: color, errorColor: errorColor
        )
        canvas.result = AgentMathTypesetter.typeset(latex, options: options)
        setAccessibilityLabel(latex)
        invalidateIntrinsicContentSize()
        needsLayout = true
        canvas.needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        guard let size = canvas.result?.size else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
        return size
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let size = canvas.result?.size ?? .zero
        let width = max(size.width, scrollView.contentSize.width)
        let frame = NSRect(x: 0, y: 0, width: width, height: max(size.height, bounds.height))
        if canvas.frame != frame { canvas.frame = frame }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        canvas.menu(for: event)
    }

    @objc func copyLatex() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(latex, forType: .string)
    }
}

/// Lets vertical scrolling pass through to the conversation; keeps horizontal scrolling.
private final class AgentMathScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let fits = (documentView?.frame.width ?? 0) <= contentSize.width + 0.5
        if fits || abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}

private final class AgentMathCanvasView: NSView {
    var result: AgentMathTypesetter.Result?
    var copyLatex: (() -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let result, let context = NSGraphicsContext.current?.cgContext else { return }
        let x = max(0, ((bounds.width - result.size.width) / 2).rounded())
        let y = max(0, ((bounds.height - result.size.height) / 2).rounded())
        context.saveGState()
        context.translateBy(x: x, y: y)
        result.draw(context)
        context.restoreGState()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy LaTeX", action: #selector(copyItem), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func copyItem() {
        copyLatex?()
    }
}
