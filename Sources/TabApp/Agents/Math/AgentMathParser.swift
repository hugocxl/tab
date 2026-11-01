import Foundation

/// TeX math styles, from largest to smallest.
enum AgentMathStyle: Equatable, Sendable {
    case display, text, script, scriptScript
}

/// Alphabets selected by `\mathrm`, `\mathbf`, `\mathbb` and friends.
enum AgentMathFontVariant: Equatable, Sendable {
    /// Italic Latin and lowercase Greek letters, upright digits and capital Greek.
    case normal
    case roman, italic, bold, boldItalic, doubleStruck, script, fraktur, sansSerif, monospace
}

/// Faces for `\text` and its relatives.
enum AgentMathTextVariant: Equatable, Sendable {
    case normal, bold, italic, monospace, sansSerif
}

/// Where scripts on an operator go.
enum AgentMathLimits: Equatable, Sendable {
    /// Above and below in display style when the operator takes limits, at the side otherwise.
    case automatic
    case limits
    case noLimits
}

/// A large operator or function name such as `\sum` or `\lim`.
struct AgentMathOperator: Equatable, Sendable {
    var text: String
    /// A symbol drawn from the math font (`∑`) rather than a word set upright (`lim`).
    var isLargeSymbol: Bool
    var limits: AgentMathLimits
    /// Whether `.automatic` limits go above and below in display style.
    var takesLimitsInDisplay: Bool
}

enum AgentMathColumnAlignment: Equatable, Sendable {
    case left, center, right
}

/// A grid from a `matrix`, `cases`, `aligned`, `gather` or `array` environment.
struct AgentMathArray: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case matrix, smallMatrix, cases, aligned, gather, array
    }

    var kind: Kind
    var rows: [[AgentMathNode]]
    /// Explicit column alignments from an `array` column spec; derived from `kind` when empty.
    var columns: [AgentMathColumnAlignment] = []
    /// Column boundaries (0 is before the first column) that carry a vertical rule.
    var verticalRules: Set<Int> = []
    /// Row boundaries (0 is above the first row) that carry a horizontal rule.
    var horizontalRules: Set<Int> = []
}

/// The parse tree of a LaTeX math expression.
indirect enum AgentMathNode: Equatable, Sendable {
    /// One or more characters from the math font with an atom class.
    case symbol(String, AgentMathAtomClass)
    case number(String)
    case text(String, AgentMathTextVariant)
    /// A braced group; it lays out as a single ordinary atom.
    case group([AgentMathNode])
    case scripts(base: AgentMathNode, sub: AgentMathNode?, sup: AgentMathNode?)
    case largeOperator(AgentMathOperator)
    /// `\frac` and `\binom` bodies. `style` is forced by `\dfrac` and `\tfrac`.
    case fraction(numerator: AgentMathNode, denominator: AgentMathNode, hasRule: Bool, style: AgentMathStyle?)
    case radical(radicand: AgentMathNode, index: AgentMathNode?)
    /// `\left … \right`; an empty delimiter is the null delimiter `.`.
    case leftRight(left: String, body: [AgentMathNode], right: String)
    case middle(String)
    /// `\big` (1) through `\Bigg` (4).
    case sizedDelimiter(String, size: Int, AgentMathAtomClass)
    case accent(base: AgentMathNode, accent: String, isStretchy: Bool)
    case overline(AgentMathNode)
    case underline(AgentMathNode)
    /// `\overbrace` and `\underbrace`; scripts on them go above or below.
    case horizontalBrace(AgentMathNode, isOver: Bool)
    /// `\overset`, `\underset` and `\stackrel`.
    case underOver(base: AgentMathNode, over: AgentMathNode?, under: AgentMathNode?, AgentMathAtomClass)
    /// `\xrightarrow[under]{over}` and its relatives.
    case extensibleArrow(String, over: AgentMathNode?, under: AgentMathNode?)
    case font(AgentMathFontVariant, [AgentMathNode])
    case style(AgentMathStyle, [AgentMathNode])
    /// A color name or `#hex`; unknown names keep the surrounding color.
    case color(String, [AgentMathNode])
    /// Horizontal space in mu (1 em = 18 mu).
    case space(Double)
    case array(AgentMathArray)
    /// `\not` on something without a precomposed negation.
    case negated(AgentMathNode)
    case cancel(AgentMathNode, AgentMathCancelKind)
    case boxed(AgentMathNode)
    case phantom(AgentMathNode, keepsWidth: Bool, keepsHeight: Bool)
    case classed(AgentMathAtomClass, AgentMathNode)
    case tag(String)
    /// Source the parser couldn't interpret, shown verbatim in the error color.
    case error(String)
}

