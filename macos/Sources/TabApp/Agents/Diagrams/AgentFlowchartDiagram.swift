import AppKit

/// A Mermaid flowchart (`flowchart` or `graph`), parsed into nodes, edges and subgraphs and drawn
/// natively with the layered graph layout.
struct AgentFlowchartDiagram: AgentDiagramDocument {
    static let keywords: Set<String> = ["flowchart", "graph"]

    /// Limits that keep untrusted sources cheap to parse and draw.
    static let maximumSourceLength = 200_000
    static let maximumNodes = 1_500
    static let maximumEdges = 3_000
    static let maximumSubgraphs = 300

    typealias Shape = AgentGraphScene.Shape

    struct Node: Equatable {
        var id: String
        var label: String
        var shape: Shape
        /// Classes from `:::name` and `class` statements, in order.
        var classes: [String]
        var style: AgentDiagramNodeStyle
        /// The subgraph that first mentioned the node.
        var subgraph: Int?
    }

    struct Edge: Equatable {
        var from: String
        var to: String
        var label: String?
        var stroke: AgentGraphScene.Stroke
        var startHead: AgentGraphScene.Head
        var endHead: AgentGraphScene.Head
        /// Mermaid's extra dashes: 1 for `-->`, 2 for `--->`.
        var length: Int
    }

    struct Subgraph: Equatable {
        var id: String
        var title: String
        var parent: Int?
        var direction: AgentGraphDirection?
        var classes: [String]
        var style: AgentDiagramNodeStyle
    }

    private(set) var direction: AgentGraphDirection
    /// Nodes in order of first mention, excluding subgraph ids.
    private(set) var nodes: [Node]
    private(set) var edges: [Edge]
    private(set) var subgraphs: [Subgraph]

    init(source: String) throws {
        var parser = AgentFlowchartParser()
        try parser.parse(source)
        direction = parser.direction
        subgraphs = parser.subgraphs
        let subgraphIDs = Set(parser.subgraphs.map(\.id))
        nodes = parser.nodes.filter { !subgraphIDs.contains($0.id) }
        edges = parser.edges
        for index in nodes.indices {
            let assigned = parser.classAssignments[nodes[index].id] ?? []
            nodes[index].classes += assigned
            let classStyle = parser.classes.style(for: nodes[index].classes)
            nodes[index].style = classStyle.merged(with: parser.styleAssignments[nodes[index].id] ?? AgentDiagramNodeStyle())
        }
        for index in subgraphs.indices {
            subgraphs[index].classes += parser.classAssignments[subgraphs[index].id] ?? []
            var style = AgentDiagramNodeStyle()
            for name in subgraphs[index].classes { style = style.merged(with: parser.classes.style(for: [name])) }
            subgraphs[index].style = style.merged(with: parser.styleAssignments[subgraphs[index].id] ?? AgentDiagramNodeStyle())
        }
    }

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    /// The diagram as a drawable scene.
    var scene: AgentGraphScene {
        var scene = AgentGraphScene()
        scene.direction = direction
        var nodeIndex: [String: Int] = [:]
        for (index, node) in nodes.enumerated() {
            nodeIndex[node.id] = index
            scene.nodes.append(.init(label: node.label, shape: node.shape, cluster: node.subgraph, style: node.style))
        }
        var subgraphIndex: [String: Int] = [:]
        for (index, subgraph) in subgraphs.enumerated() {
            subgraphIndex[subgraph.id] = index
            scene.clusters.append(.init(title: subgraph.title, parent: subgraph.parent, direction: subgraph.direction, style: subgraph.style))
        }
        func endpoint(_ id: String) -> AgentGraphLayoutInput.Endpoint? {
            if let index = subgraphIndex[id] { return .cluster(index) }
            return nodeIndex[id].map { .node($0) }
        }
        for edge in edges {
            guard let from = endpoint(edge.from), let to = endpoint(edge.to) else { continue }
            scene.edges.append(.init(from: from, to: to, label: edge.label, stroke: edge.stroke,
                                     startHead: edge.startHead, endHead: edge.endHead, minLength: edge.length))
        }
        return scene
    }

    func layout(maxWidth: CGFloat, style: AgentDiagramStyle) -> AgentDiagramLayout {
        scene.layout(maxWidth: maxWidth, style: style)
    }
}

// MARK: - Parser

