import AppKit

/// A Mermaid `classDiagram`: classes with fields, methods and annotations, generics,
/// UML relationships with cardinalities and labels, namespaces and `direction`.
struct AgentClassDiagram: AgentDiagramDocument {
    static let keywords: Set<String> = ["classdiagram", "classdiagram-v2"]
    static let maxClasses = 150
    static let maxRelations = 400
    static let maxMembers = 200

    enum Direction: String, Equatable {
        case topToBottom = "TB"
        case bottomToTop = "BT"
        case leftToRight = "LR"
        case rightToLeft = "RL"
    }

    /// A line end decoration.
    enum End: Equatable {
        case none
        /// `<|` or `|>`: inheritance or realization.
        case triangle
        /// `*`: composition.
        case filledDiamond
        /// `o`: aggregation.
        case hollowDiamond
        /// `<` or `>`: association or dependency.
        case arrow
    }

    struct ClassBox: Equatable {
        var id: String
        var label: String
        var annotation: String?
        var fields: [String] = []
        var methods: [String] = []
        var namespace: String?
    }

    struct Relation: Equatable {
        var from: Int
        var to: Int
        var fromEnd: End
        var toEnd: End
        var dashed: Bool
        var label: String
        var fromCardinality: String
        var toCardinality: String
    }

    var direction: Direction = .topToBottom
    var title: String?
    var classes: [ClassBox] = []
    var relations: [Relation] = []

    init(source: String) throws {
        let split = try AgentDiagramTextSource.split(source)
        guard let keyword = AgentDiagramSource.keyword(of: split.header.text), Self.keywords.contains(keyword) else {
            throw AgentDiagramError(message: "Expected a classDiagram header.", line: split.header.number)
        }
        var parser = Parser()
        for line in split.body {
            try parser.parse(line)
        }
        if let body = parser.openBody {
            throw AgentDiagramError(message: "Class `\(parser.classes[body.index].id)` is not closed with `}`.", line: body.line)
        }
        if let namespace = parser.namespaces.last {
            throw AgentDiagramError(message: "Namespace `\(namespace.name)` is not closed with `}`.", line: namespace.line)
        }
        guard !parser.classes.isEmpty else {
            throw AgentDiagramError(message: "The class diagram has no classes.", line: nil)
        }
        direction = parser.direction
        title = parser.title ?? split.frontMatterTitle
        classes = parser.classes
        relations = parser.relations
    }

    func layout(maxWidth: CGFloat, style: AgentDiagramStyle) -> AgentDiagramLayout {
        let geometry = geometry(style: style)
        let diagram = self
        return AgentDiagramLayout(size: geometry.size) { context in
            AgentDiagramText.withGraphics(context) {
                diagram.draw(geometry, style: style, in: context)
            }
        }
    }
}

// MARK: - Parsing

private extension AgentClassDiagram {
    struct Parser {
        var direction: Direction = .topToBottom
        var title: String?
        var classes: [ClassBox] = []
        var indexByID: [String: Int] = [:]
        var relations: [Relation] = []
        var openBody: (index: Int, line: Int)?
        var namespaces: [(name: String, line: Int)] = []

        static let ignored = ["classDef", "cssClass", "style", "click", "callback", "link", "note", "accTitle", "accDescr"]

