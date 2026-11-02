import AppKit
import TabCore
import TabProtocol

/// The source renderer's command inspector: shell source, independently scrolling output, then a nonzero exit.
@MainActor
enum AgentCommandPresentation {
    static func command(_ activity: AgentToolActivity) -> String {
        let input = activity.input ?? ""
        if let data = input.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return ((object["command"] ?? object["cmd"]) as? String ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func text(_ source: String, color: NSColor) -> NSMutableAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 21.125
        paragraph.maximumLineHeight = 21.125
        paragraph.lineBreakMode = .byWordWrapping
        return NSMutableAttributedString(string: source, attributes: [
            .font: AppFont.mono(13), .foregroundColor: color, .paragraphStyle: paragraph,
            .baselineOffset: (21.125 - floor(AppFont.mono(13).ascender - AppFont.mono(13).descender)) / 2,
        ])
    }

    static func source(_ activity: AgentToolActivity, theme: AppTheme) -> NSAttributedString {
        let command = command(activity)
        let content = text(command, color: theme.fg.withAlphaComponent(0.85))
        let highlighter = SyntaxHighlighter(language: .shell)
        highlighter.setText(command)
        for token in highlighter.tokens where NSMaxRange(token.range) <= content.length {
            content.addAttributes(theme.syntaxColors.attributes(token.kind, font: AppFont.mono(13)), range: token.range)
        }
        return content
    }

    static func output(_ activity: AgentToolActivity, theme: AppTheme) -> NSAttributedString {
        guard let output = activity.output, !output.isEmpty else {
            let value = text(activity.status == .running ? "" : "No output.", color: theme.fgMuted)
            value.addAttribute(.font, value: NSFontManager.shared.convert(AppFont.mono(13), toHaveTrait: .italicFontMask), range: NSRange(location: 0, length: value.length))
            return value
        }
        return AgentTerminalOutput(dark: !theme.palette.isLight, baseColor: theme.fgMuted, palette: TerminalPalette(scheme: theme.scheme, dark: !theme.palette.isLight)).render(output)
    }
}
