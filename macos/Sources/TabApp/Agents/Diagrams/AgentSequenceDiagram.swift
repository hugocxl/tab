import AppKit

/// A Mermaid `sequenceDiagram`: participants and actors, messages, activations, notes,
/// nested frames (`loop`, `alt`, `opt`, `par`, `critical`, `break`, `rect`) and `box` groups.
struct AgentSequenceDiagram: AgentDiagramDocument {
    static let keywords: Set<String> = ["sequencediagram"]
    static let maxParticipants = 64
    static let maxEvents = 2_000
    static let maxNesting = 24

    enum ParticipantKind: Equatable {
        case participant
        case actor
    }

    struct Participant: Equatable {
        var id: String
        var label: String
        var kind: ParticipantKind
        var box: Int?
    }

    struct Box: Equatable {
        var label: String
        var participants: [Int]
    }

    enum Head: Equatable {
        /// `->` and `-->`: a plain line.
        case none
        /// `->>` and `-->>`: a filled arrowhead.
        case filled
        /// `-x` and `--x`: a cross.
        case cross
        /// `-)` and `--)`: an open, asynchronous arrowhead.
        case open
    }

    struct Message: Equatable {
        var from: Int
        var to: Int
        var text: String
        var dashed: Bool
        var head: Head
        var bidirectional: Bool
        /// `+` after the arrow: activates the receiver.
        var activatesTarget: Bool
        /// `-` after the arrow: deactivates the sender.
        var deactivatesSource: Bool
        /// The `autonumber` sequence number, when numbering is on.
        var number: Int?
    }

    enum NotePlacement: Equatable {
        case leftOf
        case rightOf
        case over
    }

    struct Note: Equatable {
        var placement: NotePlacement
        var participants: [Int]
        var text: String
    }

    enum FrameKind: String, Equatable {
        case loop, alt, opt, par, critical
        case breakFrame = "break"
        case rect
    }

    enum Event: Equatable {
        case message(Message)
        case note(Note)
        case activate(Int)
        case deactivate(Int)
        case frameStart(FrameKind, String)
        /// `else`, `and` or `option` inside the open frame.
        case frameSection(String)
        case frameEnd
    }

    var title: String?
    var participants: [Participant] = []
    var boxes: [Box] = []
    var events: [Event] = []

    var messages: [Message] {
        events.compactMap { event in
            if case let .message(message) = event { return message }
            return nil
        }
    }