enum AgentMathCancelKind: Equatable, Sendable {
    case forward, backward, cross, strikeout
}

/// The parse tree with the problems found, if any. Parsing never fails.
struct AgentMathParseResult: Equatable, Sendable {
    var nodes: [AgentMathNode]
    var errors: [String]
}

/// A recursive-descent parser over a real TeX tokenizer: control sequences,
/// groups, scripts, alignment tabs and row breaks. It recovers from every
/// error, rendering unknown input verbatim like KaTeX's `throwOnError: false`.
struct AgentMathParser {
    private enum Token: Equatable {
        case command(String)
        case character(Character)
        case beginGroup
        case endGroup
        case superscript
        case `subscript`
        case alignment
        case end
    }

    private let characters: [Character]
    private var position = 0
    private var errors: [String] = []
    private var depth = 0
    private static let maximumDepth = 64

    private init(_ source: String) {
        characters = Array(source)
    }

    static func parse(_ latex: String) -> AgentMathParseResult {
        var parser = AgentMathParser(latex)
        let rows = parser.parseRows(environment: nil)
        let nodes: [AgentMathNode]
        if rows.rows.count == 1, rows.rows[0].count == 1, case .group(let cell) = rows.rows[0][0] {
            nodes = cell
        } else {
            let isAligned = rows.rows.contains { $0.count > 1 }
            let array = AgentMathArray(
                kind: isAligned ? .aligned : .gather,
                rows: rows.rows,
                horizontalRules: rows.horizontalRules
            )
            nodes = [.array(array)]
        }
        return AgentMathParseResult(nodes: nodes, errors: parser.errors)
    }

    // MARK: Tokenizer

    private var isAtEnd: Bool { position >= characters.count }

    private mutating func skipWhitespaceAndComments() {
        while position < characters.count {
            let character = characters[position]
            if character == "%" {
                while position < characters.count, characters[position] != "\n" { position += 1 }
                continue
            }
            guard character.isWhitespace else { return }
            position += 1
        }
    }

    private mutating func nextToken() -> Token {
        skipWhitespaceAndComments()
        guard position < characters.count else { return .end }
        let character = characters[position]
        position += 1
        switch character {
        case "{": return .beginGroup
        case "}": return .endGroup
        case "^": return .superscript
        case "_": return .subscript
        case "&": return .alignment
        case "\\": return .command(readControlSequenceName())
        default: return .character(character)
        }
    }

    private mutating func peekToken() -> Token {
        let saved = position
        let token = nextToken()
        position = saved
        return token
    }

    private mutating func readControlSequenceName() -> String {
        guard position < characters.count else { return "\\" }
        let first = characters[position]
        guard first.isASCII, first.isLetter else {
            position += 1
            return String(first)
        }
        var name = ""
        while position < characters.count, characters[position].isASCII, characters[position].isLetter {
            name.append(characters[position])
            position += 1
        }
        return name
    }

    /// Consumes a `*` directly after a command name, as in `\operatorname*`.
    private mutating func consumeStar() -> Bool {
        guard position < characters.count, characters[position] == "*" else { return false }
        position += 1
        return true
    }

    // MARK: Lists and rows

    private struct Rows {
        var rows: [[AgentMathNode]]
        var horizontalRules: Set<Int>
    }

    private func isListTerminator(_ token: Token, bracket: Bool) -> Bool {
        switch token {
        case .end, .endGroup, .alignment:
            return true
        case .command(let name):
            return ["\\", "cr", "newline", "end", "right", "middle", "hline", "hdashline"].contains(name)
        case .character(let character):
            return bracket && character == "]"
        default:
            return false
        }
    }

    /// Parses atoms until a terminator, which is left for the caller.
    private mutating func parseList(bracket: Bool = false) -> [AgentMathNode] {
        var nodes: [AgentMathNode] = []
        while true {
            let token = peekToken()
            if isListTerminator(token, bracket: bracket) { return nodes }
            if case .command(let name) = token, let rest = parseSwitch(name, bracket: bracket) {
                nodes.append(rest)
                return nodes
            }
            guard let atom = parseAtom(allowsNumberRun: true) else { continue }
            nodes.append(parseScripts(on: atom))
        }
    }

