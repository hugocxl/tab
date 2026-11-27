import AppKit

/// Reserves CSS inline-code borders and padding without inserting clipboard characters.
enum AgentInlineCodeLayout {
    static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        // The source renderer's ui-monospace/SF Mono stack resolves to this face on macOS. The
        // system UI monospace face has similar advances but different ascenders.
        // Descriptor weights may use Float precision; compare between named weights.
        let value = weight.rawValue
        let face = value >= (NSFont.Weight.semibold.rawValue + NSFont.Weight.bold.rawValue) / 2 ? "Bold"
            : value >= (NSFont.Weight.medium.rawValue + NSFont.Weight.semibold.rawValue) / 2 ? "Semibold"
            : value >= NSFont.Weight.medium.rawValue / 2 ? "Medium" : "Regular"
        return NSFont(name: "SFMono-" + face, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func inset(font: NSFont) -> CGFloat { 1 + AgentMarkdownLayout.units(font.pointSize * 0.35) }

    static func backgroundRect(x: CGFloat, width: CGFloat, baseline: CGFloat, font: NSFont) -> NSRect {
        let verticalInset = 1 + AgentMarkdownLayout.units(font.pointSize * 0.1)
        let ascent = font.ascender.rounded(), descent = (-font.descender).rounded()
        return NSRect(x: x, y: baseline - ascent - verticalInset, width: max(0, width), height: ascent + descent + verticalInset * 2)
    }

    static func mark(_ text: NSMutableAttributedString) {
        var spans: [NSRange] = []
        text.enumerateAttribute(.agentInlineCodeIdentity, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { spans.append(range) }
        }
        for span in spans {
            guard span.length > 0, let font = text.attribute(.font, at: span.location, effectiveRange: nil) as? NSFont else { continue }
            let first = (text.string as NSString).rangeOfComposedCharacterSequence(at: span.location)
            let last = (text.string as NSString).rangeOfComposedCharacterSequence(at: NSMaxRange(span) - 1)
            text.addAttributes([.agentInlineCodeBoundary: NSValue(range: first), .agentInlineCodeLeading: inset(font: font)], range: first)
            text.addAttributes([.agentInlineCodeBoundary: NSValue(range: last), .agentInlineCodeTrailing: inset(font: font)], range: last)
        }
    }

    static func lineFragment(_ proposed: NSRect, storage: NSAttributedString, at start: Int) -> NSRect {
        guard start < storage.length,
              let paragraph = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle else { return proposed }
        var rect = proposed
        let paragraphRange = (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
        let remaining = NSRange(location: start, length: NSMaxRange(paragraphRange) - start)
        let indent = start == paragraphRange.location ? paragraph.firstLineHeadIndent : paragraph.headIndent
        func width(_ range: NSRange) -> CGFloat {
            guard range.length > 0 else { return 0 }
            var length = min(range.length, 128)
            while true {
                let end = (storage.string as NSString).rangeOfComposedCharacterSequence(at: range.location + length - 1)
                length = min(range.length, NSMaxRange(end) - range.location)
                let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: NSRange(location: range.location, length: length)))
                text.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: text.length))
                let measured = text.size().width + additionalWidth(text) + AgentExternalLinkLayout.additionalWidth(text)
                if measured > rect.width || length == range.length { return measured }
                length = min(range.length, length * 2)
            }
        }
        storage.enumerateAttribute(.agentInlineCodeIdentity, in: remaining) { value, visible, stop in
            guard value != nil, let font = storage.attribute(.font, at: visible.location, effectiveRange: nil) as? NSFont else { return }
            var span = NSRange()
            _ = storage.attribute(.agentInlineCodeIdentity, at: visible.location, longestEffectiveRange: &span, in: NSRange(location: 0, length: storage.length))
            let padding = inset(font: font)
            if visible.location == start, start > span.location {
                rect.origin.x += padding
                rect.size.width = max(1, rect.width - padding)
            }
            let prefix = NSRange(location: start, length: visible.location - start)
            let tab = (storage.string as NSString).range(of: "\t", options: .backwards, range: prefix)
            let prefixWidth: CGFloat
            if tab.location != NSNotFound, let stop = paragraph.tabStops.first {
                prefixWidth = stop.location + width(NSRange(location: NSMaxRange(tab), length: visible.location - NSMaxRange(tab)))
            } else {
                prefixWidth = indent + width(prefix)
            }
            if prefixWidth > rect.width { stop.pointee = true; return }
            if prefixWidth + width(visible) > rect.width, prefixWidth <= rect.width - padding {
                rect.size.width = max(1, rect.width - padding)
                stop.pointee = true
            }
        }
        return rect
    }

    static func visibleGlyphs(_ range: NSRange, manager: NSLayoutManager, storage: NSAttributedString) -> NSRange {
        var characters = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
        let string = storage.string as NSString
        while characters.length > 0, [UInt16(32), 9].contains(string.character(at: NSMaxRange(characters) - 1)) {
            characters.length -= 1
        }
        guard characters.length > 0 else { return range }
        return manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
    }

    static func additionalWidth(_ text: NSAttributedString) -> CGFloat {
        var width: CGFloat = 0
        text.enumerateAttribute(.agentInlineCodeBoundary, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            width += (text.attribute(.agentInlineCodeLeading, at: range.location, effectiveRange: nil) as? CGFloat) ?? 0
            width += (text.attribute(.agentInlineCodeTrailing, at: range.location, effectiveRange: nil) as? CGFloat) ?? 0
        }
        return width
    }
}

extension NSAttributedString.Key {
    static let agentInlineCodeIdentity = NSAttributedString.Key("TabAgentInlineCodeIdentity")
    static let agentInlineCodeBoundary = NSAttributedString.Key("TabAgentInlineCodeBoundary")
    static let agentInlineCodeLeading = NSAttributedString.Key("TabAgentInlineCodeLeading")
    static let agentInlineCodeTrailing = NSAttributedString.Key("TabAgentInlineCodeTrailing")
}