        mutating func parse(_ line: AgentDiagramTextSourceLine) throws {
            var text = line.text
            if let body = openBody {
                if text == "}" {
                    openBody = nil
                    return
                }
                if text.hasSuffix("}") {
                    text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
                    openBody = nil
                }
                try addMember(text, to: body.index, line: line)
                return
            }
            if text == "}" {
                guard namespaces.popLast() != nil else {
                    throw AgentDiagramError(message: "`}` without an open class or namespace.", line: line.number)
                }
                return
            }
            for keyword in Self.ignored where AgentDiagramTextSource.remainder(of: text, afterKeyword: keyword) != nil {
                return
            }
            if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "direction") {
                guard let value = Direction(rawValue: rest.uppercased()) else {
                    throw AgentDiagramError(message: "Unknown direction `\(rest)`.", line: line.number)
                }
                direction = value
                return
            }
            if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "title") {
                title = rest
                return
            }
            if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "namespace") {
                let name = rest.hasSuffix("{") ? String(rest.dropLast()).trimmingCharacters(in: .whitespaces) : rest
                guard !name.isEmpty, namespaces.count < 16 else {
                    throw AgentDiagramError(message: "A namespace needs a name.", line: line.number)
                }
                namespaces.append((name, line.number))
                return
            }
            if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "class") {
                try declareClass(rest, line: line)
                return
            }
            if text.hasPrefix("<<"), let close = text.range(of: ">>") {
                let annotation = String(text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
                let name = String(text[close.upperBound...]).trimmingCharacters(in: .whitespaces)
                let index = try classIndex(name, line: line)
                classes[index].annotation = annotation
                return
            }
            if try parseRelation(text, line: line) { return }
            if let colon = Self.firstUnquoted(":", in: text) {
                let name = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
                if Self.isIdentifier(Self.baseName(name)) {
                    let index = try classIndex(name, line: line)
                    try addMember(String(text[text.index(after: colon)...]), to: index, line: line)
                    return
                }
            }
            if Self.isIdentifier(Self.baseName(text)) {
                _ = try classIndex(text, line: line)
                return
            }
            throw AgentDiagramError(message: "Unrecognized class diagram statement: \(text.prefix(60))", line: line.number)
        }

        mutating func declareClass(_ rest: String, line: AgentDiagramTextSourceLine) throws {
            var text = rest
            var opensBody = false
            var inlineBody: String?
            if let brace = text.firstIndex(of: "{") {
                let after = text[text.index(after: brace)...]
                if let close = after.lastIndex(of: "}") {
                    inlineBody = String(after[..<close])
                } else {
                    opensBody = true
                }
                text = String(text[..<brace])
            }
            var label: String?
            if let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close {
                label = AgentDiagramText.unquoted(String(text[text.index(after: open)..<close]))
                text = String(text[..<open])
            }
            if let style = text.range(of: ":::") {
                text = String(text[..<style.lowerBound])
            }
            let name = text.trimmingCharacters(in: .whitespaces)
            guard Self.isIdentifier(Self.baseName(name)) else {
                throw AgentDiagramError(message: "Invalid class name `\(name.prefix(40))`.", line: line.number)
            }
            let index = try classIndex(name, line: line)
            if let label { classes[index].label = label }
            if let inlineBody {
                for member in inlineBody.split(separator: ";") where !member.trimmingCharacters(in: .whitespaces).isEmpty {
                    try addMember(String(member), to: index, line: line)
                }
            }
            if opensBody { openBody = (index, line.number) }
        }

        mutating func addMember(_ raw: String, to index: Int, line: AgentDiagramTextSourceLine) throws {
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            if text.hasPrefix("<<"), text.hasSuffix(">>"), text.count > 4 {
                classes[index].annotation = String(text.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                return
            }
            guard classes[index].fields.count + classes[index].methods.count < AgentClassDiagram.maxMembers else {
                throw AgentDiagramError(message: "Class `\(classes[index].id)` has too many members to draw.", line: line.number)
            }
            let display = Self.displayMember(text)
            if text.contains("(") {
                classes[index].methods.append(display)
            } else {
                classes[index].fields.append(display)
            }
        }

        /// `List~int~` becomes `List<int>`; a method's return type gets a colon; `$`/`*` classifiers are dropped.
        static func displayMember(_ text: String) -> String {
            var member = text
            while let last = member.last, last == "$" || last == "*" {
                member.removeLast()
            }
            // A leading `~` is package visibility, not the start of a generic.
            let visibility = member.first.map { "+-#~".contains($0) } == true ? String(member.prefix(1)) : ""
            member = visibility + genericDisplay(String(member.dropFirst(visibility.count)))
            if let close = member.lastIndex(of: ")") {
                let returnType = member[member.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if !returnType.isEmpty, !returnType.hasPrefix(":") {
                    member = String(member[...close]) + " : " + returnType.trimmingCharacters(in: CharacterSet(charactersIn: "$*"))
                }
            }
            return member
        }

        static func genericDisplay(_ text: String) -> String {
            var output = ""
            var open = true
            for character in text {
                if character == "~" {
                    output.append(open ? "<" : ">")
                    open.toggle()
                } else {
                    output.append(character)
                }
            }
            return output
        }

        /// The class id without generics: `Box~T~` is `Box`.
        static func baseName(_ name: String) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("`"), trimmed.hasSuffix("`"), trimmed.count > 2 {
                return String(trimmed.dropFirst().dropLast())
            }
            return String(trimmed.prefix { $0 != "~" })
        }

        static func isIdentifier(_ name: String) -> Bool {
            guard !name.isEmpty, name.count <= 120 else { return false }
            return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        }

        mutating func classIndex(_ rawName: String, line: AgentDiagramTextSourceLine) throws -> Int {
            let name = rawName.trimmingCharacters(in: .whitespaces)
            let id = Self.baseName(name)
            guard Self.isIdentifier(id) else {
                throw AgentDiagramError(message: "Invalid class name `\(name.prefix(40))`.", line: line.number)
            }
            let label = name.contains("~") ? Self.genericDisplay(name) : id
            if let index = indexByID[id] {
                if name.contains("~") { classes[index].label = label }
                return index
            }
            guard classes.count < AgentClassDiagram.maxClasses else {
                throw AgentDiagramError(message: "The class diagram has too many classes to draw.", line: line.number)
            }
            classes.append(ClassBox(id: id, label: label, namespace: namespaces.last?.name))
            indexByID[id] = classes.count - 1
            return classes.count - 1
        }

        static func firstUnquoted(_ target: Character, in text: String) -> String.Index? {
            var quoted = false
            var index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                if character == "\"" { quoted.toggle() } else if character == target, !quoted { return index }
                index = text.index(after: index)
            }
            return nil
        }

        mutating func parseRelation(_ text: String, line: AgentDiagramTextSourceLine) throws -> Bool {
            let colon = Self.firstUnquoted(":", in: text)
            let head = Array(colon.map { String(text[..<$0]) } ?? text)
            let label = colon.map { AgentDiagramText.unquoted(String(text[text.index(after: $0)...])) } ?? ""
            var quoted = false
            var linkStart: Int?
            for position in 0..<max(head.count - 1, 0) {
                if head[position] == "\"" { quoted.toggle() }
                guard !quoted else { continue }
                let pair = String(head[position...position + 1])
                if pair == "--" || pair == ".." {
                    linkStart = position
                    break
                }
            }
            guard let start = linkStart else { return false }
            let dashed = head[start] == "."
            var linkEnd = start + 2
            while linkEnd < head.count, head[linkEnd] == head[start] { linkEnd += 1 }

            func isBoundary(_ position: Int) -> Bool {
                position < 0 || position >= head.count || head[position].isWhitespace || head[position] == "\""
            }
            var leftEnd = End.none
            var leftStart = start
            if start >= 2, head[start - 2] == "<", head[start - 1] == "|" {
                leftEnd = .triangle
                leftStart = start - 2
            } else if start >= 2, head[start - 2] == "(", head[start - 1] == ")" {
                leftStart = start - 2
            } else if start >= 1, head[start - 1] == "*" {
                leftEnd = .filledDiamond
                leftStart = start - 1
            } else if start >= 1, head[start - 1] == "<" {
                leftEnd = .arrow
                leftStart = start - 1
            } else if start >= 1, head[start - 1] == "o", isBoundary(start - 2) {
                leftEnd = .hollowDiamond
                leftStart = start - 1
            }
            var rightEnd = End.none
            var rightStart = linkEnd
            if linkEnd + 1 < head.count, head[linkEnd] == "|", head[linkEnd + 1] == ">" {
                rightEnd = .triangle
                rightStart = linkEnd + 2
            } else if linkEnd + 1 < head.count, head[linkEnd] == "(", head[linkEnd + 1] == ")" {
                rightStart = linkEnd + 2
            } else if linkEnd < head.count, head[linkEnd] == "*" {
                rightEnd = .filledDiamond
                rightStart = linkEnd + 1
            } else if linkEnd < head.count, head[linkEnd] == ">" {
                rightEnd = .arrow
                rightStart = linkEnd + 1
            } else if linkEnd < head.count, head[linkEnd] == "o", isBoundary(linkEnd + 1) {
                rightEnd = .hollowDiamond
                rightStart = linkEnd + 1
            }
            let (fromName, fromCardinality) = Self.splitCardinality(String(head[..<leftStart]), cardinalityFirst: false)
            let (toName, toCardinality) = Self.splitCardinality(String(head[rightStart...]), cardinalityFirst: true)
            guard Self.isIdentifier(Self.baseName(fromName)), Self.isIdentifier(Self.baseName(toName)) else {
                throw AgentDiagramError(message: "A relationship needs a class on each side.", line: line.number)
            }
            guard relations.count < AgentClassDiagram.maxRelations else {
                throw AgentDiagramError(message: "The class diagram has too many relationships to draw.", line: line.number)
            }
            let from = try classIndex(fromName, line: line)
            let to = try classIndex(toName, line: line)
            relations.append(Relation(
                from: from, to: to, fromEnd: leftEnd, toEnd: rightEnd, dashed: dashed,
                label: label, fromCardinality: fromCardinality, toCardinality: toCardinality
            ))
            return true
        }

        /// Splits `Name "1"` (or `"1" Name` when `cardinalityFirst`) into the name and the cardinality.
        static func splitCardinality(_ raw: String, cardinalityFirst: Bool) -> (String, String) {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if cardinalityFirst, text.hasPrefix("\""), let close = text.dropFirst().firstIndex(of: "\"") {
                let cardinality = String(text[text.index(after: text.startIndex)..<close])
                return (String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces), cardinality)
            }
            if !cardinalityFirst, text.hasSuffix("\""), let open = text.dropLast().lastIndex(of: "\"") {
                let cardinality = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
                return (String(text[..<open]).trimmingCharacters(in: .whitespaces), cardinality)
            }
            return (text, "")
        }
    }
}