    init(source: String) throws {
        let split = try AgentDiagramTextSource.split(source)
        guard AgentDiagramSource.keyword(of: split.header.text) == "sequencediagram" else {
            throw AgentDiagramError(message: "Expected a sequenceDiagram header.", line: split.header.number)
        }
        var parser = Parser()
        for line in split.body {
            try parser.parse(line)
        }
        try parser.finish()
        title = parser.title ?? split.frontMatterTitle
        participants = parser.participants
        boxes = parser.boxes
        events = parser.events
        if participants.isEmpty {
            throw AgentDiagramError(message: "The sequence diagram has no participants.", line: nil)
        }
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

private extension AgentSequenceDiagram {
    struct OpenFrame {
        var kind: FrameKind
        var line: Int
    }

    struct Parser {
        var title: String?
        var participants: [Participant] = []
        var indexByID: [String: Int] = [:]
        var boxes: [Box] = []
        var events: [Event] = []
        var openBox: (index: Int, line: Int)?
        var frames: [OpenFrame] = []
        var numbering: (next: Int, step: Int)?

        static let arrows: [(token: String, dashed: Bool, head: Head, bidirectional: Bool)] = [
            ("<<-->>", true, .filled, true),
            ("<<->>", false, .filled, true),
            ("-->>", true, .filled, false),
            ("->>", false, .filled, false),
            ("--x", true, .cross, false),
            ("-x", false, .cross, false),
            ("--)", true, .open, false),
            ("-)", false, .open, false),
            ("-->", true, .none, false),
            ("->", false, .none, false),
        ]

        static let ignoredKeywords = ["accTitle", "accDescr", "links", "link", "properties", "details"]

        mutating func parse(_ line: AgentDiagramTextSourceLine) throws {
            let text = line.text
            if events.count >= AgentSequenceDiagram.maxEvents {
                throw AgentDiagramError(message: "The sequence diagram has too many statements to draw.", line: line.number)
            }
            if text.lowercased() == "end" {
                try closeBlock(line)
                return
            }
            for keyword in Self.ignoredKeywords where AgentDiagramTextSource.remainder(of: text, afterKeyword: keyword) != nil {
                return
            }
            if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "title") {
                title = rest
                return
            }
            if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "autonumber") {
                try parseAutonumber(rest, line: line)
                return
            }
            if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "create") {
                try parse(AgentDiagramTextSourceLine(number: line.number, text: rest))
                return
            }
            if AgentDiagramTextSource.remainder(of: text, afterKeyword: "destroy") != nil {
                return
            }
            if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "participant") {
                try declare(rest, kind: .participant, line: line)
                return
            }
            if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "actor") {
                try declare(rest, kind: .actor, line: line)
                return
            }
            if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "box") {
                try openBox(rest, line: line)
                return
            }
            if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "activate") {
                events.append(.activate(try participant(rest, line: line)))
                return
            }
            if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "deactivate") {
                events.append(.deactivate(try participant(rest, line: line)))
                return
            }
            if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "note") {
                try parseNote(rest, line: line)
                return
            }
            for kind in [FrameKind.loop, .alt, .opt, .par, .critical, .breakFrame, .rect] {
                guard let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: kind.rawValue) else { continue }
                try openFrame(kind, label: kind == .rect ? "" : rest, line: line)
                return
            }
            for (keyword, owner) in [("else", FrameKind.alt), ("and", .par), ("option", .critical)] {
                guard let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: keyword) else { continue }
                guard frames.last?.kind == owner else {
                    throw AgentDiagramError(message: "`\(keyword)` must be inside `\(owner.rawValue)`.", line: line.number)
                }
                events.append(.frameSection(rest))
                return
            }
            if try parseMessage(text, line: line) { return }
            throw AgentDiagramError(message: "Unrecognized sequence diagram statement: \(text.prefix(60))", line: line.number)
        }

        mutating func finish() throws {
            if let openBox {
                throw AgentDiagramError(message: "`box` is not closed with `end`.", line: openBox.line)
            }
            if let frame = frames.last {
                throw AgentDiagramError(message: "`\(frame.kind.rawValue)` is not closed with `end`.", line: frame.line)
            }
        }

        mutating func closeBlock(_ line: AgentDiagramTextSourceLine) throws {
            if openBox != nil {
                openBox = nil
                return
            }
            guard frames.popLast() != nil else {
                throw AgentDiagramError(message: "`end` without an open block.", line: line.number)
            }
            events.append(.frameEnd)
        }

        mutating func openFrame(_ kind: FrameKind, label: String, line: AgentDiagramTextSourceLine) throws {
            guard frames.count < AgentSequenceDiagram.maxNesting else {
                throw AgentDiagramError(message: "Blocks are nested too deeply.", line: line.number)
            }
            frames.append(OpenFrame(kind: kind, line: line.number))
            events.append(.frameStart(kind, label))
        }

        mutating func openBox(_ rest: String, line: AgentDiagramTextSourceLine) throws {
            guard openBox == nil else {
                throw AgentDiagramError(message: "Boxes cannot be nested.", line: line.number)
            }
            guard frames.isEmpty else {
                throw AgentDiagramError(message: "`box` cannot be inside a block.", line: line.number)
            }
            boxes.append(Box(label: Self.boxLabel(rest), participants: []))
            openBox = (boxes.count - 1, line.number)
        }

        /// Drops a leading color (`rgb(…)`, `#abc`, `transparent` or a CSS color name) from a box label.
        static func boxLabel(_ rest: String) -> String {
            var text = rest
            let lower = text.lowercased()
            if lower.hasPrefix("rgb") || lower.hasPrefix("hsl"), let close = text.firstIndex(of: ")") {
                text = String(text[text.index(after: close)...])
            } else if let first = text.split(separator: " ").first {
                let word = first.lowercased()
                let namedColors: Set<String> = [
                    "transparent", "aqua", "black", "blue", "fuchsia", "gray", "grey", "green", "lime", "maroon",
                    "navy", "olive", "orange", "purple", "red", "silver", "teal", "white", "yellow", "lightblue",
                    "lightgreen", "lightgrey", "lightgray", "lightyellow", "pink", "violet", "beige", "tan",
                ]
                if word.hasPrefix("#") || namedColors.contains(word) {
                    text = String(text.dropFirst(first.count))
                }
            }
            return AgentDiagramText.unquoted(text)
        }

        mutating func parseAutonumber(_ rest: String, line: AgentDiagramTextSourceLine) throws {
            let words = rest.split(separator: " ").map(String.init)
            if words.first?.lowercased() == "off" {
                numbering = nil
                return
            }
            let start = words.first.flatMap { Int($0) } ?? 1
            let step = words.count > 1 ? (Int(words[1]) ?? 1) : 1
            numbering = (start, step)
        }

        mutating func declare(_ rest: String, kind: ParticipantKind, line: AgentDiagramTextSourceLine) throws {
            var text = rest
            if let metadata = text.range(of: "@{") {
                let close = text[metadata.upperBound...].firstIndex(of: "}").map { text.index(after: $0) } ?? text.endIndex
                text.removeSubrange(metadata.lowerBound..<close)
            }
            let id: String
            let label: String
            if let alias = text.range(of: " as ") {
                id = text[..<alias.lowerBound].trimmingCharacters(in: .whitespaces)
                label = AgentDiagramText.unquoted(String(text[alias.upperBound...]))
            } else {
                id = text.trimmingCharacters(in: .whitespaces)
                label = AgentDiagramText.unquoted(id)
            }
            guard !id.isEmpty else {
                throw AgentDiagramError(message: "A participant needs a name.", line: line.number)
            }
            let index = try participant(id, line: line)
            participants[index].label = label.isEmpty ? id : label
            participants[index].kind = kind
            if let openBox, participants[index].box == nil {
                participants[index].box = openBox.index
                boxes[openBox.index].participants.append(index)
            }
        }

        mutating func participant(_ rawID: String, line: AgentDiagramTextSourceLine) throws -> Int {
            let id = rawID.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else {
                throw AgentDiagramError(message: "Expected a participant name.", line: line.number)
            }
            if let index = indexByID[id] { return index }
            guard participants.count < AgentSequenceDiagram.maxParticipants else {
                throw AgentDiagramError(message: "The sequence diagram has too many participants to draw.", line: line.number)
            }
            participants.append(Participant(id: id, label: AgentDiagramText.unquoted(id), kind: .participant, box: nil))
            indexByID[id] = participants.count - 1
            return participants.count - 1
        }

        mutating func parseNote(_ rest: String, line: AgentDiagramTextSourceLine) throws {
            let lower = rest.lowercased()
            let placement: NotePlacement
            let afterPlacement: Substring
            if lower.hasPrefix("left of ") {
                placement = .leftOf
                afterPlacement = rest.dropFirst(8)
            } else if lower.hasPrefix("right of ") {
                placement = .rightOf
                afterPlacement = rest.dropFirst(9)
            } else if lower.hasPrefix("over ") {
                placement = .over
                afterPlacement = rest.dropFirst(5)
            } else {
                throw AgentDiagramError(message: "A note needs `left of`, `right of` or `over`.", line: line.number)
            }
            let targets: Substring
            let text: String
            if let colon = afterPlacement.firstIndex(of: ":") {
                targets = afterPlacement[..<colon]
                text = afterPlacement[afterPlacement.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                targets = afterPlacement
                text = ""
            }
            let names = targets.split(separator: ",").map(String.init).prefix(2)
            guard !names.isEmpty else {
                throw AgentDiagramError(message: "A note needs a participant.", line: line.number)
            }
            var indices: [Int] = []
            for name in names {
                indices.append(try participant(name, line: line))
            }
            events.append(.note(Note(placement: placement, participants: indices, text: text)))
        }

        mutating func parseMessage(_ text: String, line: AgentDiagramTextSourceLine) throws -> Bool {
            let head: Substring
            let label: String
            if let colon = text.firstIndex(of: ":") {
                head = text[..<colon]
                label = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                head = text[...]
                label = ""
            }
            var index = head.startIndex
            while index < head.endIndex {
                let character = head[index]
                if character == "-" || character == "<" {
                    for arrow in Self.arrows where head[index...].hasPrefix(arrow.token) {
                        let fromID = head[..<index].trimmingCharacters(in: .whitespaces)
                        var rest = head[head.index(index, offsetBy: arrow.token.count)...]
                        var activates = false
                        var deactivates = false
                        if rest.first == "+" {
                            activates = true
                            rest = rest.dropFirst()
                        } else if rest.first == "-" {
                            deactivates = true
                            rest = rest.dropFirst()
                        }
                        let toID = rest.trimmingCharacters(in: .whitespaces)
                        guard !fromID.isEmpty, !toID.isEmpty else {
                            throw AgentDiagramError(message: "A message needs a sender and a receiver.", line: line.number)
                        }
                        let from = try participant(fromID, line: line)
                        let to = try participant(toID, line: line)
                        var number: Int?
                        if let numbering {
                            number = numbering.next
                            self.numbering = (numbering.next &+ numbering.step, numbering.step)
                        }
                        events.append(.message(Message(
                            from: from, to: to, text: label, dashed: arrow.dashed, head: arrow.head,
                            bidirectional: arrow.bidirectional, activatesTarget: activates,
                            deactivatesSource: deactivates, number: number
                        )))
                        return true
                    }
                }
                index = head.index(after: index)
            }
            return false
        }
    }
}

