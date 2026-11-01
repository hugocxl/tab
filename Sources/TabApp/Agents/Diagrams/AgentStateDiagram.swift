import AppKit

/// A Mermaid state diagram (`stateDiagram` or `stateDiagram-v2`): states, transitions, start and
/// end markers, composite states with concurrent regions, fork/join bars, choices and notes,
/// drawn with the layered graph layout.
struct AgentStateDiagram: AgentDiagramDocument {
    static let keywords: Set<String> = ["statediagram", "statediagram-v2"]

    static let maximumSourceLength = 200_000
    static let maximumStates = 1_500
    static let maximumTransitions = 3_000
    static let maximumComposites = 300

    enum Kind: Equatable { case state, start, end, fork, join, choice, note }

    struct State: Equatable {
        var id: String
        var label: String
        var kind: Kind
        /// The composite or region the state belongs to.
        var scope: Int?
        var classes: [String] = []
        var style = AgentDiagramNodeStyle()
        /// For notes: the state the note sits beside, and whether on its right.
        var noteTarget: String?
        var noteOnRight = true
    }

    struct Transition: Equatable {
        var from: String
        var to: String
        var label: String?
    }

    /// A composite state, or one concurrent region of a composite.
    struct Composite: Equatable {
        var id: String
        var title: String
        var parent: Int?
        var direction: AgentGraphDirection?
        var isRegion: Bool
    }

    private(set) var direction: AgentGraphDirection = .topToBottom
    /// States in order of first mention, excluding composite states.
    private(set) var states: [State] = []
    private(set) var transitions: [Transition] = []
    private(set) var composites: [Composite] = []

    init(source: String) throws {
        var parser = AgentStateParser()
        try parser.parse(source)
        direction = parser.direction
        composites = parser.composites
        let compositeIDs = Set(parser.composites.filter { !$0.isRegion }.map(\.id))
        states = parser.states.filter { !compositeIDs.contains($0.id) }
        transitions = parser.transitions
        for index in states.indices {
            states[index].classes += parser.classAssignments[states[index].id] ?? []
            states[index].style = parser.classes.style(for: states[index].classes)
        }
    }

    func state(_ id: String) -> State? { states.first { $0.id == id } }

    /// The diagram as a drawable scene.
    var scene: AgentGraphScene {
        var scene = AgentGraphScene()
        scene.direction = direction
        var compositeIndex: [String: Int] = [:]
        var hasRegions = Array(repeating: false, count: composites.count)
        for (index, composite) in composites.enumerated() {
            if !composite.isRegion { compositeIndex[composite.id] = index }
            if composite.isRegion, let parent = composite.parent, parent < composites.count { hasRegions[parent] = true }
        }
        func effectiveDirection(_ index: Int?) -> AgentGraphDirection {
            var current = index
            var steps = 0
            while let scope = current, scope < composites.count, steps <= composites.count {
                if let direction = composites[scope].direction { return direction }
                current = composites[scope].parent
                steps += 1
            }
            return direction
        }
        for (index, composite) in composites.enumerated() {
            var cluster = AgentGraphScene.Cluster(title: composite.isRegion ? "" : composite.title, parent: composite.parent,
                                                  direction: composite.direction, isRegion: composite.isRegion)
            if hasRegions[index] {
                // Regions sit side by side; each keeps the composite's own flow.
                cluster.direction = .topToBottom
            }
            if composite.isRegion { cluster.direction = effectiveDirection(composite.parent) }
            scene.clusters.append(cluster)
        }

        var stateIndex: [String: Int] = [:]
        for (index, state) in states.enumerated() { stateIndex[state.id] = index }
        func endpoint(_ id: String) -> AgentGraphLayoutInput.Endpoint? {
            if let index = compositeIndex[id] { return .cluster(index) }
            return stateIndex[id].map { .node($0) }
        }
        func itemScope(_ id: String) -> Int? {
            if let index = compositeIndex[id] { return composites[index].parent }
            return stateIndex[id].flatMap { states[$0].scope }
        }

        for state in states {
            let shape: AgentGraphScene.Shape
            switch state.kind {
            case .state: shape = .state
            case .start: shape = .start
            case .end: shape = .end
            case .fork, .join: shape = .forkBar
            case .choice: shape = .choice
            case .note: shape = .note
            }
            var node = AgentGraphScene.Node(label: shape == .state || shape == .note ? state.label : "", shape: shape,
                                            cluster: state.scope, style: state.style)
            if state.kind == .note, let target = state.noteTarget, let anchor = endpoint(target) {
                node.cluster = itemScope(target)
                node.anchor = .init(target: anchor, after: state.noteOnRight)
            }
            scene.nodes.append(node)
        }
        for transition in transitions {
            guard let from = endpoint(transition.from), let to = endpoint(transition.to) else { continue }
            scene.edges.append(.init(from: from, to: to, label: transition.label))
        }
        for (index, state) in states.enumerated() where state.kind == .note {
            guard let target = state.noteTarget, let anchor = endpoint(target) else { continue }
            scene.edges.append(.init(from: anchor, to: .node(index), stroke: .dotted, endHead: .none))
        }
        return scene
    }