// MARK: - Layout

extension AgentClassDiagram {
    struct Geometry {
        var size: CGSize = .zero
        var titleRect: CGRect?
        /// One rect per class, in declaration order.
        var boxes: [CGRect] = []
        /// The layer of each class: 0 for the top (or leftmost) row.
        var layers: [Int] = []
        var namespaceRects: [(name: String, rect: CGRect)] = []
    }

    static let margin: CGFloat = 16
    static let padding: CGFloat = 8

    static func boldFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    static func annotationFont(_ style: AgentDiagramStyle) -> NSFont {
        NSFont.systemFont(ofSize: max(style.font.pointSize - 2, 9))
    }

    /// Heights of the name, field and method compartments of a class.
    func compartments(_ box: ClassBox, style: AgentDiagramStyle) -> (name: CGFloat, fields: CGFloat, methods: CGFloat, width: CGFloat) {
        let font = style.font
        let lineHeight = AgentDiagramText.lineHeight(font)
        var nameHeight = AgentDiagramText.size(box.label, font: Self.boldFont(font)).height + Self.padding * 2
        var width = AgentDiagramText.size(box.label, font: Self.boldFont(font)).width
        if let annotation = box.annotation {
            let size = AgentDiagramText.size("«\(annotation)»", font: Self.annotationFont(style))
            nameHeight += size.height
            width = max(width, size.width)
        }
        for member in box.fields + box.methods {
            width = max(width, AgentDiagramText.width(member, font: font))
        }
        let fields = box.fields.isEmpty ? Self.padding : CGFloat(box.fields.count) * lineHeight + Self.padding
        let methods = box.methods.isEmpty ? Self.padding : CGFloat(box.methods.count) * lineHeight + Self.padding
        return (nameHeight, fields, methods, max(width + 24, 100))
    }

