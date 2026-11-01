import AppKit

/// A display equation (`$$…$$`, `\[…\]` or a math fence), centered in the column and scrolled
/// horizontally when wider. The equation view is reused in place as the LaTeX streams or the
/// theme changes; "Copy LaTeX" is in its context menu.
@MainActor
final class AgentResponseMath: AgentResponseSection {
    override var kind: Int { 6 }
    let equation = AgentMathView(frame: .zero)
    /// Space above and below the equation, inside the section.
    static let padding: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        equation.translatesAutoresizingMaskIntoConstraints = true
        addSubview(equation)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The LaTeX source shown.
    var latex: String { equation.latex }

    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard case .math(let latex) = part else { return }
        let size = ((compactProse ? 12 : 14) * AgentMarkdownMath.relativeSize).rounded()
        equation.set(latex: latex, fontSize: size, color: AgentMarkdownPalette(theme: theme).body, errorColor: theme.danger)
    }

    override func height(for width: CGFloat) -> CGFloat {
        ceil(max(0, equation.intrinsicContentSize.height)) + Self.padding * 2
    }

    override func layoutSection(width: CGFloat) {
        equation.frame = NSRect(x: 0, y: Self.padding, width: width, height: max(0, bounds.height - Self.padding * 2))
    }
}
