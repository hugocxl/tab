import UIKit

/// Renders an agent's Markdown into attributed text for a `UITextView`:
/// headings, paragraphs, lists, quotes, code blocks, emphasis, inline code,
/// strikethrough and links, sized with Dynamic Type.
enum MarkdownRenderer {
    static func render(_ markdown: String, textColor: UIColor = .label) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: bodyFont, .foregroundColor: textColor])
        }
        let output = NSMutableAttributedString()
        var previousBlock: Int?
        var previousWasCode = false
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let isCode = components.contains { if case .codeBlock = $0.kind { return true } else { return false } }
            if let previousBlock, block != previousBlock {
                output.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                if previousWasCode != isCode || isCode {
                    output.append(NSAttributedString(string: "\n", attributes: [.font: smallFont]))
                }
            }
            if block != previousBlock, let prefix = listPrefix(components) {
                output.append(NSAttributedString(string: prefix, attributes: [
                    .font: bodyFont, .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: paragraph(components),
                ]))
            }
            previousBlock = block
            previousWasCode = isCode

            var text = String(parsed[run.range].characters)
            if isCode, text.hasSuffix("\n") { text.removeLast() }
            output.append(NSAttributedString(string: text, attributes: attributes(run, components: components,
                                                                                  textColor: textColor)))
        }
        return output
    }

    private static var bodyFont: UIFont { UIFont.preferredFont(forTextStyle: .body) }
    private static var smallFont: UIFont { UIFont.systemFont(ofSize: 6) }

    private static func attributes(_ run: AttributedString.Runs.Run, components: [PresentationIntent.IntentType],
                                   textColor: UIColor) -> [NSAttributedString.Key: Any] {
        var font = bodyFont
        var color = textColor
        var attributes: [NSAttributedString.Key: Any] = [:]
        for component in components {
            switch component.kind {
            case .header(let level):
                let style: UIFont.TextStyle = level == 1 ? .title2 : level == 2 ? .title3 : .headline
                font = UIFont.preferredFont(forTextStyle: style).withTraits(.traitBold)
            case .codeBlock:
                font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 14, weight: .regular))
                attributes[.backgroundColor] = UIColor.secondarySystemFill
            case .blockQuote:
                color = .secondaryLabel
            default:
                break
            }
        }
        if let inline = run.inlinePresentationIntent {
            if inline.contains(.code) {
                font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
                attributes[.backgroundColor] = UIColor.tertiarySystemFill
            }
            if inline.contains(.stronglyEmphasized) { font = font.withTraits(.traitBold) }
            if inline.contains(.emphasized) { font = font.withTraits(.traitItalic) }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        }
        if let link = run.link { attributes[.link] = link }
        attributes[.font] = font
        attributes[.foregroundColor] = color
        attributes[.paragraphStyle] = paragraph(components)
        return attributes
    }

    /// "• " or "3. " at the start of a list item, nested lists indented.
    private static func listPrefix(_ components: [PresentationIntent.IntentType]) -> String? {
        guard let itemIndex = components.firstIndex(where: {
            if case .listItem = $0.kind { return true } else { return false }
        }), case .listItem(let ordinal) = components[itemIndex].kind else { return nil }
        // Only the item's first paragraph gets the marker.
        guard components.prefix(itemIndex).allSatisfy({ if case .paragraph = $0.kind { return true } else { return false } }) else {
            return nil
        }
        let ordered = components.dropFirst(itemIndex + 1).first.map {
            if case .orderedList = $0.kind { return true } else { return false }
        } ?? false
        return ordered ? "\(ordinal).\t" : "•\t"
    }

    private static func paragraph(_ components: [PresentationIntent.IntentType]) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let depth = components.filter {
            switch $0.kind {
            case .orderedList, .unorderedList: true
            default: false
            }
        }.count
        let quote = components.contains { if case .blockQuote = $0.kind { return true } else { return false } }
        let indent = CGFloat(max(0, depth - 1)) * 22 + (quote ? 14 : 0)
        // The marker sits at the indent; text, wrapped lines too, starts at the tab stop.
        let text = indent + (depth > 0 ? 22 : 0)
        style.firstLineHeadIndent = indent
        style.headIndent = text
        style.tabStops = [NSTextTab(textAlignment: .natural, location: text)]
        style.defaultTabInterval = 22
        style.paragraphSpacing = 4
        style.lineHeightMultiple = 1.05
        return style
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