    /// Layers by relationship depth: inheritance parents and relationship sources come first.
    /// Cycles are broken by ignoring edges back to a class still being visited.
    func layers() -> [Int] {
        let count = classes.count
        var children: [[Int]] = Array(repeating: [], count: count)
        for relation in relations where relation.from != relation.to {
            if relation.toEnd == .triangle && relation.fromEnd != .triangle {
                children[relation.to].append(relation.from)
            } else {
                children[relation.from].append(relation.to)
            }
        }
        // Depth-first search marks back edges so the remaining graph is acyclic.
        enum Mark { case new, active, done }
        var marks = Array(repeating: Mark.new, count: count)
        var acyclic: [[Int]] = Array(repeating: [], count: count)
        for root in 0..<count where marks[root] == .new {
            var stack: [(node: Int, next: Int)] = [(root, 0)]
            marks[root] = .active
            while let top = stack.last {
                let node = top.node
                if top.next < children[node].count {
                    stack[stack.count - 1].next += 1
                    let child = children[node][top.next]
                    switch marks[child] {
                    case .active:
                        continue
                    case .done:
                        acyclic[node].append(child)
                    case .new:
                        acyclic[node].append(child)
                        marks[child] = .active
                        stack.append((child, 0))
                    }
                } else {
                    marks[node] = .done
                    stack.removeLast()
                }
            }
        }
        var indegree = Array(repeating: 0, count: count)
        for edges in acyclic { for child in edges { indegree[child] += 1 } }
        var layer = Array(repeating: 0, count: count)
        var queue = (0..<count).filter { indegree[$0] == 0 }
        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1
            for child in acyclic[node] {
                layer[child] = max(layer[child], layer[node] + 1)
                indegree[child] -= 1
                if indegree[child] == 0 { queue.append(child) }
            }
        }
        return layer
    }

    func geometry(style: AgentDiagramStyle) -> Geometry {
        var geometry = Geometry()
        let sizes = classes.map { box -> CGSize in
            let parts = compartments(box, style: style)
            return CGSize(width: parts.width, height: parts.name + parts.fields + parts.methods)
        }
        let layer = layers()
        geometry.layers = layer
        let layerCount = (layer.max() ?? 0) + 1
        var rows: [[Int]] = Array(repeating: [], count: layerCount)
        for index in classes.indices { rows[layer[index]].append(index) }

        // Order each row by the mean position of its neighbors in the row above.
        var position = Array(repeating: 0.0, count: classes.count)
        for row in rows { for (slot, node) in row.enumerated() { position[node] = Double(slot) } }
        var neighbors: [[Int]] = Array(repeating: [], count: classes.count)
        for relation in relations where relation.from != relation.to {
            neighbors[relation.from].append(relation.to)
            neighbors[relation.to].append(relation.from)
        }
        for rowIndex in rows.indices.dropFirst() {
            let keyed = rows[rowIndex].map { node -> (node: Int, key: Double) in
                let above = neighbors[node].filter { layer[$0] < rowIndex }
                let key = above.isEmpty ? position[node] : above.map { position[$0] }.reduce(0, +) / Double(above.count)
                return (node, key)
            }
            rows[rowIndex] = keyed.enumerated().sorted {
                $0.element.key != $1.element.key ? $0.element.key < $1.element.key : $0.offset < $1.offset
            }.map(\.element.node)
            for (slot, node) in rows[rowIndex].enumerated() { position[node] = Double(slot) }
        }
        if direction == .bottomToTop || direction == .rightToLeft { rows.reverse() }

        let horizontal = direction == .leftToRight || direction == .rightToLeft
        let labelGap = relations.contains { !$0.label.isEmpty || !$0.fromCardinality.isEmpty || !$0.toCardinality.isEmpty } ? 24.0 : 0
        let siblingGap: CGFloat = horizontal ? 32 : 48
        let layerGap: CGFloat = (horizontal ? 90 : 64) + labelGap
        var boxes = Array(repeating: CGRect.zero, count: classes.count)
        var top = Self.margin
        if let title, !title.isEmpty {
            let size = AgentDiagramText.size(title, font: Self.boldFont(style.font))
            geometry.titleRect = CGRect(x: 0, y: top, width: size.width, height: size.height)
            top += size.height + 16
        }
        let hasNamespaces = classes.contains { $0.namespace != nil }
        if hasNamespaces { top += 28 }
        let start = hasNamespaces ? Self.margin + 12 : Self.margin
        let rowExtent = rows.map { row -> CGFloat in
            let lengths = row.map { horizontal ? sizes[$0].height : sizes[$0].width }
            return lengths.reduce(0, +) + CGFloat(max(row.count - 1, 0)) * siblingGap
        }
        let widest = rowExtent.max() ?? 0
        var cursor = horizontal ? start : top
        for (rowIndex, row) in rows.enumerated() {
            let thickness = row.map { horizontal ? sizes[$0].width : sizes[$0].height }.max() ?? 0
            var along = (horizontal ? top : start) + (widest - rowExtent[rowIndex]) / 2
            for node in row {
                let size = sizes[node]
                if horizontal {
                    boxes[node] = CGRect(x: cursor + (thickness - size.width) / 2, y: along, width: size.width, height: size.height)
                    along += size.height + siblingGap
                } else {
                    boxes[node] = CGRect(x: along, y: cursor, width: size.width, height: size.height)
                    along += size.width + siblingGap
                }
            }
            cursor += thickness + layerGap
        }
        geometry.boxes = boxes.map(\.integral)

        var namespaceOrder: [String] = []
        for box in classes { if let name = box.namespace, !namespaceOrder.contains(name) { namespaceOrder.append(name) } }
        for name in namespaceOrder {
            let members = classes.indices.filter { classes[$0].namespace == name }
            let union = members.map { geometry.boxes[$0] }.reduce(CGRect.null) { $0.union($1) }
            let padded = union.insetBy(dx: -10, dy: -10)
            let rect = CGRect(x: padded.minX, y: padded.minY - 16, width: padded.width, height: padded.height + 16)
            let others = classes.indices.filter { classes[$0].namespace != name }
            guard !others.contains(where: { geometry.boxes[$0].intersects(rect) }) else { continue }
            geometry.namespaceRects.append((name, rect))
        }

        var maxX = geometry.boxes.map(\.maxX).max() ?? 0
        var maxY = geometry.boxes.map(\.maxY).max() ?? 0
        for item in geometry.namespaceRects {
            maxX = max(maxX, item.rect.maxX)
            maxY = max(maxY, item.rect.maxY)
        }
        var width = maxX + Self.margin
        if let rect = geometry.titleRect {
            width = max(width, rect.width + Self.margin * 2)
            geometry.titleRect = CGRect(x: (width - rect.width) / 2, y: rect.minY, width: rect.width, height: rect.height)
        }
        geometry.size = CGSize(width: ceil(width), height: ceil(maxY + Self.margin))
        return geometry
    }

    /// The point where the segment from `rect`'s center toward `target` leaves `rect`.
    static func clip(_ rect: CGRect, toward target: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let scaleX = dx == 0 ? CGFloat.infinity : (rect.width / 2) / abs(dx)
        let scaleY = dy == 0 ? CGFloat.infinity : (rect.height / 2) / abs(dy)
        let scale = min(scaleX, scaleY, 1)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }
}