struct AgentFlowchartParser {
    var direction: AgentGraphDirection = .topToBottom
    var nodes: [AgentFlowchartDiagram.Node] = []
    var edges: [AgentFlowchartDiagram.Edge] = []
    var subgraphs: [AgentFlowchartDiagram.Subgraph] = []
    var classes = AgentDiagramClassRegistry()
    var classAssignments: [String: [String]] = [:]
    var styleAssignments: [String: AgentDiagramNodeStyle] = [:]

    private var nodeIndex: [String: Int] = [:]
    private var subgraphIndex: [String: Int] = [:]
    private var openSubgraphs: [Int] = []
    private var line = 0

    private func error(_ message: String) -> AgentDiagramError {
        AgentDiagramError(message: message, line: line)
    }

    mutating func parse(_ source: String) throws {
        guard source.utf8.count <= AgentFlowchartDiagram.maximumSourceLength else {
            throw AgentDiagramError(message: "The flowchart is too large to draw.", line: nil)
        }
        var sawHeader = false
        for (offset, rawLine) in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            line = offset + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("%%") { continue }
            for statement in Self.statements(in: Self.strippingComment(trimmed)) {
                if !sawHeader {
                    sawHeader = true
                    try parseHeader(statement)
                    continue
                }
                try parseStatement(statement)
            }
        }
        guard sawHeader else { throw AgentDiagramError(message: "Missing flowchart header.", line: nil) }
        if !openSubgraphs.isEmpty {
            throw AgentDiagramError(message: "Subgraph “\(subgraphs[openSubgraphs[openSubgraphs.count - 1]].id)” is missing its end.", line: line)
        }
    }

    private mutating func parseHeader(_ statement: String) throws {
        let words = statement.split(maxSplits: 2, whereSeparator: \.isWhitespace).map(String.init)
        guard let keyword = words.first?.lowercased(), ["flowchart", "graph", "flowchart-elk"].contains(keyword) else {
            throw error("Expected “flowchart” or “graph”.")
        }
        guard words.count > 1 else { return }
        guard let parsed = AgentGraphDirection(mermaid: words[1]) else {
            // `graph` followed directly by a statement.
            try parseStatement(words.dropFirst().joined(separator: " "))
            return
        }
        direction = parsed
        if words.count > 2 { try parseStatement(words[2]) }
    }

    /// Drops a trailing `%%` comment outside quotes and labels.
    static func strippingComment(_ line: String) -> String {
        guard line.contains("%%") else { return line }
        var inQuote = false
        var previous: Character = " "
        var result = ""
        for character in line {
            if character == "\"" { inQuote.toggle() }
            if !inQuote, character == "%", previous == "%" {
                result.removeLast()
                return result
            }
            result.append(character)
            previous = character
        }
        return result
    }

    /// Splits a line at `;` outside quotes, brackets, pipe labels and `#entity;` codes.
    static func statements(in line: String) -> [String] {
        let characters = Array(line)
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inQuote = false
        var inPipe = false
        for (index, character) in characters.enumerated() {
            switch character {
            case "\"": inQuote.toggle()
            case "[", "(", "{": if !inQuote { depth += 1 }
            case "]", ")", "}": if !inQuote { depth = max(0, depth - 1) }
            case "|": if !inQuote && depth == 0 { inPipe.toggle() }
            case ";":
                if !inQuote, !inPipe, depth == 0, !Self.closesEntity(characters, at: index) {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { parts.append(trimmed) }
                    current = ""
                    continue
                }
            default: break
            }
            current.append(character)
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts
    }

    private static func closesEntity(_ characters: [Character], at index: Int) -> Bool {
        var cursor = index - 1
        var length = 0
        while cursor >= 0, characters[cursor].isLetter || characters[cursor].isNumber, length <= 10 {
            cursor -= 1
            length += 1
        }
        return length > 0 && cursor >= 0 && (characters[cursor] == "#" || characters[cursor] == "&")
    }

    // MARK: Statements

    private mutating func parseStatement(_ statement: String) throws {
        let firstWord = statement.prefix { !$0.isWhitespace }
        let rest = statement.dropFirst(firstWord.count).trimmingCharacters(in: .whitespaces)
        switch firstWord.lowercased() {
        case "subgraph":
            try openSubgraph(rest)
        case "end":
            guard openSubgraphs.popLast() != nil else { throw error("“end” without a matching subgraph.") }
        case "direction":
            guard let parsed = AgentGraphDirection(mermaid: rest) else { throw error("Unknown direction “\(rest)”.") }
            if let current = openSubgraphs.last {
                subgraphs[current].direction = parsed
            } else {
                direction = parsed
            }
        case "style":
            let parts = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { return }
            let id = String(parts[0])
            styleAssignments[id] = (styleAssignments[id] ?? AgentDiagramNodeStyle()).merged(with: AgentDiagramNodeStyle(declarations: String(parts[1])))
        case "classdef":
            _ = classes.define(rest)
        case "class":
            let parts = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { return }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            for id in parts[0].split(separator: ",") { classAssignments[String(id), default: []].append(name) }
        case "click", "linkstyle", "acctitle", "acctitle:", "accdescr", "accdescr:", "interpolate":
            return
        default:
            if firstWord.lowercased().hasPrefix("acctitle") || firstWord.lowercased().hasPrefix("accdescr") { return }
            try parseGraphStatement(statement)
        }
    }

    private mutating func openSubgraph(_ rest: String) throws {
        guard subgraphs.count < AgentFlowchartDiagram.maximumSubgraphs else { throw error("Too many subgraphs.") }
        var id: String
        var title: String
        if rest.isEmpty {
            id = "subgraph\(subgraphs.count)"
            title = ""
        } else if rest.hasPrefix("\"") {
            title = AgentDiagramLabelText.decode(rest)
            id = "subgraph\(subgraphs.count)"
        } else if let open = rest.firstIndex(of: "["), rest.hasSuffix("]") {
            id = rest[..<open].trimmingCharacters(in: .whitespaces)
            title = AgentDiagramLabelText.decode(String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]))
            if id.isEmpty { id = "subgraph\(subgraphs.count)" }
        } else {
            id = rest
            title = AgentDiagramLabelText.decode(rest)
        }
        if let existing = subgraphIndex[id] {
            openSubgraphs.append(existing)
            return
        }
        let index = subgraphs.count
        subgraphs.append(.init(id: id, title: title, parent: openSubgraphs.last, direction: nil, classes: [], style: AgentDiagramNodeStyle()))
        subgraphIndex[id] = index
        openSubgraphs.append(index)
    }

    // MARK: Nodes and edges

    private mutating func parseGraphStatement(_ statement: String) throws {
        var scanner = AgentFlowchartScanner(statement)
        var group = try parseGroup(&scanner)
        while true {
            scanner.skipSpaces()
            if scanner.isAtEnd { return }
            guard let link = try scanner.link(line: line) else {
                throw error("Unexpected “\(scanner.remainder.prefix(20))”.")
            }
            scanner.skipSpaces()
            let next = try parseGroup(&scanner)
            for from in group {
                for to in next {
                    guard edges.count < AgentFlowchartDiagram.maximumEdges else { throw error("The flowchart has too many edges.") }
                    edges.append(.init(from: from, to: to, label: link.label, stroke: link.stroke,
                                       startHead: link.startHead, endHead: link.endHead, length: link.length))
                }
            }
            group = next
        }
    }

    private mutating func parseGroup(_ scanner: inout AgentFlowchartScanner) throws -> [String] {
        var ids: [String] = []
        while true {
            scanner.skipSpaces()
            guard let reference = try scanner.nodeReference(line: line) else {
                throw error(scanner.isAtEnd ? "Expected a node after the edge." : "Unexpected “\(scanner.remainder.prefix(20))”.")
            }
            try define(reference)
            ids.append(reference.id)
            scanner.skipSpaces()
            guard scanner.consume("&") else { return ids }
        }
    }

    private mutating func define(_ reference: AgentFlowchartScanner.NodeReference) throws {
        let index: Int
        if let existing = nodeIndex[reference.id] {
            index = existing
        } else {
            guard nodes.count < AgentFlowchartDiagram.maximumNodes else { throw error("The flowchart has too many nodes.") }
            index = nodes.count
            nodes.append(.init(id: reference.id, label: reference.id, shape: .rectangle, classes: [], style: AgentDiagramNodeStyle(), subgraph: nil))
            nodeIndex[reference.id] = index
        }
        if let label = reference.label { nodes[index].label = label }
        if let shape = reference.shape { nodes[index].shape = shape }
        if let className = reference.className { nodes[index].classes.append(className) }
        if nodes[index].subgraph == nil, let current = openSubgraphs.last, subgraphs[current].id != reference.id {
            nodes[index].subgraph = current
        }
    }
}

