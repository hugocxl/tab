import AppKit
import TabProtocol

extension NSAttributedString.Key {
    /// The `tab-thread://` href of a composer thread mention; sent as a Markdown link.
    static let agentThreadMention = NSAttributedString.Key("TabAgentThreadMention")
    /// The session id (lowercase) of a rendered thread link chip.
    static let agentThreadLink = NSAttributedString.Key("TabAgentThreadLink")
}

/// A link to another agent conversation: `tab-thread://<project>/<session>`, or
/// `tab-thread://<session>` for a conversation of the same project. The composer's
/// `@` thread mention sends `[@Title](tab-thread://<project>/<session>)`; responses
/// render the link as a chip that opens the conversation.
struct AgentThreadLink: Equatable {
    static let scheme = "tab-thread"
    var session: SessionId
    var project: ProjectId?

    init(session: SessionId, project: ProjectId? = nil) {
        self.session = session
        self.project = project
    }

    init?(_ destination: String) {
        let raw = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.lowercased().hasPrefix(Self.scheme + "://"), raw.utf16.count <= 512,
              let parts = URLComponents(string: raw), parts.scheme?.lowercased() == Self.scheme,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
              let host = parts.host, !host.isEmpty else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: true)
        switch path.count {
        case 0:
            guard let session = SessionId(string: host) else { return nil }
            self.init(session: session)
        case 1:
            guard let project = ProjectId(string: host), let session = SessionId(string: String(path[0])) else { return nil }
            self.init(session: session, project: project)
        default: return nil
        }
    }

    var href: String { Self.scheme + "://" + (project.map { $0.description + "/" } ?? "") + session.description }

    /// The Markdown the composer sends for a mention titled `title`.
    func markdown(title: String) -> String { "[" + Self.escapeLabel("@" + Self.normalizedTitle(title)) + "](" + href + ")" }

    /// The first eight characters of the session id, for chips without a known title.
    var shortID: String { String(session.description.prefix(8)) }

    /// A known conversation title, else the link's own label, else a short session id.
    func chipTitle(label: String?, knownTitle: String?) -> String {
        if let knownTitle = knownTitle.map(Self.normalizedTitle), !knownTitle.isEmpty { return knownTitle }
        var text = Self.normalizedTitle(label ?? "")
        if text.hasPrefix("@") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if text.isEmpty || text.lowercased().hasPrefix(Self.scheme + "://") { return "Conversation " + shortID }
        return text
    }

    /// One line, at most 80 characters.
    static func normalizedTitle(_ title: String) -> String {
        let line = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// Escapes emphasis and code markers. Brackets stay literal when balanced, which link
    /// text allows; `\\[` would read as display math. Unbalanced brackets become parentheses.
    static func escapeLabel(_ label: String) -> String {
        var depth = 0, balanced = true
        for character in label {
            if character == "[" { depth += 1 } else if character == "]" { depth -= 1; if depth < 0 { balanced = false } }
        }
        if depth != 0 { balanced = false }
        var result = ""
        for character in label {
            if !balanced, character == "[" { result.append("("); continue }
            if !balanced, character == "]" { result.append(")"); continue }
            if "\\*_`<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// A chip: the conversation icon and the title, linked to the conversation. The
    /// pill is drawn by the rich-text layout manager's inline-code background.
    static func chip(_ link: AgentThreadLink, title: String, font: NSFont, color: NSColor, background: NSColor, identity: String) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .link: URL(string: link.href) as Any,
            .agentThreadLink: link.session.description, .agentInlineCodeIdentity: identity,
            .agentInlineCodeBackground: background,
        ]
        if URL(string: link.href) == nil { attributes.removeValue(forKey: .link) }
        let result = NSMutableAttributedString()
        if let icon = icon(size: font.pointSize, color: color) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: font.descender / 2, width: icon.size.width, height: icon.size.height)
            let iconText = NSMutableAttributedString(attachment: attachment)
            iconText.addAttributes(attributes, range: NSRange(location: 0, length: iconText.length))
            result.append(iconText)
            result.append(NSAttributedString(string: "\u{2009}", attributes: attributes))
        }
        result.append(NSAttributedString(string: title, attributes: attributes))
        result.addAttribute(.toolTip, value: "Open conversation", range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func icon(size: CGFloat, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.85, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Conversation")?
            .withSymbolConfiguration(configuration)
    }

    /// Replaces the titles of rendered chips whose conversation has a known title.
    static func applyKnownTitles(_ text: NSMutableAttributedString, titles: [String: String]) {
        guard !titles.isEmpty, text.length > 0 else { return }
        var replacements: [(NSRange, String)] = []
        text.enumerateAttribute(.agentThreadLink, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let session = value as? String, let title = titles[session].map(normalizedTitle), !title.isEmpty else { return }
            let content = text.attributedSubstring(from: range).string as NSString
            let titleStart = content.range(of: "\u{2009}").location
            let start = titleStart == NSNotFound ? 0 : titleStart + 1
            let titleRange = NSRange(location: range.location + start, length: range.length - start)
            guard (text.string as NSString).substring(with: titleRange) != title else { return }
            replacements.append((titleRange, title))
        }
        for (range, title) in replacements.reversed() where range.length > 0 {
            let attributes = text.attributes(at: range.location, effectiveRange: nil)
            text.replaceCharacters(in: range, with: NSAttributedString(string: title, attributes: attributes))
        }
    }
}