// MARK: - Drawing

private extension AgentClassDiagram {
    static func marker(_ end: End) -> AgentDiagramTextMarker {
        switch end {
        case .none: return .none
        case .triangle: return .hollowTriangle
        case .filledDiamond: return .filledDiamond
        case .hollowDiamond: return .hollowDiamond
        case .arrow: return .openArrow
        }
    }

    func draw(_ geometry: Geometry, style: AgentDiagramStyle, in context: CGContext) {
        let font = style.font
        let small = Self.annotationFont(style)
        for item in geometry.namespaceRects {
            AgentDiagramTextStroke.rect(context, item.rect, radius: 8, fill: AgentDiagramText.faded(style.accentSoft, 0.5), stroke: style.border, dashed: true)
            AgentDiagramText.draw(item.name, in: CGRect(x: item.rect.minX + 8, y: item.rect.minY + 3, width: item.rect.width, height: 16), font: Self.boldFont(small), color: style.muted, alignment: .left)
        }
        for relation in relations {
            drawRelation(relation, geometry: geometry, style: style, small: small, in: context)
        }
        for (index, box) in classes.enumerated() where index < geometry.boxes.count {
            drawClass(box, in: geometry.boxes[index], style: style, font: font, small: small, context: context)
        }
        if let title, let rect = geometry.titleRect {
            AgentDiagramText.draw(title, in: rect, font: Self.boldFont(font), color: style.foreground, alignment: .center)
        }
    }

