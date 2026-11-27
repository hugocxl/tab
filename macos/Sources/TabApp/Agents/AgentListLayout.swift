import AppKit

/// Resolves shared list gutters before laying out individual paragraphs. The source uses
/// 20px for single-digit lists and (decimal digit count + 2)ch for wider lists.
enum AgentListLayout {
    private struct Group {
        var parent: Int?
        var depth: Int
        var ordered: Bool
        var missingAncestorInset: CGFloat
        var lastNumber: Int?
        var digits = 1
    }

    static func indents(_ blocks: [AgentMarkdown.Block], font: NSFont) -> [Int: CGFloat] {
        var groups: [Group] = []
        var stack: [Int] = []
        var membership: [Int: Int] = [:]
        for (index, block) in blocks.enumerated() {
            let marker: String
            let depth: Int
            switch block {
            case .list(let value, _, let level, _), .listBlock(let value, _, let level, _): marker = value; depth = level
            case .nested(.list(let value, let level, _, _), _): marker = value; depth = level
            case .reference, .footnoteDefinition: continue
            default: stack.removeAll(); continue
            }
            let ordered = marker.hasSuffix(".")
            while let last = stack.last, groups[last].depth > depth { stack.removeLast() }
            let ancestors = stack.filter { groups[$0].depth < depth }
            let orderedDepth = ancestors.filter { groups[$0].ordered }.count
            let number = ordered ? number(marker: marker, orderedDepth: orderedDepth) : nil
            if let last = stack.last, groups[last].depth == depth {
                let previous = groups[last]
                if previous.ordered != ordered || (number != nil && previous.lastNumber.map { number != $0 + 1 } == true) {
                    stack.removeLast()
                }
            }
            if stack.last.map({ groups[$0].depth != depth }) ?? true {
                let parent = stack.last
                stack.append(groups.count)
                groups.append(Group(parent: parent, depth: depth, ordered: ordered, missingAncestorInset: CGFloat(max(0, depth - (parent.map { groups[$0].depth + 1 } ?? 0))) * 20, lastNumber: nil))
            }
            guard let group = stack.last else { continue }
            if let number {
                groups[group].lastNumber = number
                groups[group].digits = max(groups[group].digits, String(number).count)
            }
            membership[index] = group
        }
        // Chromium resolves CSS ch from the system font's untracked zero metric;
        // AppKit's optical tracking changes the painted glyph advance at 14pt.
        let ch = font.pointSize * 1290 / 2048
        var offsets: [CGFloat] = []
        for group in groups {
            let gutter: CGFloat = group.ordered && group.digits > 1 ? AgentMarkdownLayout.units(CGFloat(group.digits + 2) * ch) : 20
            offsets.append((group.parent.map { offsets[$0] } ?? 0) + group.missingAncestorInset + gutter)
        }
        var result = membership.mapValues { offsets[$0] }
        let structures = Dictionary(blocks.compactMap { $0.listStructure }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func offset(_ structure: AgentListItemStructure) -> CGFloat {
            let parent = structure.parentID.flatMap { structures[$0] }
            return (parent.map(offset) ?? 0) + gutter(structure: structure, blocks: blocks, font: font)
        }
        for (index, block) in blocks.enumerated() {
            if let structure = block.listStructure { result[index] = offset(structure) }
        }
        return result
    }

    static func gutter(structure: AgentListItemStructure?, blocks: [AgentMarkdown.Block], font: NSFont) -> CGFloat {
        guard let structure, let start = structure.start else { return 20 }
        let last = structure.lastNumber ?? blocks.compactMap { $0.listStructure }.filter { $0.id == structure.id }.compactMap { $0.number }.max() ?? start
        let digits = max(String(start).count, String(last).count)
        guard digits > 1 else { return 20 }
        return AgentMarkdownLayout.units(CGFloat(digits + 2) * font.pointSize * 1290 / 2048)
    }

    private static func number(marker: String, orderedDepth: Int) -> Int? {
        let label = marker.dropLast()
        if let decimal = Int(label) { return decimal }
        if orderedDepth < 2 {
            var result = 0
            for scalar in label.unicodeScalars {
                guard (97...122).contains(scalar.value) else { return nil }
                result = result * 26 + Int(scalar.value - 96)
            }
            return result
        }
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000]
        var total = 0, previous = 0
        for character in label.reversed() {
            guard let value = values[character] else { return nil }
            total += value < previous ? -value : value
            previous = value
        }
        return total
    }
}
