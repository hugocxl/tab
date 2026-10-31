import AppKit

/// JSON scopes from the existing app syntax colors. Applied only
/// where the source renderer's StructuredValue requests JSON highlighting, not to tool output.
@MainActor
enum AgentJSONSyntax {
    static func highlight(_ text: String, theme: AppTheme) -> NSAttributedString {
        let result = AgentCommandPresentation.text(text, color: theme.fgMuted)
        guard AgentToolJSON.parse(text) != nil,
              let expression = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\[\],:]"#) else { return result }
        let source = text as NSString
        let syntax = theme.syntaxColors
        let punctuation = syntax.color(.punctuation)
        let key = syntax.color(.attribute)
        let string = syntax.color(.string)
        let escape = syntax.color(.type)
        let number = syntax.color(.number)
        let null = syntax.color(.keyword)
        let escapes = try? NSRegularExpression(pattern: #"\\(?:u[0-9a-fA-F]{4}|["\\/bfnrt])"#)
        for token in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let value = source.substring(with: token.range)
            let isString = value.hasPrefix("\"")
            var next = NSMaxRange(token.range)
            if isString {
                while next < source.length && [9, 10, 13, 32].contains(source.character(at: next)) { next += 1 }
            }
            let isKey = isString && next < source.length && source.character(at: next) == 58
            let foreground = isString ? (isKey ? key : string) : value == "null" ? null
                : (value == "true" || value == "false" || value.first?.isNumber == true || value.hasPrefix("-")) ? number : punctuation
            result.addAttribute(.foregroundColor, value: foreground, range: token.range)
            if isString {
                for escaped in escapes?.matches(in: text, range: token.range) ?? [] {
                    result.addAttribute(.foregroundColor, value: escape, range: escaped.range)
                }
            }
        }
        return result
    }
}
