import AppKit
import TabProtocol

/// The source renderer's typed web_search inspector: patterns, then title/link and snippet result rows.
@MainActor
final class AgentWebSearchPanel: NSView, NSTextViewDelegate {
    override var isFlipped: Bool { true }
    private let patterns = AgentRichTextView(frame: .zero)
    private var results: [AgentRichTextView] = []
    private weak var hoveredResult: AgentRichTextView?
    var onOpenURL: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(patterns)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func safeURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value.hasPrefix("//") ? "https:" + value : value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return nil }
        return url
    }

    static func queryPatterns(_ activity: AgentToolActivity) -> [String] {
        if let patterns = activity.searchPatterns { return patterns }
        guard let input = activity.input, !input.isEmpty else { return [] }
        guard let value = AgentToolJSON.parse(input) else { return [input] }
        if case .object = value {
            if value["type"]?.string == "search" {
                let queries: [String]
                if case .array(let values) = value["queries"] { queries = values.compactMap(\.string) } else { queries = [] }
                return (queries + [value["query"]?.string].compactMap { $0 }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            if value["type"]?.string == "findInPage" { return ["pattern", "url"].compactMap { value[$0]?.string } }
            return ["query", "url", "pattern"].compactMap { value[$0]?.string }
        }
        return value.string.map { [$0] } ?? []
    }

    var hasContent: Bool { !patterns.string.isEmpty || !results.isEmpty }

    func update(_ activity: AgentToolActivity, theme: AppTheme) {
        setHoveredResult(nil)
        patterns.setContent(AgentCommandPresentation.text(Self.queryPatterns(activity).joined(separator: "\n"), color: theme.fg.withAlphaComponent(0.85)))
        patterns.isHidden = patterns.string.isEmpty
        let items = activity.webResults ?? []
        while results.count > items.count { results.removeLast().removeFromSuperview() }
        while results.count < items.count {
            let text = AgentRichTextView(frame: .zero)
            text.delegate = self
            text.linkTextAttributes = [:]
            text.setAccessibilityLabel("Search result")
            results.append(text); addSubview(text)
        }
        for (view, item) in zip(results, items) {
            view.setContent(Self.result(item, theme: theme))
            view.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        }
        patterns.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        needsLayout = true
    }

    static func result(_ item: AgentToolActivity.WebResult, theme: AppTheme) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 16; paragraph.maximumLineHeight = 16
        paragraph.lineBreakMode = .byWordWrapping
        let title = collapsedWhitespace(item.title ?? item.url ?? "Search result")
        let font = AppFont.system(12, weight: .medium)
        let result = NSMutableAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: theme.fg, .paragraphStyle: paragraph,
        ])
        if let url = safeURL(item.url) {
            // Four-point flex gap and the pinned 12px external-link glyph.
            let spacer = NSTextAttachment()
            spacer.image = NSImage(size: NSSize(width: 4, height: 1), flipped: false) { _ in true }
            spacer.bounds = NSRect(x: 0, y: 0, width: 4, height: 1)
            result.append(NSAttributedString(attachment: spacer))
            let attachment = NSTextAttachment()
            attachment.image = AppIcon.externalLink.image(size: 12, scale: AppIcon.inlineScale, color: theme.fg)?.tiffRepresentation.flatMap(NSImage.init(data:))
            attachment.bounds = NSRect(x: 0, y: -2, width: 12, height: 12)
            result.append(NSAttributedString(attachment: attachment))
            result.addAttribute(.font, value: font, range: NSRange(location: 0, length: result.length))
            result.addAttribute(.link, value: url, range: NSRange(location: 0, length: result.length))
        }
        if let snippet = item.snippet.map(collapsedWhitespace), !snippet.isEmpty {
            result.append(NSAttributedString(string: "\n" + snippet, attributes: [
                .font: AppFont.system(12), .foregroundColor: theme.fgMuted, .paragraphStyle: paragraph,
            ]))
        }
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "[\\t\\n\\f\\r ]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    @discardableResult
    func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var y: CGFloat = 0
        func place(_ view: AgentRichTextView) {
            let rounded = view.height(for: width)
            let height = view.textContainer.flatMap { view.layoutManager?.usedRect(for: $0).maxY } ?? rounded
            if apply { view.frame = NSRect(x: 0, y: y, width: width, height: height) }
            y += height
        }
        if !patterns.isHidden { place(patterns) }
        for (index, view) in results.enumerated() {
            if index > 0 { y += 6 } else if !patterns.isHidden { y += 8 }
            place(view)
        }
        return y
    }
    override func layout() { super.layout(); arrange(width: bounds.width, apply: true) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func setHoveredResult(_ view: AgentRichTextView?) {
        guard hoveredResult !== view else { return }
        if let storage = hoveredResult?.textStorage { storage.removeAttribute(.underlineStyle, range: NSRange(location: 0, length: storage.length)) }
        hoveredResult?.needsDisplay = true
        hoveredResult = view
        if let storage = view?.textStorage {
            let text = storage.string as NSString
            let attachment = text.range(of: "\u{fffc}")
            let length = attachment.location == NSNotFound ? storage.length : attachment.location
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: length))
        }
        view?.needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        for view in results {
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point), let container = view.textContainer, let layout = view.layoutManager,
                  let storage = view.textStorage, storage.length > 0 else { continue }
            let textPoint = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
            let index = layout.characterIndex(for: textPoint, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            var range = NSRange()
            if index < storage.length, storage.attribute(.link, at: index, effectiveRange: &range) != nil {
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                if layout.boundingRect(forGlyphRange: glyphs, in: container).contains(textPoint) { setHoveredResult(view); return }
            }
        }
        setHoveredResult(nil)
    }
    override func mouseExited(with event: NSEvent) { setHoveredResult(nil) }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL, Self.safeURL(url.absoluteString) != nil { onOpenURL?(url) }
        return true
    }
}