    /// Rows of cells up to `\end{environment}` (or the end of input at the top level).
    private mutating func parseRows(environment: String?) -> Rows {
        var rows: [[AgentMathNode]] = []
        var row: [AgentMathNode] = []
        var cell: [AgentMathNode] = []
        var horizontalRules: Set<Int> = []
        func finishRow() {
            row.append(.group(cell))
            rows.append(row)
            row = []
            cell = []
        }
        loop: while true {
            cell += parseList()
            let token = nextTokenAfterPeek()
            switch token {
            case .end:
                if let environment { errors.append("missing \\end{\(environment)}") }
                break loop
            case .alignment:
                row.append(.group(cell))
                cell = []
            case .command("\\"), .command("cr"), .command("newline"):
                _ = readOptionalBracketText()
                finishRow()
            case .command("hline"), .command("hdashline"):
                horizontalRules.insert(rows.count)
            case .command("end"):
                let name = readRawGroup()
                if environment == nil {
                    errors.append("unexpected \\end{\(name)}")
                    cell.append(.error("\\end{\(name)}"))
                    continue
                }
                if name != environment { errors.append("\\begin{\(environment ?? "")} ended by \\end{\(name)}") }
                break loop
            case .endGroup:
                errors.append("unexpected }")
                cell.append(.error("}"))
            case .command(let name):
                errors.append("unexpected \\\(name)")
                if name == "right" || name == "middle" { _ = readDelimiter() }
                cell.append(.error("\\\(name)"))
            default:
                break loop
            }
        }
        finishRow()
        if rows.count > 1, let last = rows.last, last.count == 1, last[0] == .group([]) {
            rows.removeLast()
        }
        return Rows(rows: rows, horizontalRules: horizontalRules)
    }

    private mutating func nextTokenAfterPeek() -> Token {
        nextToken()
    }

    /// Commands that apply to the rest of the current group, like `\displaystyle` or `\color`.
    private mutating func parseSwitch(_ name: String, bracket: Bool) -> AgentMathNode? {
        let style: AgentMathStyle? = switch name {
        case "displaystyle": .display
        case "textstyle": .text
        case "scriptstyle": .script
        case "scriptscriptstyle": .scriptScript
        default: nil
        }
        if let style {
            _ = nextToken()
            return .style(style, parseList(bracket: bracket))
        }
        let variant: AgentMathFontVariant? = switch name {
        case "rm": .roman
        case "bf": .bold
        case "it": .italic
        case "cal": .script
        case "sf": .sansSerif
        case "tt": .monospace
        default: nil
        }
        if let variant {
            _ = nextToken()
            return .font(variant, parseList(bracket: bracket))
        }
        guard name == "color" else { return nil }
        _ = nextToken()
        let color = readColorArgument()
        return .color(color, parseList(bracket: bracket))
    }

    // MARK: Atoms

    /// One atom without its scripts, or nil when the token produced nothing visible.
    private mutating func parseAtom(allowsNumberRun: Bool) -> AgentMathNode? {
        let token = nextToken()
        switch token {
        case .end:
            return nil
        case .beginGroup:
            return .group(parseGroupBody())
        case .endGroup, .alignment:
            errors.append("unexpected token")
            return .error(token == .alignment ? "&" : "}")
        case .superscript, .subscript:
            position -= 1
            return .group([])
        case .character(let character):
            return parseCharacter(character, allowsNumberRun: allowsNumberRun)
        case .command(let name):
            depth += 1
            defer { depth -= 1 }
            guard depth < Self.maximumDepth else {
                errors.append("nesting too deep")
                return .error("\\\(name)")
            }
            return parseCommand(name)
        }
    }

    private mutating func parseGroupBody() -> [AgentMathNode] {
        var nodes: [AgentMathNode] = []
        while true {
            nodes += parseList()
            switch peekToken() {
            case .endGroup:
                _ = nextToken()
                return nodes
            case .end, .command("end"), .command("right"), .command("middle"):
                errors.append("missing }")
                return nodes
            case .alignment:
                _ = nextToken()
                errors.append("& outside an environment")
                nodes.append(.error("&"))
            default:
                _ = nextToken()
            }
        }
    }