// MARK: - Geometry

extension AgentSequenceDiagram {
    struct MessageGeometry: Equatable {
        var event: Int
        var y: CGFloat
        var startX: CGFloat
        var endX: CGFloat
        var isSelf: Bool
        var labelRect: CGRect
    }

    struct ActivationGeometry: Equatable {
        var participant: Int
        var level: Int
        var rect: CGRect
    }

    struct FrameGeometry: Equatable {
        var kind: FrameKind
        var label: String
        var depth: Int
        var rect: CGRect
        var sections: [(y: CGFloat, label: String)]

        static func == (lhs: FrameGeometry, rhs: FrameGeometry) -> Bool {
            lhs.kind == rhs.kind && lhs.label == rhs.label && lhs.depth == rhs.depth && lhs.rect == rhs.rect
                && lhs.sections.map(\.y) == rhs.sections.map(\.y) && lhs.sections.map(\.label) == rhs.sections.map(\.label)
        }
    }

    struct NoteGeometry: Equatable {
        var text: String
        var rect: CGRect
    }

    /// Positions of everything the diagram draws, in the diagram's top-left coordinates.
    struct Geometry {
        var size: CGSize = .zero
        var titleRect: CGRect?
        var centers: [CGFloat] = []
        var headerRects: [CGRect] = []
        var footerRects: [CGRect] = []
        var boxRects: [CGRect] = []
        var boxLabelHeight: CGFloat = 0
        var messages: [MessageGeometry] = []
        var activations: [ActivationGeometry] = []
        var frames: [FrameGeometry] = []
        var notes: [NoteGeometry] = []

