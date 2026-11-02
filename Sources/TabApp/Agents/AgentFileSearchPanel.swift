import AppKit
import TabProtocol

/// The V2 file_search inspector. Provider Grep/Glob calls remain dynamic tools,
/// as in the source; only explicitly typed records use this presentation.
@MainActor
final class AgentFileSearchPanel: NSView, @preconcurrency NSLayoutManagerDelegate {
    override var isFlipped: Bool { true }
    private let pattern = AgentRichTextView(frame: .zero)
    private var results: [(path: AgentRichTextView, preview: AgentRichTextView, icon: NSImageView)] = []
    var hasContent: Bool { !pattern.isHidden || !results.isEmpty }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(pattern)
        pattern.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ details: AgentToolActivity.FileSearchDetails?, root: String?, theme: AppTheme) {
        let query = details?.pattern ?? ""
        pattern.isHidden = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        pattern.setContent(AgentCommandPresentation.text(query, color: theme.fg.withAlphaComponent(0.85)))
        let items = details?.results ?? []
        while results.count > items.count {
            let row = results.removeLast(); row.path.removeFromSuperview(); row.preview.removeFromSuperview(); row.icon.removeFromSuperview()
        }
        while results.count < items.count {
            let row = (path: AgentRichTextView(frame: .zero), preview: AgentRichTextView(frame: .zero), icon: NSImageView())
            row.path.layoutManager?.delegate = self
            results.append(row); addSubview(row.path); addSubview(row.preview); addSubview(row.icon)
            row.icon.setAccessibilityElement(false)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 16; paragraph.maximumLineHeight = 16
        for (row, item) in zip(results, items) {
            row.icon.image = FileIcon.image(for: item.fileName, theme: theme)
            let path = AgentFileChangePanel.displayPath(item.fileName, root: root)
                + (item.line.map { ":\($0)" } ?? "") + (item.column.map { ":\($0)" } ?? "")
            // Path spans use normal HTML whitespace; previews deliberately preserve it.
            let label = path.replacingOccurrences(of: "[\\t\\n\\f\\r ]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " "))
            row.path.setContent(NSAttributedString(string: label, attributes: [
                .font: AppFont.mono(12), .foregroundColor: theme.fg.withAlphaComponent(0.8), .paragraphStyle: paragraph,
            ]))
            row.preview.isHidden = item.preview?.isEmpty != false
            row.preview.setContent(NSAttributedString(string: item.preview ?? "", attributes: [
                .font: AppFont.system(12), .foregroundColor: theme.fgMuted, .paragraphStyle: paragraph,
            ]))
            for text in [row.path, row.preview] { text.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)] }
        }
        pattern.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        needsLayout = true
    }

    @discardableResult
    func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var y: CGFloat = 0
        func place(_ view: AgentRichTextView, x: CGFloat = 0) {
            _ = view.height(for: max(1, width - x))
            let height = view.textContainer.flatMap { view.layoutManager?.usedRect(for: $0).maxY } ?? 0
            if apply { view.frame = NSRect(x: x, y: y, width: max(1, width - x), height: height) }
            y += height
        }
        if !pattern.isHidden { place(pattern) }
        for (index, row) in results.enumerated() {
            if index > 0 { y += 4 } else if !pattern.isHidden { y += 8 }
            if apply { row.icon.frame = NSRect(x: 0, y: y + 1, width: 14, height: 14) }
            place(row.path, x: 20)
            if !row.preview.isHidden { y += 2; place(row.preview, x: 20) }
        }
        return y
    }
    override func layout() { super.layout(); arrange(width: bounds.width, apply: true) }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        guard let text = layoutManager.textStorage?.string as NSString?, charIndex > 0, charIndex <= text.length else { return true }
        return ![47, 92].contains(text.character(at: charIndex - 1))
    }
}