    private mutating func parseCharacter(_ character: Character, allowsNumberRun: Bool) -> AgentMathNode {
        if character.isASCII, character.isNumber {
            var digits = String(character)
            guard allowsNumberRun else { return .number(digits) }
            while position < characters.count {
                let next = characters[position]
                if next.isASCII, next.isNumber {
                    digits.append(next)
                    position += 1
                } else if next == ".", position + 1 < characters.count,
                          characters[position + 1].isASCII, characters[position + 1].isNumber {
                    digits.append(next)
                    position += 1
                } else {
                    break
                }
            }
            return .number(digits)
        }
        switch character {
        case "-": return .symbol("−", .bin)
        case "*": return .symbol("∗", .bin)
        case "'": return .symbol("′", .ord)
        case "~": return .space(6)
        case "<": return .symbol("<", .rel)
        case ">": return .symbol(">", .rel)
        default: return .symbol(String(character), AgentMathSymbols.atomClass(of: character))
        }
    }

    /// Attaches `^`, `_`, primes, `\limits` and `\nolimits` that follow `base`.
    private mutating func parseScripts(on base: AgentMathNode) -> AgentMathNode {
        var base = base
        var sub: AgentMathNode?
        var sup: AgentMathNode?
        var primes = 0
        loop: while true {
            switch peekToken() {
            case .superscript:
                _ = nextToken()
                let argument = parseArgument()
                if sup != nil { errors.append("double superscript") }
                sup = sup.map { .group([$0, argument]) } ?? argument
            case .subscript:
                _ = nextToken()
                let argument = parseArgument()
                if sub != nil { errors.append("double subscript") }
                sub = sub.map { .group([$0, argument]) } ?? argument
            case .character("'"):
                _ = nextToken()
                primes += 1
            case .command("limits"), .command("nolimits"), .command("displaylimits"):
                guard case .command(let name) = nextToken() else { break loop }
                guard case .largeOperator(var op) = base else { continue }
                op.limits = name == "limits" ? .limits : name == "nolimits" ? .noLimits : .automatic
                base = .largeOperator(op)
            default:
                break loop
            }
        }
        if primes > 0 {
            let prime = AgentMathNode.symbol(String(repeating: "′", count: primes), .ord)
            if case .group(let nodes)? = sup {
                sup = .group([prime] + nodes)
            } else if let existing = sup {
                sup = .group([prime, existing])
            } else {
                sup = prime
            }
        }
        guard sub != nil || sup != nil else { return base }
        return .scripts(base: base, sub: sub, sup: sup)
    }

    /// A braced group or a single token, as TeX reads macro arguments.
    private mutating func parseArgument() -> AgentMathNode {
        switch peekToken() {
        case .beginGroup:
            _ = nextToken()
            return .group(parseGroupBody())
        case .end, .endGroup, .alignment, .superscript, .subscript:
            errors.append("missing argument")
            return .group([])
        case .command(let name) where ["\\", "end", "right", "middle", "cr", "hline"].contains(name):
            errors.append("missing argument")
            return .group([])
        default:
            return parseAtom(allowsNumberRun: false) ?? .group([])
        }
    }

    private mutating func peekCharacter() -> Character? {
        skipWhitespaceAndComments()
        return position < characters.count ? characters[position] : nil
    }

    /// The `[…]` optional argument parsed as math, or nil when absent.
    private mutating func parseOptionalArgument() -> AgentMathNode? {
        guard peekCharacter() == "[" else { return nil }
        position += 1
        let nodes = parseList(bracket: true)
        if peekToken() == .character("]") {
            _ = nextToken()
        } else {
            errors.append("missing ]")
        }
        return .group(nodes)
    }

    /// The raw text of a `[…]` optional argument, or nil when absent.
    private mutating func readOptionalBracketText() -> String? {
        guard peekCharacter() == "[" else { return nil }
        position += 1
        var text = ""
        while position < characters.count, characters[position] != "]" {
            text.append(characters[position])
            position += 1
        }
        if position < characters.count { position += 1 }
        return text
    }

    /// The literal contents of a braced group (or one character), with text-mode escapes resolved.
    private mutating func readRawGroup() -> String {
        skipWhitespaceAndComments()
        guard position < characters.count else {
            errors.append("missing argument")
            return ""
        }
        guard characters[position] == "{" else {
            let character = characters[position]
            position += 1
            if character == "\\" { return textForEscape(readControlSequenceName()) }
            return String(character)
        }
        position += 1
        var text = ""
        var nesting = 0
        var lastWasSpace = false
        while position < characters.count {
            let character = characters[position]
            position += 1
            switch character {
            case "{":
                nesting += 1
                lastWasSpace = false
            case "}":
                if nesting == 0 { return text }
                nesting -= 1
            case "\\":
                let name = readControlSequenceName()
                let escaped = textForEscape(name)
                if name.first?.isLetter == true { skipSpacesOnly() }
                text += escaped
                lastWasSpace = escaped == " "
            case "~":
                text.append("\u{00A0}")
                lastWasSpace = false
            case _ where character.isWhitespace:
                if !lastWasSpace { text.append(" ") }
                lastWasSpace = true
            default:
                text.append(character)
                lastWasSpace = false
            }
        }
        errors.append("missing }")
        return text
    }