// MARK: - Scanner

/// Reads node references and links from one flowchart statement.
struct AgentFlowchartScanner {
    struct NodeReference {
        var id: String
        var label: String?
        var shape: AgentGraphScene.Shape?
        var className: String?
    }

    struct Link: Equatable {
        var stroke: AgentGraphScene.Stroke
        var startHead: AgentGraphScene.Head
        var endHead: AgentGraphScene.Head
        var length: Int
        var label: String?
    }

    private let characters: [Character]
    private var index = 0

    init(_ text: String) {
        characters = Array(text)
    }

    var isAtEnd: Bool { index >= characters.count }
    var remainder: String { isAtEnd ? "" : String(characters[index...]) }

    private func peek(_ offset: Int = 0) -> Character? {
        let position = index + offset
        return position < characters.count ? characters[position] : nil
    }

    private func matches(_ text: String, at position: Int? = nil) -> Bool {
        var cursor = position ?? index
        for character in text {
            guard cursor < characters.count, characters[cursor] == character else { return false }
            cursor += 1
        }
        return true
    }

    mutating func skipSpaces() {
        while let character = peek(), character.isWhitespace { index += 1 }
    }

    mutating func consume(_ text: String) -> Bool {
        guard matches(text) else { return false }
        index += text.count
        return true
    }