        mutating func shift(_ dx: CGFloat) {
            func moved(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: dx, dy: 0) }
            centers = centers.map { $0 + dx }
            headerRects = headerRects.map(moved)
            footerRects = footerRects.map(moved)
            boxRects = boxRects.map(moved)
            for index in messages.indices {
                messages[index].startX += dx
                messages[index].endX += dx
                messages[index].labelRect = moved(messages[index].labelRect)
            }
            for index in activations.indices { activations[index].rect = moved(activations[index].rect) }
            for index in frames.indices { frames[index].rect = moved(frames[index].rect) }
            for index in notes.indices { notes[index].rect = moved(notes[index].rect) }
        }
    }

    static let margin: CGFloat = 12
    static let selfLoopWidth: CGFloat = 32
    static let selfLoopHeight: CGFloat = 20
    static let barWidth: CGFloat = 10

    static func smallFont(_ style: AgentDiagramStyle) -> NSFont {
        NSFont.systemFont(ofSize: max(style.font.pointSize - 1, 9))
    }

    static func boldFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    static func barRect(center: CGFloat, level: Int, top: CGFloat, bottom: CGFloat) -> CGRect {
        CGRect(x: center - barWidth / 2 + CGFloat(level - 1) * 5, y: top, width: barWidth, height: max(bottom - top, 8))
    }

    /// Lays the diagram out. Deterministic for a given source and style.
    func geometry(style: AgentDiagramStyle) -> Geometry {
        let font = style.font
        let small = Self.smallFont(style)
        let lineHeight = AgentDiagramText.lineHeight(font)
        let count = participants.count
        var geometry = Geometry()

        let labelSizes = participants.map { AgentDiagramText.size($0.label, font: font) }
        let headerWidths = labelSizes.map { max($0.width + 24, 72) }
        let rectHeight = (labelSizes.map(\.height).max() ?? lineHeight) + 16
        let hasActors = participants.contains { $0.kind == .actor }
        let headerHeight = max(rectHeight, hasActors ? 38 + (labelSizes.map(\.height).max() ?? lineHeight) : 0)

        let eventTextSizes: [CGSize] = events.map { event in
            switch event {
            case let .message(message): return AgentDiagramText.size(message.text, font: font)
            case let .note(note): return AgentDiagramText.size(note.text, font: font)
            case let .frameStart(_, label), let .frameSection(label):
                return AgentDiagramText.size(label.isEmpty ? "" : "[\(label)]", font: small)
            default: return .zero
            }
        }

        // Horizontal pass: gaps between neighboring lifelines grow to fit labels and notes.
        var gaps: [CGFloat] = (0..<max(count - 1, 0)).map { headerWidths[$0] / 2 + headerWidths[$0 + 1] / 2 + 32 }
        var leftExtra: CGFloat = 0
        var rightExtra: CGFloat = 0
        func widen(_ low: Int, _ high: Int, to needed: CGFloat) {
            guard high > low else { return }
            let span = gaps[low..<high].reduce(0, +)
            if span < needed { gaps[high - 1] += needed - span }
        }
        for (index, event) in events.enumerated() {
            let textSize = eventTextSizes[index]
            switch event {
            case let .message(message):
                let badge: CGFloat = message.number == nil ? 0 : 22
                if message.from == message.to {
                    let needed = Self.selfLoopWidth + max(textSize.width + 16 + badge - Self.selfLoopWidth, 0) + 24
                    if message.from < count - 1 {
                        gaps[message.from] = max(gaps[message.from], needed + headerWidths[message.from + 1] / 2)
                    } else {
                        rightExtra = max(rightExtra, needed)
                    }
                } else {
                    widen(min(message.from, message.to), max(message.from, message.to), to: textSize.width + 36 + badge)
                }
            case let .note(note):
                let width = max(textSize.width + 20, 60)
                guard let first = note.participants.first else { continue }
                switch note.placement {
                case .leftOf:
                    if first > 0 { gaps[first - 1] = max(gaps[first - 1], width + 24) } else { leftExtra = max(leftExtra, width + 14) }
                case .rightOf:
                    if first < count - 1 { gaps[first] = max(gaps[first], width + 24) } else { rightExtra = max(rightExtra, width + 14) }
                case .over:
                    let low = note.participants.min() ?? first
                    let high = note.participants.max() ?? first
                    if low == high {
                        if low > 0 { gaps[low - 1] = max(gaps[low - 1], width / 2 + headerWidths[low - 1] / 2 + 8) }
                        if low < count - 1 { gaps[low] = max(gaps[low], width / 2 + headerWidths[low + 1] / 2 + 8) }
                    } else {
                        widen(low, high, to: width - 50)
                    }
                }
            default:
                continue
            }
        }
        var centers: [CGFloat] = []
        var x = max(headerWidths[0] / 2, leftExtra)
        for index in 0..<count {
            centers.append(x)
            if index < count - 1 { x += gaps[index] }
        }
        geometry.centers = centers

        // Vertical pass.
        var y = Self.margin
        if let title, !title.isEmpty {
            let size = AgentDiagramText.size(title, font: Self.boldFont(font))
            geometry.titleRect = CGRect(x: 0, y: y, width: size.width, height: size.height)
            y += size.height + 12
        }
        if !boxes.isEmpty {
            geometry.boxLabelHeight = AgentDiagramText.lineHeight(small) + 8
            y += geometry.boxLabelHeight
        }
        let headerTop = y
        geometry.headerRects = (0..<count).map {
            CGRect(x: centers[$0] - headerWidths[$0] / 2, y: headerTop, width: headerWidths[$0], height: headerHeight)
        }
        y = headerTop + headerHeight + 18

        struct FrameBuilder {
            var kind: FrameKind
            var label: String
            var top: CGFloat
            var sections: [(y: CGFloat, label: String)] = []
            var minX: CGFloat?
            var maxX: CGFloat?
            var tabWidth: CGFloat
            mutating func include(_ low: CGFloat, _ high: CGFloat) {
                minX = min(minX ?? low, low)
                maxX = max(maxX ?? high, high)
            }
        }
        var openFrames: [FrameBuilder] = []
        var stacks: [[CGFloat]] = Array(repeating: [], count: count)
        var lastMessageY: CGFloat?
        let tabHeight = AgentDiagramText.lineHeight(small) + 6
        let lowestCenter = centers.first ?? 0
        let highestCenter = centers.last ?? 0

        func edge(_ participant: Int, towardRight: Bool) -> CGFloat {
            let level = stacks[participant].count
            guard level > 0 else { return centers[participant] }
            let bar = Self.barRect(center: centers[participant], level: level, top: 0, bottom: 1)
            return towardRight ? bar.maxX : bar.minX
        }
        func include(_ low: CGFloat, _ high: CGFloat) {
            guard !openFrames.isEmpty else { return }
            openFrames[openFrames.count - 1].include(low, high)
        }
        func activate(_ participant: Int, at top: CGFloat) {
            guard stacks[participant].count < 8 else { return }
            stacks[participant].append(top)
            include(centers[participant] - Self.barWidth, centers[participant] + Self.barWidth)
        }
        func deactivate(_ participant: Int, at bottom: CGFloat) {
            guard let top = stacks[participant].popLast() else { return }
            let level = stacks[participant].count + 1
            geometry.activations.append(ActivationGeometry(
                participant: participant, level: level,
                rect: Self.barRect(center: centers[participant], level: level, top: top, bottom: bottom)
            ))
        }

        for (index, event) in events.enumerated() {
            let textSize = eventTextSizes[index]
            var messageY: CGFloat?
            switch event {
            case let .message(message):
                let labelHeight = max(textSize.height, message.number == nil ? 0 : 16)
                y += labelHeight + 6
                let lineY = y
                messageY = lineY
                if message.from == message.to {
                    let start = edge(message.from, towardRight: true)
                    if message.activatesTarget { activate(message.to, at: lineY + Self.selfLoopHeight) }
                    let badge: CGFloat = message.number == nil ? 0 : 22
                    let labelRect = CGRect(x: start + 6 + badge, y: lineY - textSize.height - 3, width: textSize.width, height: textSize.height)
                    geometry.messages.append(MessageGeometry(event: index, y: lineY, startX: start, endX: start, isSelf: true, labelRect: labelRect))
                    include(centers[message.from] - Self.barWidth, max(start + Self.selfLoopWidth, labelRect.maxX) + 4)
                    if message.deactivatesSource { deactivate(message.from, at: lineY + Self.selfLoopHeight) }
                    y += Self.selfLoopHeight + 10
                } else {
                    let towardRight = message.to > message.from
                    let start = edge(message.from, towardRight: towardRight)
                    if message.activatesTarget { activate(message.to, at: lineY) }
                    let end = edge(message.to, towardRight: !towardRight)
                    let mid = (start + end) / 2
                    let labelRect = CGRect(x: mid - textSize.width / 2, y: lineY - textSize.height - 3, width: textSize.width, height: textSize.height)
                    geometry.messages.append(MessageGeometry(event: index, y: lineY, startX: start, endX: end, isSelf: false, labelRect: labelRect))
                    include(min(start, end, labelRect.minX), max(start, end, labelRect.maxX))
                    if message.deactivatesSource { deactivate(message.from, at: lineY) }
                    y += 12
                }
            case let .note(note):
                guard let first = note.participants.first else { continue }
                let width = max(textSize.width + 20, 60)
                let height = textSize.height + 12
                y += 4
                var rect: CGRect
                switch note.placement {
                case .leftOf:
                    let right = edge(first, towardRight: false) - 6
                    rect = CGRect(x: right - width, y: y, width: width, height: height)
                case .rightOf:
                    let left = edge(first, towardRight: true) + 6
                    rect = CGRect(x: left, y: y, width: width, height: height)
                case .over:
                    let low = centers[note.participants.min() ?? first]
                    let high = centers[note.participants.max() ?? first]
                    let spanned = high > low ? high - low + 50 : width
                    let noteWidth = max(width, spanned)
                    rect = CGRect(x: (low + high) / 2 - noteWidth / 2, y: y, width: noteWidth, height: height)
                }
                rect = rect.integral
                geometry.notes.append(NoteGeometry(text: note.text, rect: rect))
                include(rect.minX, rect.maxX)
                y += height + 10
            case let .activate(participant):
                activate(participant, at: lastMessageY ?? y)
            case let .deactivate(participant):
                deactivate(participant, at: lastMessageY ?? y)
            case let .frameStart(kind, label):
                y += 6
                let tabWidth = AgentDiagramText.width(kind.rawValue, font: Self.boldFont(small)) + 18
                openFrames.append(FrameBuilder(kind: kind, label: label, top: y, tabWidth: tabWidth + textSize.width + 12))
                y += kind == .rect ? 8 : tabHeight + 8
            case let .frameSection(label):
                y += 4
                if !openFrames.isEmpty {
                    openFrames[openFrames.count - 1].sections.append((y, label))
                    openFrames[openFrames.count - 1].tabWidth = max(openFrames[openFrames.count - 1].tabWidth, textSize.width + 24)
                }
                y += tabHeight + 6
            case .frameEnd:
                guard let frame = openFrames.popLast() else { continue }
                y += 6
                let inset: CGFloat = 12
                let low = (frame.minX ?? lowestCenter - 30) - inset
                var high = (frame.maxX ?? max(highestCenter, lowestCenter) + 30) + inset
                high = max(high, low + frame.tabWidth + 8)
                let rect = CGRect(x: low, y: frame.top, width: high - low, height: y - frame.top)
                geometry.frames.append(FrameGeometry(kind: frame.kind, label: frame.label, depth: openFrames.count, rect: rect, sections: frame.sections))
                include(rect.minX, rect.maxX)
                y += 6
            }
            lastMessageY = messageY
        }

        y += 12
        for participant in 0..<count {
            while !stacks[participant].isEmpty { deactivate(participant, at: y - 6) }
        }
        let footerTop = y
        geometry.footerRects = geometry.headerRects.map { CGRect(x: $0.minX, y: footerTop, width: $0.width, height: headerHeight) }
        y = footerTop + headerHeight

        for box in boxes where !box.participants.isEmpty {
            let low = box.participants.map { geometry.headerRects[$0].minX }.min() ?? 0
            let high = box.participants.map { geometry.headerRects[$0].maxX }.max() ?? 0
            let labelWidth = AgentDiagramText.size(box.label, font: small).width + 16
            let width = max(high - low + 20, labelWidth)
            let center = (low + high) / 2
            geometry.boxRects.append(CGRect(x: center - width / 2, y: headerTop - geometry.boxLabelHeight, width: width, height: y + 6 - (headerTop - geometry.boxLabelHeight)))
        }
        if !boxes.isEmpty { y += 6 }

        // Normalize horizontally so the leftmost element sits at the margin.
        var minX = geometry.headerRects.map(\.minX).min() ?? 0
        var maxX = geometry.headerRects.map(\.maxX).max() ?? 0
        minX = min(minX, centers.first.map { $0 - leftExtra } ?? minX)
        maxX = max(maxX, centers.last.map { $0 + rightExtra } ?? maxX)
        let extents: [CGRect] = geometry.boxRects + geometry.frames.map(\.rect) + geometry.notes.map(\.rect)
            + geometry.messages.map(\.labelRect) + geometry.activations.map(\.rect)
        for rect in extents {
            minX = min(minX, rect.minX)
            maxX = max(maxX, rect.maxX)
        }
        for message in geometry.messages where message.isSelf {
            maxX = max(maxX, message.startX + Self.selfLoopWidth + 4)
        }
        geometry.shift(Self.margin - minX)
        var width = maxX - minX + Self.margin * 2
        if let titleRect = geometry.titleRect {
            width = max(width, titleRect.width + Self.margin * 2)
            geometry.titleRect = CGRect(x: (width - titleRect.width) / 2, y: titleRect.minY, width: titleRect.width, height: titleRect.height)
        }
        geometry.size = CGSize(width: ceil(width), height: ceil(y + Self.margin))
        return geometry
    }
}