    func layout(maxWidth: CGFloat, style: AgentDiagramStyle) -> AgentDiagramLayout {
        scene.layout(maxWidth: maxWidth, style: style)
    }
}

// MARK: - Parser

struct AgentStateParser {
    var direction: AgentGraphDirection = .topToBottom
    var states: [AgentStateDiagram.State] = []
    var transitions: [AgentStateDiagram.Transition] = []
    var composites: [AgentStateDiagram.Composite] = []
    var classes = AgentDiagramClassRegistry()
    var classAssignments: [String: [String]] = [:]

    private var stateIndex: [String: Int] = [:]
    private var compositeIndex: [String: Int] = [:]
    /// Open composites, each with its current region when it has `--` separators.
    private var stack: [(composite: Int, region: Int?)] = []
    private var line = 0
    private var pendingNote: (index: Int, lines: [String])?

    private var currentScope: Int? {
        guard let top = stack.last else { return nil }
        return top.region ?? top.composite
    }

    private func error(_ message: String) -> AgentDiagramError {
        AgentDiagramError(message: message, line: line)
    }

    mutating func parse(_ source: String) throws {
        guard source.utf8.count <= AgentStateDiagram.maximumSourceLength else {
            throw AgentDiagramError(message: "The state diagram is too large to draw.", line: nil)
        }
        var sawHeader = false
        for (offset, rawLine) in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            line = offset + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let note = pendingNote {
                if trimmed.lowercased() == "end note" {
                    states[note.index].label = AgentDiagramLabelText.decode(note.lines.joined(separator: "\n"))
                    pendingNote = nil
                } else if note.lines.count < 60 {
                    pendingNote?.lines.append(trimmed)
                }
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("%%") { continue }
            let statement = AgentFlowchartParser.strippingComment(trimmed).trimmingCharacters(in: .whitespaces)
            for part in statement.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                if !sawHeader {
                    sawHeader = true
                    let keyword = part.prefix { !$0.isWhitespace }.lowercased()
                    guard keyword == "statediagram" || keyword == "statediagram-v2" else {
                        throw error("Expected “stateDiagram”.")
                    }
                    continue
                }
                try parseStatement(part)
            }
        }
        guard sawHeader else { throw AgentDiagramError(message: "Missing state diagram header.", line: nil) }
        if pendingNote != nil { throw AgentDiagramError(message: "Note is missing “end note”.", line: line) }
        if let open = stack.last {
            throw AgentDiagramError(message: "State “\(composites[open.composite].id)” is missing its closing “}”.", line: line)
        }
    }

    // MARK: Statements

    private mutating func parseStatement(_ statement: String) throws {
        let firstWord = statement.prefix { !$0.isWhitespace }
        let lowered = firstWord.lowercased()
        let rest = statement.dropFirst(firstWord.count).trimmingCharacters(in: .whitespaces)

        if statement == "}" {
            guard stack.popLast() != nil else { throw error("Unexpected “}”.") }
            return
        }
        if statement == "--" {
            try splitRegion()
            return
        }
        switch lowered {
        case "direction":
            guard let parsed = AgentGraphDirection(mermaid: rest) else { throw error("Unknown direction “\(rest)”.") }
            if let scope = currentScope { composites[scope].direction = parsed } else { direction = parsed }
            return
        case "note":
            try parseNote(rest)
            return
        case "state":
            try parseStateDeclaration(rest)
            return
        case "classdef":
            _ = classes.define(rest)
            return
        case "class":
            let parts = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { return }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            for id in parts[0].split(separator: ",") { classAssignments[String(id), default: []].append(name) }
            return
        case "hide", "scale", "style", "click":
            return
        default:
            if lowered.hasPrefix("acctitle") || lowered.hasPrefix("accdescr") { return }
        }
        if let arrow = statement.range(of: "-->") {
            try parseTransition(source: String(statement[..<arrow.lowerBound]), rest: String(statement[arrow.upperBound...]))
            return
        }
        if let colon = Self.labelColon(in: statement) {
            let idPart = statement[..<colon].trimmingCharacters(in: .whitespaces)
            if Self.isValidID(idPart) {
                let text = AgentDiagramLabelText.decode(String(statement[statement.index(after: colon)...]))
                let index = try declare(idPart)
                if states[index].label == idPart || states[index].label.isEmpty {
                    states[index].label = text
                } else if !text.isEmpty {
                    states[index].label += "\n" + text
                }
                if let composite = compositeIndex[idPart], !text.isEmpty { composites[composite].title = text }
                return
            }
        }
        let (id, className) = Self.splitClass(statement)
        guard Self.isValidID(id) else { throw error("Unexpected “\(statement.prefix(30))”.") }
        let index = try declare(id)
        if let className { states[index].classes.append(className) }
    }

    private static func splitClass(_ text: String) -> (String, String?) {
        guard let range = text.range(of: ":::") else { return (text.trimmingCharacters(in: .whitespaces), nil) }
        let id = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let name = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return (id, name.isEmpty ? nil : name)
    }

    static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 200 else { return false }
        if id == "[*]" { return true }
        return id.allSatisfy { $0.isLetter || $0.isNumber || "_-.$".contains($0) }
    }

    private mutating func parseTransition(source: String, rest: String) throws {
        var target = rest
        var label: String?
        if let split = Self.labelColon(in: rest) {
            target = String(rest[..<split])
            let text = AgentDiagramLabelText.decode(String(rest[rest.index(after: split)...]))
            label = text.isEmpty ? nil : text
        }
        let (fromID, fromClass) = Self.splitClass(source)
        let (toID, toClass) = Self.splitClass(target)
        guard Self.isValidID(fromID) else { throw error("Invalid state “\(fromID.prefix(30))”.") }
        guard Self.isValidID(toID) else { throw error("Invalid state “\(toID.prefix(30))”.") }
        let from = try endpoint(fromID, isSource: true)
        let to = try endpoint(toID, isSource: false)
        if let fromClass { states[from].classes.append(fromClass) }
        if let toClass { states[to].classes.append(toClass) }
        guard transitions.count < AgentStateDiagram.maximumTransitions else { throw error("The state diagram has too many transitions.") }
        transitions.append(.init(from: states[from].id, to: states[to].id, label: label))
    }

    /// The index of the first `:` that is not part of a `:::` class marker.
    private static func labelColon(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == ":" {
                if text[index...].hasPrefix(":::") {
                    index = text.index(index, offsetBy: 3)
                    continue
                }
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private mutating func endpoint(_ id: String, isSource: Bool) throws -> Int {
        guard id == "[*]" else { return try declare(id) }
        let scopeKey = currentScope.map(String.init) ?? "root"
        let key = isSource ? "[*]start#\(scopeKey)" : "[*]end#\(scopeKey)"
        let index = try declare(key)
        states[index].kind = isSource ? .start : .end
        states[index].label = ""
        return index
    }

    @discardableResult
    private mutating func declare(_ id: String) throws -> Int {
        if let existing = stateIndex[id] { return existing }
        guard states.count < AgentStateDiagram.maximumStates else { throw error("The state diagram has too many states.") }
        let index = states.count
        states.append(.init(id: id, label: id, kind: .state, scope: currentScope))
        stateIndex[id] = index
        return index
    }

    private mutating func parseStateDeclaration(_ rest: String) throws {
        var text = rest
        var opensBlock = false
        if text.hasSuffix("{") {
            opensBlock = true
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        var id: String
        var label: String?
        if text.hasPrefix("\"") {
            // state "Description" as id
            let afterQuote = text.index(after: text.startIndex)
            guard let close = text[afterQuote...].firstIndex(of: "\"") else { throw error("Unclosed state description.") }
            label = AgentDiagramLabelText.decode(String(text[afterQuote..<close]))
            let remainder = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard remainder.lowercased().hasPrefix("as ") else { throw error("Expected “as” after the state description.") }
            id = remainder.dropFirst(3).trimmingCharacters(in: .whitespaces)
        } else {
            let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
            guard let first = parts.first else { throw error("Expected a state name.") }
            id = first
            if parts.count > 1 {
                let modifier = parts[1].trimmingCharacters(in: .whitespaces)
                let kind: AgentStateDiagram.Kind?
                switch modifier.lowercased() {
                case "<<fork>>", "[[fork]]": kind = .fork
                case "<<join>>", "[[join]]": kind = .join
                case "<<choice>>", "[[choice]]": kind = .choice
                default: kind = nil
                }
                if let kind {
                    let (cleanID, _) = Self.splitClass(id)
                    guard Self.isValidID(cleanID) else { throw error("Invalid state “\(cleanID.prefix(30))”.") }
                    let index = try declare(cleanID)
                    states[index].kind = kind
                    states[index].label = ""
                    return
                }
                if modifier.lowercased().hasPrefix("as ") {
                    label = AgentDiagramLabelText.decode(String(modifier.dropFirst(3)))
                } else if modifier.hasPrefix(":") {
                    label = AgentDiagramLabelText.decode(String(modifier.dropFirst()))
                } else {
                    throw error("Unexpected “\(modifier.prefix(30))”.")
                }
            }
        }
        let (cleanID, className) = Self.splitClass(id)
        id = cleanID
        guard Self.isValidID(id), id != "[*]" else { throw error("Invalid state “\(id.prefix(30))”.") }
        let index = try declare(id)
        if let label { states[index].label = label }
        if let className { states[index].classes.append(className) }
        guard opensBlock else { return }

        guard composites.count < AgentStateDiagram.maximumComposites else { throw error("Too many composite states.") }
        let composite: Int
        if let existing = compositeIndex[id] {
            composite = existing
        } else {
            composite = composites.count
            composites.append(.init(id: id, title: label ?? (states[index].label.isEmpty ? id : states[index].label),
                                    parent: currentScope, direction: nil, isRegion: false))
            compositeIndex[id] = composite
        }
        states[index].scope = currentScope
        composites[composite].parent = currentScope
        stack.append((composite, nil))
    }

    /// `--` inside a composite: the states so far form the first region, and a new region starts.
    private mutating func splitRegion() throws {
        guard let top = stack.last else { throw error("“--” is only allowed inside a composite state.") }
        guard composites.count + 2 <= AgentStateDiagram.maximumComposites else { throw error("Too many composite states.") }
        if top.region == nil {
            let first = composites.count
            composites.append(.init(id: "\(composites[top.composite].id)#region0", title: "", parent: top.composite, direction: nil, isRegion: true))
            for index in states.indices where states[index].scope == top.composite { states[index].scope = first }
            for index in composites.indices where index != first && composites[index].parent == top.composite {
                composites[index].parent = first
            }
        }
        let next = composites.count
        composites.append(.init(id: "\(composites[top.composite].id)#region\(next)", title: "", parent: top.composite, direction: nil, isRegion: true))
        stack[stack.count - 1].region = next
    }

    private mutating func parseNote(_ rest: String) throws {
        let lowered = rest.lowercased()
        if rest.hasPrefix("\"") {
            // note "text" as N: a floating note.
            let afterQuote = rest.index(after: rest.startIndex)
            guard let close = rest[afterQuote...].firstIndex(of: "\"") else { throw error("Unclosed note text.") }
            let text = AgentDiagramLabelText.decode(String(rest[afterQuote..<close]))
            let remainder = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
            let id = remainder.lowercased().hasPrefix("as ") ? remainder.dropFirst(3).trimmingCharacters(in: .whitespaces) : "note\(states.count)"
            let index = try declare(id)
            states[index].kind = .note
            states[index].label = text
            return
        }
        let onRight: Bool
        if lowered.hasPrefix("right of ") {
            onRight = true
        } else if lowered.hasPrefix("left of ") {
            onRight = false
        } else {
            throw error("Expected “note left of” or “note right of”.")
        }
        let afterSide = rest.dropFirst(onRight ? 9 : 8)
        var target = String(afterSide)
        var text: String?
        if let colon = afterSide.firstIndex(of: ":") {
            target = String(afterSide[..<colon])
            text = AgentDiagramLabelText.decode(String(afterSide[afterSide.index(after: colon)...]))
        }
        target = target.trimmingCharacters(in: .whitespaces)
        guard Self.isValidID(target), target != "[*]" else { throw error("Invalid note target “\(target.prefix(30))”.") }
        try declare(target)
        guard states.count < AgentStateDiagram.maximumStates else { throw error("The state diagram has too many states.") }
        let index = states.count
        let id = "note#\(index)"
        states.append(.init(id: id, label: text ?? "", kind: .note, scope: currentScope, noteTarget: target, noteOnRight: onRight))
        stateIndex[id] = index
        if text == nil { pendingNote = (index, []) }
    }
}