    private static func isIDCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$" || character == "'"
    }

    // MARK: Node references

    mutating func nodeReference(line: Int) throws -> NodeReference? {
        let start = index
        while let character = peek(), index - start < 200 {
            if Self.isIDCharacter(character) {
                index += 1
            } else if character == "-" || character == ".", let next = peek(1), Self.isIDCharacter(next),
                      index > start, !(character == "-" && (next == "o" || next == "x") && peek(2) == "-") {
                index += 1
            } else {
                break
            }
        }
        guard index > start else { return nil }
        var reference = NodeReference(id: String(characters[start..<index]))
        if matches("@{") {
            try readShapeData(into: &reference, line: line)
        } else if let (shape, label) = try readShape(line: line) {
            reference.shape = shape
            reference.label = AgentDiagramLabelText.decode(label)
        }
        if consume(":::") {
            let classStart = index
            while let character = peek(), Self.isIDCharacter(character) || character == "-" { index += 1 }
            if index > classStart { reference.className = String(characters[classStart..<index]) }
        }
        return reference
    }

    private static let shapes: [(open: String, close: String, shape: AgentGraphScene.Shape)] = [
        ("(((", ")))", .doubleCircle), ("((", "))", .circle), ("([", "])", .stadium), ("[[", "]]", .subroutine),
        ("[(", ")]", .cylinder), ("{{", "}}", .hexagon), ("(", ")", .rounded), ("{", "}", .diamond), (">", "]", .asymmetric),
    ]

    private mutating func readShape(line: Int) throws -> (AgentGraphScene.Shape, String)? {
        if matches("[/") || matches("[\\") {
            let leading = characters[index + 1]
            index += 2
            guard let (label, closer) = readText(until: ["/]", "\\]"]) else {
                throw AgentDiagramError(message: "Unclosed node shape.", line: line)
            }
            let shape: AgentGraphScene.Shape
            switch (leading, closer) {
            case ("/", "/]"): shape = .parallelogram
            case ("\\", "\\]"): shape = .parallelogramAlt
            case ("/", _): shape = .trapezoid
            default: shape = .trapezoidAlt
            }
            return (shape, label)
        }
        for candidate in Self.shapes where matches(candidate.open) {
            index += candidate.open.count
            guard let (label, _) = readText(until: [candidate.close]) else {
                throw AgentDiagramError(message: "Unclosed node shape; expected “\(candidate.close)”.", line: line)
            }
            return (candidate.shape, label)
        }
        if matches("[") {
            index += 1
            guard let (label, _) = readText(until: ["]"]) else {
                throw AgentDiagramError(message: "Unclosed node shape; expected “]”.", line: line)
            }
            return (.rectangle, label)
        }
        return nil
    }

    /// Reads text up to the first of `closers` (consumed), honoring quotes and nested brackets.
    private mutating func readText(until closers: [String]) -> (String, String)? {
        let start = index
        if peek() == "\"" {
            var cursor = index + 1
            while cursor < characters.count, characters[cursor] != "\"" { cursor += 1 }
            if cursor < characters.count {
                var after = cursor + 1
                while after < characters.count, characters[after] == " " { after += 1 }
                for closer in closers where matches(closer, at: after) {
                    index = after + closer.count
                    return (String(characters[start...cursor]), closer)
                }
            }
        }
        var depth = 0
        var inQuote = false
        var cursor = index
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\"" { inQuote.toggle() }
            if !inQuote {
                if depth == 0 {
                    for closer in closers where matches(closer, at: cursor) {
                        index = cursor + closer.count
                        return (String(characters[start..<cursor]), closer)
                    }
                }
                if "([{".contains(character) { depth += 1 }
                if ")]}".contains(character) { depth = max(0, depth - 1) }
            }
            cursor += 1
        }
        return nil
    }

    private static let namedShapes: [String: AgentGraphScene.Shape] = [
        "rect": .rectangle, "rectangle": .rectangle, "proc": .rectangle, "process": .rectangle,
        "rounded": .rounded, "event": .rounded, "stadium": .stadium, "pill": .stadium, "terminal": .stadium,
        "subproc": .subroutine, "subroutine": .subroutine, "fr-rect": .subroutine,
        "cyl": .cylinder, "cylinder": .cylinder, "database": .cylinder, "db": .cylinder,
        "circle": .circle, "circ": .circle, "dbl-circ": .doubleCircle, "double-circle": .doubleCircle,
        "diam": .diamond, "diamond": .diamond, "decision": .diamond, "question": .diamond,
        "hex": .hexagon, "hexagon": .hexagon, "prepare": .hexagon,
        "lean-r": .parallelogram, "lean-right": .parallelogram, "in-out": .parallelogram,
        "lean-l": .parallelogramAlt, "lean-left": .parallelogramAlt, "out-in": .parallelogramAlt,
        "trap-b": .trapezoid, "trapezoid": .trapezoid, "priority": .trapezoid,
        "trap-t": .trapezoidAlt, "inv-trapezoid": .trapezoidAlt, "manual": .trapezoidAlt, "odd": .asymmetric,
    ]

    /// Mermaid's `id@{ shape: …, label: "…" }` node data.
    private mutating func readShapeData(into reference: inout NodeReference, line: Int) throws {
        index += 2
        guard let (body, _) = readText(until: ["}"]) else {
            throw AgentDiagramError(message: "Unclosed node data; expected “}”.", line: line)
        }
        for entry in AgentDiagramNodeStyle.splitTopLevel(body, separators: [","]) {
            guard let colon = entry.firstIndex(of: ":") else { continue }
            let key = entry[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "shape": reference.shape = Self.namedShapes[value.lowercased()] ?? .rectangle
            case "label": reference.label = AgentDiagramLabelText.decode(value)
            default: continue
            }
        }
        if reference.shape == nil { reference.shape = .rectangle }
    }

    // MARK: Links

    private func isHeadBoundary(at position: Int) -> Bool {
        guard position < characters.count else { return true }
        let character = characters[position]
        return character.isWhitespace || character == "|" || !Self.isIDCharacter(character)
    }

    /// Reads a link such as `-->`, `-.->`, `==>`, `---`, `--o`, `<-->`, `-- text -->` and a trailing `|label|`.
    mutating func link(line: Int) throws -> Link? {
        let start = index
        var startHead: AgentGraphScene.Head = .none
        if let first = peek() {
            let previousIsSpace = index == 0 || characters[index - 1].isWhitespace
            if first == "<", let next = peek(1), "-=.".contains(next) {
                startHead = .arrow
                index += 1
            } else if (first == "o" || first == "x"), previousIsSpace, let next = peek(1), let after = peek(2),
                      "-=".contains(next), "-=.".contains(after) {
                startHead = first == "o" ? .circle : .cross
                index += 1
            }
        }

        // Invisible links.
        if matches("~~~") {
            var count = 0
            while peek() == "~" { index += 1; count += 1 }
            return finish(Link(stroke: .invisible, startHead: .none, endHead: .none, length: max(1, min(count - 2, 8))))
        }

        let runStart = index
        while let character = peek(), "-=.".contains(character), index - runStart < 40 { index += 1 }
        let run = Array(characters[runStart..<index])
        guard run.count >= 2 else {
            index = start
            return nil
        }
        let thick = run.allSatisfy { $0 == "=" }
        let dotted = run.contains(".")
        guard thick || run.allSatisfy({ $0 == "-" || $0 == "." }) else {
            index = start
            return nil
        }
        let stroke: AgentGraphScene.Stroke = thick ? .thick : dotted ? .dotted : .solid
        let endHead = readHead()

        // An opening `--`, `-.` or `==` followed by text: `-- text -->`.
        let isTextOpening = endHead == .none && (run == ["-", "-"] || run == ["-", "."] || run == ["=", "="])
        if isTextOpening, peek().map({ !"-=.>".contains($0) }) ?? false {
            return try textLink(stroke: stroke, startHead: startHead, line: line)
        }
        if dotted {
            guard run.first == "-", run.last == "-" || endHead != .none else {
                index = start
                return nil
            }
        }
        let length: Int
        if dotted {
            length = run.filter { $0 == "." }.count
        } else {
            length = endHead == .none ? run.count - 2 : run.count - 1
        }
        return finish(Link(stroke: stroke, startHead: startHead, endHead: endHead, length: max(1, min(length, 8))))
    }

    private mutating func readHead() -> AgentGraphScene.Head {
        guard let character = peek() else { return .none }
        if character == ">" {
            index += 1
            return .arrow
        }
        if (character == "o" || character == "x"), isHeadBoundary(at: index + 1) {
            index += 1
            return character == "o" ? .circle : .cross
        }
        return .none
    }

    private mutating func textLink(stroke: AgentGraphScene.Stroke, startHead: AgentGraphScene.Head, line: Int) throws -> Link? {
        let textStart = index
        var cursor = index
        while cursor < characters.count {
            let close = closingLink(at: cursor, stroke: stroke)
            if let close, cursor > textStart {
                let label = AgentDiagramLabelText.decode(String(characters[textStart..<cursor]))
                index = close.end
                var link = Link(stroke: stroke, startHead: startHead, endHead: close.head, length: close.length,
                                label: label.isEmpty ? nil : label)
                link = finish(link)
                return link
            }
            cursor += 1
        }
        throw AgentDiagramError(message: "Edge text is missing its closing arrow.", line: line)
    }

    /// Recognizes the closing half of a text link, `-->`, `---`, `.->`, `==>`, at `position`.
    private func closingLink(at position: Int, stroke: AgentGraphScene.Stroke) -> (end: Int, head: AgentGraphScene.Head, length: Int)? {
        var cursor = position
        switch stroke {
        case .dotted:
            var dots = 0
            while cursor < characters.count, characters[cursor] == "." { dots += 1; cursor += 1 }
            guard dots > 0, cursor < characters.count, characters[cursor] == "-" else { return nil }
            cursor += 1
            return closingHead(at: cursor, length: dots, requiresHead: false)
        case .thick, .solid, .invisible:
            let symbol: Character = stroke == .thick ? "=" : "-"
            var count = 0
            while cursor < characters.count, characters[cursor] == symbol { count += 1; cursor += 1 }
            guard count >= 2 else { return nil }
            if let headed = closingHead(at: cursor, length: count - 1, requiresHead: true) { return headed }
            guard count >= 3 else { return nil }
            return (cursor, .none, max(1, min(count - 2, 8)))
        }
    }

    private func closingHead(at cursor: Int, length: Int, requiresHead: Bool) -> (end: Int, head: AgentGraphScene.Head, length: Int)? {
        let clamped = max(1, min(length, 8))
        if cursor < characters.count {
            let character = characters[cursor]
            if character == ">" { return (cursor + 1, .arrow, clamped) }
            if (character == "o" || character == "x"), isHeadBoundary(at: cursor + 1) {
                return (cursor + 1, character == "o" ? .circle : .cross, clamped)
            }
        }
        return requiresHead ? nil : (cursor, .none, clamped)
    }

    /// Reads an optional `|label|` after a link.
    private mutating func finish(_ link: Link) -> Link {
        var result = link
        let save = index
        skipSpaces()
        guard peek() == "|" else {
            index = save
            return result
        }
        var cursor = index + 1
        while cursor < characters.count, characters[cursor] != "|" { cursor += 1 }
        guard cursor < characters.count else {
            index = save
            return result
        }
        let label = AgentDiagramLabelText.decode(String(characters[(index + 1)..<cursor]))
        result.label = label.isEmpty ? nil : label
        index = cursor + 1
        return result
    }
}