// MARK: - Drawing

private extension AgentSequenceDiagram {
    func draw(_ geometry: Geometry, style: AgentDiagramStyle, in context: CGContext) {
        let font = style.font
        let small = Self.smallFont(style)
        let smallBold = Self.boldFont(small)

        for (index, rect) in geometry.boxRects.enumerated() {
            AgentDiagramTextStroke.rect(context, rect, radius: 6, fill: AgentDiagramText.faded(style.accentSoft, 0.7), stroke: style.border)
            let label = boxes.filter { !$0.participants.isEmpty }[index].label
            AgentDiagramText.draw(label, in: CGRect(x: rect.minX, y: rect.minY + 4, width: rect.width, height: geometry.boxLabelHeight), font: smallBold, color: style.foreground, alignment: .center)
        }
        for frame in geometry.frames.sorted(by: { $0.depth < $1.depth }) where frame.kind == .rect {
            AgentDiagramTextStroke.rect(context, frame.rect, radius: 4, fill: style.accentSoft)
        }
        for (index, center) in geometry.centers.enumerated() {
            let top = geometry.headerRects[index].maxY
            let bottom = geometry.footerRects[index].minY
            AgentDiagramTextStroke.line(context, from: CGPoint(x: center, y: top), to: CGPoint(x: center, y: bottom), color: style.border, dashed: true)
        }
        for activation in geometry.activations.sorted(by: { $0.level < $1.level }) {
            AgentDiagramTextStroke.rect(context, activation.rect, fill: style.surface, stroke: style.muted)
        }
        for frame in geometry.frames where frame.kind != .rect {
            drawFrame(frame, style: style, small: small, smallBold: smallBold, in: context)
        }
        for message in geometry.messages {
            guard case let .message(model) = events[message.event] else { continue }
            drawMessage(model, geometry: message, style: style, small: small, in: context)
        }
        for note in geometry.notes {
            AgentDiagramTextStroke.rect(context, note.rect, radius: 3, fill: style.surface)
            AgentDiagramTextStroke.rect(context, note.rect, radius: 3, fill: style.warning.withAlphaComponent(0.16), stroke: style.warning.withAlphaComponent(0.6))
            AgentDiagramText.draw(note.text, centeredAt: CGPoint(x: note.rect.midX, y: note.rect.midY), font: font, color: style.foreground)
        }
        for (index, participant) in participants.enumerated() {
            drawParticipant(participant, in: geometry.headerRects[index], style: style, in: context)
            drawParticipant(participant, in: geometry.footerRects[index], style: style, in: context)
        }
        if let title, let titleRect = geometry.titleRect {
            AgentDiagramText.draw(title, in: titleRect, font: Self.boldFont(font), color: style.foreground, alignment: .center)
        }
    }