    private mutating func skipSpacesOnly() {
        while position < characters.count, characters[position] == " " { position += 1 }
    }

    private func textForEscape(_ name: String) -> String {
        switch name {
        case " ", "space": return " "
        case ",", "thinspace": return "\u{2009}"
        case "quad": return "\u{2003}"
        case "qquad": return "\u{2003}\u{2003}"
        case "textbackslash", "backslash": return "\\"
        case "{", "}", "$", "%", "&", "#", "_": return name
        case "\\": return " "
        case "ldots", "dots", "textellipsis": return "…"
        case "textendash": return "–"
        case "textemdash": return "—"
        default:
            if let symbol = AgentMathSymbols.symbols[name] { return symbol.text }
            return "\\" + name
        }
    }

    private mutating func readColorArgument() -> String {
        let model = readOptionalBracketText()
        let value = readRawGroup()
        if model?.lowercased() == "html" { return "#" + value }
        return value
    }

    /// A delimiter after `\left`, `\right`, `\middle` or `\big`; "" is the null delimiter.
    private mutating func readDelimiter() -> String {
        let token = nextToken()
        switch token {
        case .character(let character):
            if let delimiter = AgentMathSymbols.delimiterCharacters[character] { return delimiter }
        case .command(let name):
            if let delimiter = AgentMathSymbols.delimiterCommands[name] { return delimiter }
        case .beginGroup:
            let delimiter = readDelimiter()
            if peekToken() == .endGroup { _ = nextToken() }
            return delimiter
        default:
            break
        }
        errors.append("missing or invalid delimiter")
        if token == .end { return "" }
        if case .endGroup = token { position -= 1 }
        return ""
    }