    func drawRelation(_ relation: Relation, geometry: Geometry, style: AgentDiagramStyle, small: NSFont, in context: CGContext) {
        let fromRect = geometry.boxes[relation.from]
        let toRect = geometry.boxes[relation.to]
        var start: CGPoint
        var end: CGPoint
        if relation.from == relation.to {
            let loop = [
                CGPoint(x: fromRect.maxX - 20, y: fromRect.minY),
                CGPoint(x: fromRect.maxX - 20, y: fromRect.minY - 18),
                CGPoint(x: fromRect.maxX + 18, y: fromRect.minY - 18),
                CGPoint(x: fromRect.maxX + 18, y: fromRect.minY + 20),
                CGPoint(x: fromRect.maxX, y: fromRect.minY + 20),
            ]
            AgentDiagramTextStroke.polyline(context, loop, color: style.muted, dashed: relation.dashed)
            AgentDiagramTextStroke.marker(context, Self.marker(relation.toEnd), tip: loop[4], from: loop[3], color: style.muted, fill: style.surface)
            AgentDiagramTextStroke.marker(context, Self.marker(relation.fromEnd), tip: loop[0], from: loop[1], color: style.muted, fill: style.surface)
            if !relation.label.isEmpty {
                AgentDiagramText.draw(relation.label, centeredAt: CGPoint(x: fromRect.maxX + 18, y: fromRect.minY - 28), font: small, color: style.muted)
            }
            return
        }
        start = Self.clip(fromRect, toward: CGPoint(x: toRect.midX, y: toRect.midY))
        end = Self.clip(toRect, toward: CGPoint(x: fromRect.midX, y: fromRect.midY))
        let length = max(hypot(end.x - start.x, end.y - start.y), 0.001)
        let ux = (end.x - start.x) / length
        let uy = (end.y - start.y) / length
        let fromMarker = Self.marker(relation.fromEnd)
        let toMarker = Self.marker(relation.toEnd)
        let lineStart = CGPoint(x: start.x + ux * AgentDiagramTextStroke.markerLength(fromMarker), y: start.y + uy * AgentDiagramTextStroke.markerLength(fromMarker))
        let lineEnd = CGPoint(x: end.x - ux * AgentDiagramTextStroke.markerLength(toMarker), y: end.y - uy * AgentDiagramTextStroke.markerLength(toMarker))
        AgentDiagramTextStroke.line(context, from: lineStart, to: lineEnd, color: style.muted, width: 1.2, dashed: relation.dashed)
        AgentDiagramTextStroke.marker(context, fromMarker, tip: start, from: end, color: style.muted, fill: style.surface)
        AgentDiagramTextStroke.marker(context, toMarker, tip: end, from: start, color: style.muted, fill: style.surface)
        if !relation.label.isEmpty {
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let size = AgentDiagramText.size(relation.label, font: small)
            AgentDiagramTextStroke.rect(context, CGRect(x: mid.x - size.width / 2 - 3, y: mid.y - size.height / 2 - 1, width: size.width + 6, height: size.height + 2), radius: 3, fill: style.surface)
            AgentDiagramText.draw(relation.label, centeredAt: mid, font: small, color: style.foreground)
        }
        let normal = CGPoint(x: -uy, y: ux)
        if !relation.fromCardinality.isEmpty {
            let point = CGPoint(x: start.x + ux * 22 + normal.x * 10, y: start.y + uy * 22 + normal.y * 10)
            AgentDiagramText.draw(relation.fromCardinality, centeredAt: point, font: small, color: style.muted)
        }
        if !relation.toCardinality.isEmpty {
            let point = CGPoint(x: end.x - ux * 22 + normal.x * 10, y: end.y - uy * 22 + normal.y * 10)
            AgentDiagramText.draw(relation.toCardinality, centeredAt: point, font: small, color: style.muted)
        }
    }

