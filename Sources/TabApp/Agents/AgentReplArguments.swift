import AppKit
import TabProtocol

/// source gives recognized JavaScript REPL `code` arguments their own preformatted
/// block and scroll container; other keys stay in the surrounding argument list.
@MainActor
final class AgentReplArguments: NSView {
    override var isFlipped: Bool { true }
    private let before = AgentRichTextView(frame: .zero)
    private let label = AgentRichTextView(frame: .zero)
    private let code = AgentRichTextView(frame: .zero)
    private let after = AgentRichTextView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private var restoredPosition: NSPoint?
    var scrollPosition: NSPoint { restoredPosition ?? scroll.contentView.bounds.origin }
    func restoreScrollPosition(_ position: NSPoint) { restoredPosition = position }

    static func accepts(_ activity: AgentToolActivity?) -> Bool {
        guard let activity, ["js", "cua_repl.js", "node_repl.js"].contains(activity.name ?? ""),
              let input = activity.input, !AgentToolPresentation.argumentsNeedScroll(input),
              let value = AgentToolJSON.parse(input) else { return false }
        return value["code"] != nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = code
        for view in [before, label, scroll, after] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ activity: AgentToolActivity, theme: AppTheme) {
        guard let input = activity.input, case .object(let entries) = AgentToolJSON.parse(input),
              let index = entries.firstIndex(where: { $0.0 == "code" }) else { return }
        func section(_ entries: ArraySlice<(String, AgentToolJSON)>) -> NSAttributedString {
            AgentToolPresentation.arguments(AgentToolJSON.object(Array(entries)).encoded(), theme: theme)
        }
        before.setContent(section(entries[..<index]))
        after.setContent(section(entries[(index + 1)...]))
        label.setContent(AgentCommandPresentation.text("code ", color: theme.fgMuted))
        let value = entries[index].1
        let source = value.string.flatMap { $0.isEmpty ? nil : $0 } ?? value.encoded()
        let content = AgentCommandPresentation.text(source, color: theme.fgMuted)
        for token in SyntaxHighlighter.highlight(source, language: .typeScript) where NSMaxRange(token.range) <= content.length {
            if let color = theme.syntaxColors.attributes(token.kind, font: AppFont.mono(13))[.foregroundColor] {
                content.addAttribute(.foregroundColor, value: color, range: token.range)
            }
        }
        code.setContent(content)
        for text in [before, label, code, after] { text.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)] }
        needsLayout = true
    }

    @discardableResult
    func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let width = max(1, width)
        var y: CGFloat = 0
        func height(_ text: AgentRichTextView) -> CGFloat {
            guard !text.string.isEmpty else { return 0 }
            _ = text.height(for: width)
            return text.textContainer.flatMap { text.layoutManager?.usedRect(for: $0).maxY } ?? 0
        }
        func place(_ text: AgentRichTextView) {
            let size = height(text)
            if apply { text.frame = NSRect(x: 0, y: y, width: width, height: size) }
            y += size
        }
        place(before); place(label)
        let contentHeight = height(code)
        let viewportHeight = min(320, contentHeight)
        if apply {
            scroll.frame = NSRect(x: 0, y: y, width: width, height: viewportHeight)
            code.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
            if let position = restoredPosition {
                code.scroll(NSPoint(x: 0, y: min(max(0, position.y), max(0, contentHeight - viewportHeight))))
                restoredPosition = nil
            }
        }
        y += viewportHeight
        place(after)
        return y
    }
    override func layout() { super.layout(); arrange(width: bounds.width, apply: true) }
}