    /// A TeX dimension such as `1em`, `-3mu` or `2pt`, in mu.
    private mutating func readDimension(braced: Bool) -> Double {
        let source: [Character]
        if braced {
            source = Array(readRawGroup())
        } else {
            skipWhitespaceAndComments()
            var collected: [Character] = []
            while position < characters.count {
                let character = characters[position]
                if character.isNumber || character == "." || character == "-" || character == "+" {
                    collected.append(character)
                    position += 1
                } else {
                    break
                }
            }
            skipWhitespaceAndComments()
            var letters = 0
            while position < characters.count, letters < 2, characters[position].isLetter {
                collected.append(characters[position])
                position += 1
                letters += 1
            }
            source = collected
        }
        let numberPart = String(source.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" })
        let unit = String(source.dropFirst(numberPart.count)).trimmingCharacters(in: .whitespaces)
        guard let value = Double(numberPart) else {
            errors.append("invalid dimension")
            return 0
        }
        switch unit {
        case "mu": return value
        case "em": return value * 18
        case "ex": return value * 18 * 0.431
        case "pt", "px", "bp": return value * 1.8
        case "pc": return value * 21.6
        case "mm": return value * 1.8 * 2.845
        case "cm": return value * 1.8 * 28.45
        case "in": return value * 1.8 * 72.27
        default: return value * 1.8
        }
    }

    // MARK: Commands

    private mutating func parseCommand(_ name: String) -> AgentMathNode {
        if let symbol = AgentMathSymbols.symbols[name] {
            return .symbol(symbol.text, symbol.atomClass)
        }
        if let text = AgentMathSymbols.largeOperators[name] {
            let takesLimits = !AgentMathSymbols.sideScriptOperators.contains(text)
            return .largeOperator(AgentMathOperator(
                text: text, isLargeSymbol: true, limits: .automatic, takesLimitsInDisplay: takesLimits
            ))
        }
        if let function = AgentMathSymbols.functions[name] {
            return .largeOperator(AgentMathOperator(
                text: function.text, isLargeSymbol: false, limits: .automatic, takesLimitsInDisplay: function.limits
            ))
        }
        if let mu = AgentMathSymbols.spaces[name] {
            return .space(mu)
        }
        if let accent = AgentMathSymbols.accents[name] {
            return .accent(base: parseArgument(), accent: accent.character, isStretchy: accent.isStretchy)
        }
        if let node = parseStructureCommand(name) {
            return node
        }
        if let node = parseFontCommand(name) {
            return node
        }
        return parseMiscellaneousCommand(name)
    }

    private mutating func parseStructureCommand(_ name: String) -> AgentMathNode? {
        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            let numerator = parseArgument()
            let denominator = parseArgument()
            let style: AgentMathStyle? = name == "dfrac" || name == "cfrac" ? .display : name == "tfrac" ? .text : nil
            return .fraction(numerator: numerator, denominator: denominator, hasRule: true, style: style)
        case "binom", "dbinom", "tbinom":
            let top = parseArgument()
            let bottom = parseArgument()
            let style: AgentMathStyle? = name == "dbinom" ? .display : name == "tbinom" ? .text : nil
            let fraction = AgentMathNode.fraction(numerator: top, denominator: bottom, hasRule: false, style: style)
            return .leftRight(left: "(", body: [fraction], right: ")")
        case "sqrt":
            let index = parseOptionalArgument()
            return .radical(radicand: parseArgument(), index: index)
        case "left":
            return parseLeftRight()
        case "big", "Big", "bigg", "Bigg", "bigl", "Bigl", "biggl", "Biggl",
             "bigr", "Bigr", "biggr", "Biggr", "bigm", "Bigm", "biggm", "Biggm":
            return parseSizedDelimiter(name)
        case "overline":
            return .overline(parseArgument())
        case "underline":
            return .underline(parseArgument())
        case "overbrace", "underbrace":
            return .horizontalBrace(parseArgument(), isOver: name == "overbrace")
        case "overset", "stackrel":
            let over = parseArgument()
            let base = parseArgument()
            let atomClass = name == "stackrel" ? .rel : Self.binRelClass(of: base)
            return .underOver(base: base, over: over, under: nil, atomClass)
        case "underset":
            let under = parseArgument()
            let base = parseArgument()
            return .underOver(base: base, over: nil, under: under, Self.binRelClass(of: base))
        case "xrightarrow", "xleftarrow", "xleftrightarrow", "xRightarrow", "xLeftarrow",
             "xLeftrightarrow", "xmapsto", "xlongequal":
            let arrows = [
                "xrightarrow": "→", "xleftarrow": "←", "xleftrightarrow": "↔", "xRightarrow": "⇒",
                "xLeftarrow": "⇐", "xLeftrightarrow": "⇔", "xmapsto": "↦", "xlongequal": "=",
            ]
            let under = parseOptionalArgument()
            let over = parseArgument()
            return .extensibleArrow(arrows[name] ?? "→", over: over, under: under)
        case "begin":
            return parseEnvironment()
        case "operatorname", "operatornamewithlimits":
            let limits = consumeStar() || name == "operatornamewithlimits"
            let text = readRawGroup()
            return .largeOperator(AgentMathOperator(
                text: text, isLargeSymbol: false, limits: .automatic, takesLimitsInDisplay: limits
            ))
        default:
            return nil
        }
    }

    private mutating func parseFontCommand(_ name: String) -> AgentMathNode? {
        let textVariants: [String: AgentMathTextVariant] = [
            "text": .normal, "textrm": .normal, "textnormal": .normal, "mbox": .normal, "hbox": .normal,
            "textup": .normal, "textbf": .bold, "textit": .italic, "textsl": .italic, "emph": .italic,
            "texttt": .monospace, "textsf": .sansSerif,
        ]
        if let variant = textVariants[name] {
            return .text(readRawGroup(), variant)
        }
        let mathVariants: [String: AgentMathFontVariant] = [
            "mathrm": .roman, "mathup": .roman, "mathit": .italic, "mathbf": .bold, "bm": .boldItalic,
            "boldsymbol": .boldItalic, "mathbb": .doubleStruck, "Bbb": .doubleStruck,
            "mathcal": .script, "mathscr": .script, "mathfrak": .fraktur, "frak": .fraktur,
            "mathsf": .sansSerif, "mathtt": .monospace, "mathnormal": .normal,
        ]
        guard let variant = mathVariants[name] else { return nil }
        let argument = parseArgument()
        if case .group(let nodes) = argument { return .font(variant, nodes) }
        return .font(variant, [argument])
    }

