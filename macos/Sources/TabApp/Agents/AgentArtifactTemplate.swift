import AppKit

/// A Codex artifact template offered in an assistant message, written as the leaf
/// directive `::artifact-template{artifact_kind="presentation" display_name="…"
/// skill_directory="/…" skill_name="artifact-template-…"}` on a line of its own.
/// Using it puts a prompt naming the template's skill in the composer; it never sends.
struct AgentArtifactTemplate: Equatable {
    enum Kind: String, CaseIterable {
        case document, presentation, spreadsheet, site, image, email, slack
        case googleDocs = "google-docs"
        case googleSlides = "google-slides"
        case googleSheets = "google-sheets"

        var label: String {
            switch self {
            case .document: return "Document template"
            case .presentation: return "Presentation template"
            case .spreadsheet: return "Spreadsheet template"
            case .site: return "Site template"
            case .googleDocs: return "Google Doc template"
            case .googleSlides: return "Google Slides template"
            case .googleSheets: return "Google Sheet template"
            case .image: return "Image template"
            case .email: return "Email template"
            case .slack: return "Slack template"
            }
        }

        var icon: AppIcon {
            switch self {
            case .document, .googleDocs: return .fileText
            case .presentation, .googleSlides: return .slides
            case .spreadsheet, .googleSheets: return .fileTable
            case .site: return .globe
            case .image: return .image
            case .email: return .envelope
            case .slack: return .hash
            }
        }

        /// The composer prompt for a template whose skill reference is `skill`.
        func prompt(_ skill: String) -> String {
            switch self {
            case .document: return "Create a document using this \(skill) about…"
            case .presentation: return "Create a presentation using the \(skill) template about…"
            case .spreadsheet: return "Create a spreadsheet using this \(skill) about…"
            case .site: return "Create a Site using this \(skill) about…"
            case .googleDocs: return "Create a Google Doc using this \(skill) about…"
            case .googleSlides: return "Create a Google Slides presentation using this \(skill) about…"
            case .googleSheets: return "Create a Google Sheet using this \(skill) about…"
            case .image: return "Create an image using this \(skill) of…"
            case .email: return "Draft an email using this \(skill) about…"
            case .slack: return "Draft a Slack message using this \(skill) about…"
            }
        }
    }

    var kind: Kind
    var displayName: String
    var galleryKind: String?
    var skillDirectory: String
    var skillName: String

    /// What the composer receives: `$skill-name` inside the kind's sentence.
    var prompt: String { kind.prompt("$" + skillName) }

