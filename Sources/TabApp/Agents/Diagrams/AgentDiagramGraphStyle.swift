import CoreGraphics
import Foundation

/// A color written in a Mermaid style declaration: `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()` or a basic name.
struct AgentDiagramColor: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat = 1

    /// Relative luminance, used to pick readable text on a custom fill.
    var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(css raw: String) {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("#") {
            let hex = Array(value.dropFirst())
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            func component(_ digits: ArraySlice<Character>) -> CGFloat? {
                let text = digits.count == 1 ? String(digits) + String(digits) : String(digits)
                return UInt8(text, radix: 16).map { CGFloat($0) / 255 }
            }
            switch hex.count {
            case 3, 4:
                guard let r = component(hex[0...0]), let g = component(hex[1...1]), let b = component(hex[2...2]) else { return nil }
                self.init(red: r, green: g, blue: b, alpha: hex.count == 4 ? component(hex[3...3]) ?? 1 : 1)
            case 6, 8:
                guard let r = component(hex[0...1]), let g = component(hex[2...3]), let b = component(hex[4...5]) else { return nil }
                self.init(red: r, green: g, blue: b, alpha: hex.count == 8 ? component(hex[6...7]) ?? 1 : 1)
            default:
                return nil
            }
            return
        }
        if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close {
            let parts = value[value.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            let numbers = parts.prefix(3).compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
            guard numbers.count == 3 else { return nil }
            let alpha = parts.count > 3 ? Double(parts[3]) ?? 1 : 1
            self.init(red: CGFloat(min(max(numbers[0], 0), 255) / 255), green: CGFloat(min(max(numbers[1], 0), 255) / 255),
                      blue: CGFloat(min(max(numbers[2], 0), 255) / 255), alpha: CGFloat(min(max(alpha, 0), 1)))
            return
        }
        let names: [String: (CGFloat, CGFloat, CGFloat)] = [
            "white": (1, 1, 1), "black": (0, 0, 0), "red": (1, 0, 0), "green": (0, 0.5, 0), "lime": (0, 1, 0),
            "blue": (0, 0, 1), "yellow": (1, 1, 0), "orange": (1, 0.65, 0), "purple": (0.5, 0, 0.5),
            "gray": (0.5, 0.5, 0.5), "grey": (0.5, 0.5, 0.5), "pink": (1, 0.75, 0.8), "cyan": (0, 1, 1),
            "magenta": (1, 0, 1), "brown": (0.65, 0.16, 0.16), "navy": (0, 0, 0.5), "teal": (0, 0.5, 0.5),
            "lightgray": (0.83, 0.83, 0.83), "lightgrey": (0.83, 0.83, 0.83), "darkgray": (0.66, 0.66, 0.66),
            "lightblue": (0.68, 0.85, 0.9), "lightgreen": (0.56, 0.93, 0.56), "gold": (1, 0.84, 0),
        ]
        if value == "transparent" || value == "none" {
            self.init(red: 0, green: 0, blue: 0, alpha: 0)
            return
        }
        guard let rgb = names[value] else { return nil }
        self.init(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

/// Visual overrides from Mermaid `style`, `classDef` and `class`. Unknown properties are ignored.
struct AgentDiagramNodeStyle: Equatable {
    var fill: AgentDiagramColor?
    var stroke: AgentDiagramColor?
    var text: AgentDiagramColor?
    var strokeWidth: CGFloat?
    var dashed = false
    var bold = false

    init() {}

    /// Parses `fill:#f9f,stroke:#333,stroke-width:4px,color:#fff,stroke-dasharray:5 5`.
    init(declarations: String) {
        for declaration in Self.splitTopLevel(declarations, separators: [",", ";"]) {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let key = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = declaration[declaration.index(after: colon)...]
                .replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "fill", "background", "background-color": fill = AgentDiagramColor(css: value)
            case "stroke", "border-color": stroke = AgentDiagramColor(css: value)
            case "color": text = AgentDiagramColor(css: value)
            case "stroke-width":
                if let width = Double(value.lowercased().replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)) {
                    strokeWidth = CGFloat(min(max(width, 0), 8))
                }
            case "stroke-dasharray": dashed = !value.isEmpty && value != "0" && value != "none"
            case "font-weight": bold = value == "bold" || (Int(value) ?? 400) >= 600
            default: continue
            }
        }
    }

    /// `other`'s set properties on top of this style's.
    func merged(with other: AgentDiagramNodeStyle) -> AgentDiagramNodeStyle {
        var result = self
        if let fill = other.fill { result.fill = fill }
        if let stroke = other.stroke { result.stroke = stroke }
        if let text = other.text { result.text = text }
        if let width = other.strokeWidth { result.strokeWidth = width }
        if other.dashed { result.dashed = true }
        if other.bold { result.bold = true }
        return result
    }

    /// Splits on separators outside parentheses, so `rgb(1,2,3)` stays whole.
    static func splitTopLevel(_ text: String, separators: Set<Character>) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if depth == 0, separators.contains(character) {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Named `classDef` styles and the classes assigned to diagram items.
struct AgentDiagramClassRegistry {
    private(set) var definitions: [String: AgentDiagramNodeStyle] = [:]

    /// Parses the text after `classDef`: `name[,name…] declarations`.
    mutating func define(_ rest: String) -> Bool {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return false }
        let names = trimmed[..<space].split(separator: ",").map { String($0) }
        let style = AgentDiagramNodeStyle(declarations: String(trimmed[space...]))
        for name in names where !name.isEmpty { definitions[name] = (definitions[name] ?? AgentDiagramNodeStyle()).merged(with: style) }
        return !names.isEmpty
    }

    /// The combined style of `default` and then each class in order.
    func style(for classes: [String]) -> AgentDiagramNodeStyle {
        var result = definitions["default"] ?? AgentDiagramNodeStyle()
        for name in classes { if let style = definitions[name] { result = result.merged(with: style) } }
        return result
    }
}

/// Mermaid label text: quotes, markdown strings, entity codes and `<br/>` line breaks.
enum AgentDiagramLabelText {
    /// The longest label kept; longer text is cut with an ellipsis.
    static let maximumLength = 600

    static func decode(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        }
        if text.count >= 2, text.hasPrefix("`"), text.hasSuffix("`") {
            text = String(text.dropFirst().dropLast())
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
        }
        text = text.replacingOccurrences(of: "\\n", with: "\n")
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</?(b|i|u|em|strong|small|code|span|sub|sup|p)(\\s[^>]*)?>", with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "fa:fa-[a-z0-9-]+\\s?", with: "", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maximumLength { text = String(text.prefix(maximumLength)) + "…" }
        return text
    }

    private static let named: [String: String] = [
        "quot": "\"", "amp": "&", "lt": "<", "gt": ">", "nbsp": " ", "apos": "'", "hash": "#",
        "semi": ";", "colon": ":", "copy": "©", "reg": "®", "deg": "°", "times": "×", "rarr": "→", "larr": "←",
    ]

    /// Decodes Mermaid `#name;`/`#123;` codes and HTML `&name;`/`&#123;` entities.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("#") || text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "#" || character == "&" else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            var cursor = text.index(after: index)
            if character == "&", cursor < text.endIndex, text[cursor] == "#" { cursor = text.index(after: cursor) }
            let start = cursor
            var length = 0
            while cursor < text.endIndex, text[cursor].isLetter || text[cursor].isNumber, length < 10 {
                cursor = text.index(after: cursor)
                length += 1
            }
            guard cursor < text.endIndex, text[cursor] == ";", length > 0 else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let name = String(text[start..<cursor])
            var replacement: String?
            if let value = named[name.lowercased()] {
                replacement = value
            } else if let number = UInt32(name), let scalar = Unicode.Scalar(number) {
                replacement = String(Character(scalar))
            } else if name.lowercased().hasPrefix("x"), let number = UInt32(name.dropFirst(), radix: 16), let scalar = Unicode.Scalar(number) {
                replacement = String(Character(scalar))
            }
            guard let replacement else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            result += replacement
            index = text.index(after: cursor)
        }
        return result
    }
}