    private mutating func parseMiscellaneousCommand(_ name: String) -> AgentMathNode {
        switch name {
        case "implies":
            return .group([.space(5), .symbol("⟹", .rel), .space(5)])
        case "impliedby":
            return .group([.space(5), .symbol("⟸", .rel), .space(5)])
        case "iff":
            return .group([.space(5), .symbol("⟺", .rel), .space(5)])
        case "textcolor":
            let color = readColorArgument()
            let argument = parseArgument()
            if case .group(let nodes) = argument { return .color(color, nodes) }
            return .color(color, [argument])
        case "not":
            return parseNot()
        case "cancel", "bcancel", "xcancel", "sout":
            let kinds: [String: AgentMathCancelKind] = [
                "cancel": .forward, "bcancel": .backward, "xcancel": .cross, "sout": .strikeout,
            ]
            return .cancel(parseArgument(), kinds[name] ?? .forward)
        case "boxed", "fbox":
            if name == "fbox" { return .boxed(.text(readRawGroup(), .normal)) }
            return .boxed(parseArgument())
        case "phantom":
            return .phantom(parseArgument(), keepsWidth: true, keepsHeight: true)
        case "hphantom":
            return .phantom(parseArgument(), keepsWidth: true, keepsHeight: false)
        case "vphantom":
            return .phantom(parseArgument(), keepsWidth: false, keepsHeight: true)
        case "mathop", "mathrel", "mathbin", "mathord", "mathopen", "mathclose", "mathpunct", "mathinner":
            let classes: [String: AgentMathAtomClass] = [
                "mathop": .op, "mathrel": .rel, "mathbin": .bin, "mathord": .ord, "mathopen": .open,
                "mathclose": .close, "mathpunct": .punct, "mathinner": .inner,
            ]
            return .classed(classes[name] ?? .ord, parseArgument())
        case "tag":
            _ = consumeStar()
            return .tag(readRawGroup())
        case "label", "ref", "eqref":
            let label = readRawGroup()
            return name == "label" ? .group([]) : .text("(\(label))", .normal)
        case "nonumber", "notag", "limits", "nolimits", "displaylimits", "allowbreak", "nobreak",
             "relax", "strut", "mathstrut", "hfill", "hfil", "centering", "noindent", "par", "middle":
            return .group([])
        case "hspace", "hskip", "kern", "mkern", "mskip", "mspace":
            let braced = name == "hspace" || name == "mspace" || peekCharacter() == "{"
            if name == "hspace" { _ = consumeStar() }
            return .space(readDimension(braced: braced))
        case "unicode":
            let code = readRawGroup()
            let digits = code.hasPrefix("x") || code.hasPrefix("X") ? String(code.dropFirst()) : code
            let radix = code.hasPrefix("x") || code.hasPrefix("X") ? 16 : 10
            guard let value = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(value) else {
                errors.append("invalid \\unicode")
                return .error("\\unicode{\(code)}")
            }
            return .symbol(String(Character(scalar)), .ord)
        default:
            errors.append("unknown command \\\(name)")
            return .error("\\" + name)
        }
    }

    private mutating func parseNot() -> AgentMathNode {
        guard let atom = parseAtom(allowsNumberRun: false) else {
            errors.append("missing argument")
            return .symbol("/", .rel)
        }
        if case .symbol(let text, _) = atom, let negation = AgentMathSymbols.negations[text] {
            return .symbol(negation, .rel)
        }
        return .classed(.rel, .negated(atom))
    }

    private mutating func parseLeftRight() -> AgentMathNode {
        let left = readDelimiter()
        var body: [AgentMathNode] = []
        while true {
            body += parseList()
            switch peekToken() {
            case .command("right"):
                _ = nextToken()
                return .leftRight(left: left, body: body, right: readDelimiter())
            case .command("middle"):
                _ = nextToken()
                body.append(.middle(readDelimiter()))
            case .alignment, .command("\\"), .command("cr"), .command("hline"):
                _ = nextToken()
                errors.append("row break inside \\left … \\right")
            default:
                errors.append("missing \\right")
                return .leftRight(left: left, body: body, right: "")
            }
        }
    }