    func drawClass(_ box: ClassBox, in rect: CGRect, style: AgentDiagramStyle, font: NSFont, small: NSFont, context: CGContext) {
        let parts = compartments(box, style: style)
        let lineHeight = AgentDiagramText.lineHeight(font)
        AgentDiagramTextStroke.rect(context, rect, radius: 4, fill: style.surface, stroke: style.border)
        AgentDiagramTextStroke.rect(context, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: parts.name), radius: 4, fill: style.accentSoft)
        var y = rect.minY + Self.padding
        if let annotation = box.annotation {
            let text = "«\(annotation)»"
            let height = AgentDiagramText.size(text, font: small).height
            AgentDiagramText.draw(text, in: CGRect(x: rect.minX, y: y, width: rect.width, height: height), font: small, color: style.muted, alignment: .center)
            y += height
        }
        AgentDiagramText.draw(box.label, in: CGRect(x: rect.minX, y: y, width: rect.width, height: parts.name), font: Self.boldFont(font), color: style.foreground, alignment: .center)
        let fieldsTop = rect.minY + parts.name
        let methodsTop = fieldsTop + parts.fields
        AgentDiagramTextStroke.line(context, from: CGPoint(x: rect.minX, y: fieldsTop), to: CGPoint(x: rect.maxX, y: fieldsTop), color: style.border)
        AgentDiagramTextStroke.line(context, from: CGPoint(x: rect.minX, y: methodsTop), to: CGPoint(x: rect.maxX, y: methodsTop), color: style.border)
        for (index, field) in box.fields.enumerated() {
            AgentDiagramText.draw(field, in: CGRect(x: rect.minX + 10, y: fieldsTop + Self.padding / 2 + CGFloat(index) * lineHeight, width: rect.width - 20, height: lineHeight), font: font, color: style.foreground, alignment: .left)
        }
        for (index, method) in box.methods.enumerated() {
            AgentDiagramText.draw(method, in: CGRect(x: rect.minX + 10, y: methodsTop + Self.padding / 2 + CGFloat(index) * lineHeight, width: rect.width - 20, height: lineHeight), font: font, color: style.foreground, alignment: .left)
        }
        AgentDiagramTextStroke.rect(context, rect, radius: 4, stroke: style.border)
    }
}