    func drawFrame(_ frame: FrameGeometry, style: AgentDiagramStyle, small: NSFont, smallBold: NSFont, in context: CGContext) {
        AgentDiagramTextStroke.rect(context, frame.rect, radius: 3, stroke: style.border)
        let name = frame.kind.rawValue
        let tabHeight = AgentDiagramText.lineHeight(small) + 6
        let tabWidth = AgentDiagramText.width(name, font: smallBold) + 16
        let origin = frame.rect.origin
        context.saveGState()
        context.move(to: origin)
        context.addLine(to: CGPoint(x: origin.x + tabWidth, y: origin.y))
        context.addLine(to: CGPoint(x: origin.x + tabWidth, y: origin.y + tabHeight - 5))
        context.addLine(to: CGPoint(x: origin.x + tabWidth - 5, y: origin.y + tabHeight))
        context.addLine(to: CGPoint(x: origin.x, y: origin.y + tabHeight))
        context.closePath()
        context.setFillColor(style.surface.cgColor)
        context.setStrokeColor(style.border.cgColor)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
        AgentDiagramText.draw(name, in: CGRect(x: origin.x, y: origin.y + 3, width: tabWidth, height: tabHeight), font: smallBold, color: style.foreground, alignment: .center)
        if !frame.label.isEmpty {
            AgentDiagramText.draw("[\(frame.label)]", in: CGRect(x: origin.x + tabWidth + 8, y: origin.y + 3, width: frame.rect.width, height: tabHeight), font: small, color: style.muted, alignment: .left)
        }
        for section in frame.sections {
            AgentDiagramTextStroke.line(context, from: CGPoint(x: frame.rect.minX, y: section.y), to: CGPoint(x: frame.rect.maxX, y: section.y), color: style.border, dashed: true)
            if !section.label.isEmpty {
                AgentDiagramText.draw("[\(section.label)]", in: CGRect(x: frame.rect.minX + 8, y: section.y + 3, width: frame.rect.width, height: tabHeight), font: small, color: style.muted, alignment: .left)
            }
        }
    }