    private mutating func parseSizedDelimiter(_ name: String) -> AgentMathNode {
        var base = name
        var atomClass = AgentMathAtomClass.ord
        if let last = base.last, ["l", "r", "m"].contains(last), base != "big", base != "Big" {
            base.removeLast()
            atomClass = last == "l" ? .open : last == "r" ? .close : .rel
        }
        let size = ["big": 1, "Big": 2, "bigg": 3, "Bigg": 4][base] ?? 1
        let delimiter = readDelimiter()
        if atomClass == .ord {
            atomClass = AgentMathSymbols.atomClass(of: delimiter.first ?? " ")
        }
        return .sizedDelimiter(delimiter, size: size, atomClass)
    }

    private mutating func parseEnvironment() -> AgentMathNode {
        let name = readRawGroup()
        let delimiters: [String: (String, String)] = [
            "pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "Bmatrix": ("{", "}"), "vmatrix": ("|", "|"),
            "Vmatrix": ("‖", "‖"),
        ]
        switch name {
        case "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix",
             "pmatrix*", "bmatrix*", "matrix*":
            _ = readOptionalBracketText()
            let rows = parseRows(environment: name)
            let kind: AgentMathArray.Kind = name == "smallmatrix" ? .smallMatrix : .matrix
            let array = AgentMathNode.array(AgentMathArray(kind: kind, rows: rows.rows, horizontalRules: rows.horizontalRules))
            let base = name.hasSuffix("*") ? String(name.dropLast()) : name
            guard let (left, right) = delimiters[base] else { return array }
            return .leftRight(left: left, body: [array], right: right)
        case "cases", "dcases", "rcases":
            let rows = parseRows(environment: name)
            let array = AgentMathNode.array(AgentMathArray(kind: .cases, rows: rows.rows, horizontalRules: rows.horizontalRules))
            if name == "rcases" { return .leftRight(left: "", body: [array], right: "}") }
            return .leftRight(left: "{", body: [array], right: "")
        case "aligned", "align", "align*", "alignat", "alignat*", "alignedat", "split", "eqnarray",
             "eqnarray*", "flalign", "flalign*":
            if name.hasPrefix("alignat") || name == "alignedat" { _ = readRawGroup() }
            let rows = parseRows(environment: name)
            return .array(AgentMathArray(kind: .aligned, rows: rows.rows, horizontalRules: rows.horizontalRules))
        case "gather", "gather*", "gathered", "multline", "multline*":
            let rows = parseRows(environment: name)
            return .array(AgentMathArray(kind: .gather, rows: rows.rows, horizontalRules: rows.horizontalRules))
        case "array", "darray", "subarray":
            let spec = parseColumnSpec(readRawGroup())
            let rows = parseRows(environment: name)
            return .array(AgentMathArray(
                kind: .array, rows: rows.rows, columns: spec.columns,
                verticalRules: spec.rules, horizontalRules: rows.horizontalRules
            ))
        case "equation", "equation*", "displaymath", "math":
            let rows = parseRows(environment: name)
            if rows.rows.count == 1, rows.rows[0].count == 1 { return rows.rows[0][0] }
            return .array(AgentMathArray(kind: .gather, rows: rows.rows, horizontalRules: rows.horizontalRules))
        default:
            errors.append("unknown environment \(name)")
            let rows = parseRows(environment: name)
            let body = AgentMathNode.array(AgentMathArray(kind: .matrix, rows: rows.rows))
            return .group([.error("\\begin{\(name)}"), body, .error("\\end{\(name)}")])
        }
    }

    private func parseColumnSpec(_ spec: String) -> (columns: [AgentMathColumnAlignment], rules: Set<Int>) {
        var columns: [AgentMathColumnAlignment] = []
        var rules: Set<Int> = []
        var skipDepth = 0
        for character in spec {
            if skipDepth > 0 {
                if character == "{" { skipDepth += 1 }
                if character == "}" { skipDepth -= 1 }
                continue
            }
            switch character {
            case "l": columns.append(.left)
            case "c": columns.append(.center)
            case "r": columns.append(.right)
            case "p", "m", "b":
                columns.append(.left)
            case "{":
                skipDepth = 1
            case "|", ":":
                rules.insert(columns.count)
            default:
                break
            }
        }
        return (columns, rules)
    }

    /// `\overset{a}{=}` is a relation when its base is one, otherwise ordinary.
    private static func binRelClass(of node: AgentMathNode) -> AgentMathAtomClass {
        switch node {
        case .symbol(_, let atomClass) where atomClass == .rel || atomClass == .bin:
            return atomClass
        case .group(let nodes) where nodes.count == 1:
            return binRelClass(of: nodes[0])
        default:
            return .ord
        }
    }
}