    /// The directive on `line`, or nil when the line is anything else or the
    /// template is invalid; an invalid directive stays visible as text.
    static func parse(_ line: String) -> Self? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard line.prefix(while: { $0 == " " }).count <= 3, trimmed.hasPrefix("::artifact-template"),
              let regex = directivePattern,
              let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) else { return nil }
        let body = (trimmed as NSString).substring(with: match.range(at: 1))
        guard let attributes = attributes(body) else { return nil }
        guard let kind = attributes["artifact_kind"].flatMap(Kind.init(rawValue:)),
              let name = attributes["display_name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let directory = attributes["skill_directory"], isAbsolute(directory),
              let skill = attributes["skill_name"], skill.hasPrefix("artifact-template-") else { return nil }
        let gallery = attributes["gallery_kind"]
        if let gallery, !["imagegen", "product-design"].contains(gallery) { return nil }
        return Self(kind: kind, displayName: name, galleryKind: gallery, skillDirectory: directory, skillName: skill)
    }

    /// `draft` with the template prompt appended after a space, or unchanged when
    /// the draft already ends with that prompt.
    func appending(to draft: String) -> String {
        let prompt = self.prompt
        var trimmed = draft
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        if trimmed.hasSuffix(prompt) {
            let before = trimmed.dropLast(prompt.count)
            if before.isEmpty || before.last?.isWhitespace == true { return draft }
        }
        let separator = !draft.isEmpty && draft.last?.isWhitespace != true ? " " : ""
        return draft + separator + prompt
    }

    private static let directivePattern = try? NSRegularExpression(pattern: #"^::artifact-template(?:\[[^\]]*\])?\{(.*)\}$"#)
    private static let attributePattern = try? NSRegularExpression(
        pattern: #"\s*([A-Za-z_][\w-]*)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|([^\s"'=}]+))\s*"#)

    /// `key="value"` pairs covering the whole brace body; anything else rejects it.
    private static func attributes(_ body: String) -> [String: String]? {
        guard let regex = attributePattern else { return nil }
        let source = body as NSString
        var result: [String: String] = [:]
        var location = 0
        while location < source.length {
            guard let match = regex.firstMatch(in: body, options: .anchored, range: NSRange(location: location, length: source.length - location)),
                  match.range.length > 0 else {
                return source.substring(from: location).trimmingCharacters(in: .whitespaces).isEmpty ? result : nil
            }
            let key = source.substring(with: match.range(at: 1))
            if match.range(at: 4).location != NSNotFound {
                result[key] = source.substring(with: match.range(at: 4))
            } else {
                let quoted = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
                result[key] = quoted.location == NSNotFound ? ""
                    : source.substring(with: quoted).replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            }
            location = NSMaxRange(match.range)
        }
        return result
    }

    private static func isAbsolute(_ path: String) -> Bool {
        if path.hasPrefix("/") { return !path.hasPrefix("//") }
        if path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil { return true }
        return path.range(of: #"^(?:\\\\[^\\]+\\[^\\]+|//[^/]+/[^/]+)"#, options: .regularExpression) != nil
    }
}

/// A template offer: kind icon, name and kind, and a button that adds its prompt to the composer.
@MainActor
final class AgentResponseTemplate: AgentResponseSection {
    override var kind: Int { 9 }
    static let height: CGFloat = 56
    weak var services: AgentConversationLinkServices?
    private(set) var template: AgentArtifactTemplate?
    private let icon = NSImageView()
    private let iconBox = NSView()
    private let title = makeLabel("", font: AppFont.system(13, weight: .medium))
    private let subtitle = makeLabel("", font: AppFont.footnote)
    let use = PillButton("Use template", style: .normal)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 7
        iconBox.layer?.borderWidth = 1
        iconBox.addSubview(icon)
        for child in [iconBox, title, subtitle, use] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }
        title.lineBreakMode = .byTruncatingTail
        subtitle.lineBreakMode = .byTruncatingTail
        use.font = AppFont.footnote
        use.onPress = { [weak self] in
            guard let self, let template = self.template else { return }
            self.services?.useTemplate?(template)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard case .template(let template) = part else { return }
        self.template = template
        title.stringValue = template.displayName
        title.textColor = theme.fg
        subtitle.stringValue = template.kind.label
        subtitle.textColor = theme.fgMuted
        icon.image = template.kind.icon.image(size: 20, theme: theme)
        icon.contentTintColor = theme.fgMuted
        iconBox.layer?.backgroundColor = theme.bg.cgColor
        iconBox.layer?.borderColor = theme.border.withAlphaComponent(0.7).cgColor
        layer?.backgroundColor = theme.fg.withAlphaComponent(0.035).cgColor
        layer?.borderColor = theme.border.withAlphaComponent(0.7).cgColor
        use.setTitleColor(theme.fg)
        use.toolTip = "Add “\(template.prompt)” to the message"
        setAccessibilityLabel("\(template.displayName) template")
    }

    override func height(for width: CGFloat) -> CGFloat { Self.height }

    override func layoutSection(width: CGFloat) {
        let buttonWidth = ceil(use.intrinsicContentSize.width)
        use.frame = NSRect(x: max(0, width - 12 - buttonWidth), y: 14, width: buttonWidth, height: 28)
        iconBox.frame = NSRect(x: 12, y: 10, width: 36, height: 36)
        icon.frame = NSRect(x: 8, y: 8, width: 20, height: 20)
        let textX: CGFloat = 60, textWidth = max(0, use.frame.minX - 12 - textX)
        title.frame = NSRect(x: textX, y: 10, width: textWidth, height: 18)
        subtitle.frame = NSRect(x: textX, y: 29, width: textWidth, height: 16)
    }
}