    func drawMessage(_ message: Message, geometry: MessageGeometry, style: AgentDiagramStyle, small: NSFont, in context: CGContext) {
        let marker: AgentDiagramTextMarker
        switch message.head {
        case .none: marker = .none
        case .filled: marker = .filledArrow
        case .cross: marker = .cross
        case .open: marker = .openArrow
        }
        let y = geometry.y
        if geometry.isSelf {
            let start = CGPoint(x: geometry.startX, y: y)
            let corner = geometry.startX + Self.selfLoopWidth
            let end = CGPoint(x: geometry.startX, y: y + Self.selfLoopHeight)
            AgentDiagramTextStroke.polyline(context, [start, CGPoint(x: corner, y: y), CGPoint(x: corner, y: end.y), end], color: style.foreground, dashed: message.dashed)
            AgentDiagramTextStroke.marker(context, marker, tip: end, from: CGPoint(x: corner, y: end.y), color: style.foreground, fill: style.surface)
        } else {
            let start = CGPoint(x: geometry.startX, y: y)
            let end = CGPoint(x: geometry.endX, y: y)
            AgentDiagramTextStroke.line(context, from: start, to: end, color: style.foreground, dashed: message.dashed)
            AgentDiagramTextStroke.marker(context, marker, tip: end, from: start, color: style.foreground, fill: style.surface)
            if message.bidirectional {
                AgentDiagramTextStroke.marker(context, marker, tip: start, from: end, color: style.foreground, fill: style.surface)
            }
        }
        AgentDiagramText.draw(message.text, in: geometry.labelRect, font: style.font, color: style.foreground, alignment: geometry.isSelf ? .left : .center)
        if let number = message.number {
            let center = CGPoint(x: geometry.startX + (geometry.isSelf || geometry.endX > geometry.startX ? 9 : -9), y: y - 9)
            let circle = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
            context.saveGState()
            context.setFillColor(style.accent.cgColor)
            context.fillEllipse(in: circle)
            context.restoreGState()
            let numberFont = NSFont.systemFont(ofSize: max(small.pointSize - 2, 8), weight: .semibold)
            AgentDiagramText.draw(String(number), centeredAt: center, font: numberFont, color: style.surface)
        }
    }

