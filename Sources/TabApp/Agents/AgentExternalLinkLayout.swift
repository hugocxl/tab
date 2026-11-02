import AppKit

/// A presentation-only leading box. The underlying label and selection offsets stay intact.
@MainActor
enum AgentExternalLinkLayout {
    nonisolated static func inset(fontSize: CGFloat) -> CGFloat { 14 + fontSize * 0.45 }

    static func mark(_ text: NSMutableAttributedString, fontSize: CGFloat, color: NSColor, theme: AppTheme) {
        let full = NSRange(location: 0, length: text.length)
        var links: [NSRange] = []
        text.enumerateAttribute(.agentExternalLinkIdentity, in: full) { value, range, _ in
            guard value != nil, range.length > 0,
                  let url = text.attribute(.link, at: range.location, effectiveRange: nil) as? URL else { return }
            if url.scheme == "tab-agent-file" {
                links.append(range)
            } else if let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"), url.host != nil {
                links.append(range)
            }
        }
        for link in links {
            let range = (text.string as NSString).rangeOfComposedCharacterSequence(at: link.location)
            if let url = text.attribute(.link, at: link.location, effectiveRange: nil) as? URL,
               case .file(let path, _)? = AgentResponseLink.parse(url.absoluteString),
               let image = FileIcon.image(for: path, isDirectory: path.hasSuffix("/"), theme: theme) {
                text.addAttribute(.agentFileLinkImage, value: image, range: range)
            }
            var prefix = range
            if text.attribute(.agentExternalLinkProtocol, at: link.location, effectiveRange: nil) as? Bool == true {
                let label = (text.string as NSString).substring(with: link).lowercased()
                if label.hasPrefix("https://") { prefix.length = 8 }
                else if label.hasPrefix("http://") { prefix.length = 7 }
            }
            text.addAttribute(.agentExternalLinkNoBreak, value: NSValue(range: prefix), range: prefix)
            text.addAttributes([.agentExternalLinkFontSize: fontSize, .agentExternalLinkColor: color,
                                .agentExternalLinkGroup: NSValue(range: range)], range: range)
        }
    }

    static func minimumPrefixWidth(_ text: NSAttributedString) -> CGFloat {
        var width: CGFloat = 0
        text.enumerateAttribute(.agentExternalLinkNoBreak, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil, let size = text.attribute(.agentExternalLinkFontSize, at: range.location, effectiveRange: nil) as? CGFloat else { return }
            width = max(width, text.attributedSubstring(from: range).size().width + inset(fontSize: size) + AgentInlineCodeLayout.additionalWidth(text.attributedSubstring(from: range)))
        }
        return width
    }

    nonisolated static func additionalWidth(_ text: NSAttributedString) -> CGFloat {
        var width: CGFloat = 0
        text.enumerateAttribute(.agentExternalLinkGroup, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil, let size = text.attribute(.agentExternalLinkFontSize, at: range.location, effectiveRange: nil) as? CGFloat { width += inset(fontSize: size) }
        }
        return width
    }
}

extension NSAttributedString.Key {
    static let agentFileLinkImage = NSAttributedString.Key("TabAgentFileLinkImage")
    static let agentExternalLinkIdentity = NSAttributedString.Key("TabAgentExternalLinkIdentity")
    static let agentExternalLinkNoBreak = NSAttributedString.Key("TabAgentExternalLinkNoBreak")
    static let agentExternalLinkProtocol = NSAttributedString.Key("TabAgentExternalLinkProtocol")
    static let agentExternalLinkGroup = NSAttributedString.Key("TabAgentExternalLinkGroup")
    static let agentExternalLinkColor = NSAttributedString.Key("TabAgentExternalLinkColor")
    static let agentExternalLinkFontSize = NSAttributedString.Key("TabAgentExternalLinkFontSize")
}