    func drawParticipant(_ participant: Participant, in rect: CGRect, style: AgentDiagramStyle, in context: CGContext) {
        guard participant.kind == .actor else {
            AgentDiagramTextStroke.rect(context, rect, radius: 5, fill: style.surface, stroke: style.border)
            AgentDiagramText.draw(participant.label, centeredAt: CGPoint(x: rect.midX, y: rect.midY), font: style.font, color: style.foreground)
            return
        }
        let labelSize = AgentDiagramText.size(participant.label, font: style.font)
        let figureBottom = rect.maxY - labelSize.height - 4
        let headCenter = CGPoint(x: rect.midX, y: rect.minY + 7)
        context.saveGState()
        context.setStrokeColor(style.foreground.cgColor)
        context.setFillColor(style.surface.cgColor)
        context.setLineWidth(1.4)
        context.setLineCap(.round)
        let head = CGRect(x: headCenter.x - 6, y: headCenter.y - 6, width: 12, height: 12)
        context.fillEllipse(in: head)
        context.strokeEllipse(in: head)
        let neck = CGPoint(x: headCenter.x, y: headCenter.y + 6)
        let hip = CGPoint(x: headCenter.x, y: figureBottom - 9)
        context.move(to: neck)
        context.addLine(to: hip)
        context.move(to: CGPoint(x: hip.x - 10, y: neck.y + 6))
        context.addLine(to: CGPoint(x: hip.x + 10, y: neck.y + 6))
        context.move(to: CGPoint(x: hip.x - 8, y: figureBottom))
        context.addLine(to: hip)
        context.addLine(to: CGPoint(x: hip.x + 8, y: figureBottom))
        context.strokePath()
        context.restoreGState()
        AgentDiagramText.draw(participant.label, in: CGRect(x: rect.minX, y: rect.maxY - labelSize.height, width: rect.width, height: labelSize.height), font: style.font, color: style.foreground, alignment: .center)
    }
}
