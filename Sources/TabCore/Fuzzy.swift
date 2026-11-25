import Foundation

/// Fuzzy matching and ranking shared by every list that filters as the user
/// types. Match ranges are UTF-16 offsets into the candidate, so they can
/// highlight an `NSAttributedString` directly.
///
/// Each whitespace-separated word of the query must match on its own, in any
/// order. A word matches when its characters appear in order, ignoring case
/// and diacritics; among all such alignments the best one is found with a
/// Smith-Waterman style dynamic program (as in fzf's v2 algorithm), so an
/// early stray character can never hide a stronger match later on. Scoring
/// favours, in roughly this order: the file name over its folders, the exact
/// name, characters at the start of words, runs of consecutive characters,
/// and short gaps.
public enum Fuzzy {
    /// A candidate that contains every query character in order.
    public struct Match: Equatable, Sendable {
        public var score: Int
        public var ranges: [Range<Int>]

        public init(score: Int = 0, ranges: [Range<Int>] = []) {
            self.score = score
            self.ranges = ranges
        }
    }

    /// A candidate kept by `rank`, with its score and matched ranges.
    public struct Ranked<Item> {
        public var item: Item
        public var score: Int
        public var ranges: [Range<Int>]
    }

    // Scores, in the spirit of fzf's: a matched character is worth `matchScore`
    // plus the bonus of where it lands; gaps cost a little, opening one more.
    static let matchScore = 16
    static let gapStart = 3
    static let gapExtension = 1
    static let bonusStart = 10
    static let bonusSeparator = 10
    static let bonusDelimiter = 8
    static let bonusCamel = 7
    static let bonusConsecutive = 4
    static let firstCharMultiplier = 2
    /// Per character matched in the last path component, so names beat folders.
    static let bonusBasename = 12
    /// The word is the whole file name, or the name without its extension.
    static let bonusExactName = 64
    /// The word starts the file name.
    static let bonusNamePrefix = 24
    /// The word is the whole candidate.
    static let bonusExact = 96

    /// Lowercases and strips diacritics from a query into the characters
    /// `match` compares against.
    public static func normalize(_ query: String) -> [Unicode.Scalar] {
        query.unicodeScalars.map(fold)
    }

    /// Scores `candidate` against a `normalize`d query, or nil when some
    /// word of the query does not match.
    public static func match(_ candidate: String, _ query: [Unicode.Scalar]) -> Match? {
        var scratch = Scratch()
        return match(candidate, words: words(query), scratch: &scratch)
    }

    /// The best `limit` candidates for `query`, highest score first. Ties go
    /// to the shorter key, then to the smaller one.
    public static func rank<Item>(
        _ candidates: some Sequence<Item>,
        key: (Item) -> String,
        query: String,
        limit: Int
    ) -> [Ranked<Item>] {
        guard limit > 0 else { return [] }
        let words = words(normalize(query))
        var scratch = Scratch()
        var ranked: [(Ranked<Item>, String)] = []
        for item in candidates {
            let text = key(item)
            guard let found = match(text, words: words, scratch: &scratch) else { continue }
            ranked.append((Ranked(item: item, score: found.score, ranges: found.ranges), text))
        }
        ranked.sort { left, right in
            if left.0.score != right.0.score { return left.0.score > right.0.score }
            let leftLength = left.1.utf8.count
            let rightLength = right.1.utf8.count
            if leftLength != rightLength { return leftLength < rightLength }
            return left.1 < right.1
        }
        return ranked.prefix(limit).map(\.0)
    }

    // MARK: Matching

    /// Buffers reused across the candidates of one ranking, so scoring a
    /// long file list does not allocate per candidate.
    struct Scratch {
        var scalars: [Unicode.Scalar] = []
        var folded: [Unicode.Scalar] = []
        var offsets: [Int] = []
        var bonuses: [Int] = []
        var score: [Int] = []
        var chain: [Int] = []
        var origin: [Int32] = []
        var positions: [Int] = []
        var aligned: [Int] = []
    }

    private static func words(_ query: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        query.split(whereSeparator: isWhitespace).map(Array.init)
    }

    static func match(_ candidate: String, words: [[Unicode.Scalar]], scratch: inout Scratch) -> Match? {
        if words.isEmpty { return Match() }
        scratch.scalars.removeAll(keepingCapacity: true)
        scratch.folded.removeAll(keepingCapacity: true)
        for scalar in candidate.unicodeScalars {
            scratch.scalars.append(scalar)
            scratch.folded.append(fold(scalar))
        }
        // Cheap rejection before any scoring.
        for word in words where !isSubsequence(word, of: scratch.folded) { return nil }

        let count = scratch.scalars.count
        scratch.offsets.removeAll(keepingCapacity: true)
        var offset = 0
        var basename = 0
        for index in 0..<count {
            let scalar = scratch.scalars[index]
            scratch.offsets.append(offset)
            offset += scalar.utf16.count
            if scalar == "/" { basename = index + 1 }
        }
        scratch.offsets.append(offset)
        // A trailing slash names a folder: its name is the component before it.
        if basename == count, basename > 0 {
            basename = (scratch.scalars[..<(basename - 1)].lastIndex(of: "/")).map { $0 + 1 } ?? 0
        }
        positionBonuses(&scratch)

        var total = 0
        scratch.positions.removeAll(keepingCapacity: true)
        for word in words {
            guard let score = align(word, basename: basename, scratch: &scratch) else { return nil }
            total += score + nameBonus(word, scratch.folded, basename: basename, start: scratch.aligned[0])
            scratch.positions.append(contentsOf: scratch.aligned)
        }
        if words.count > 1 { scratch.positions.sort() }
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(scratch.positions.count)
        var previous = -1
        for position in scratch.positions where position != previous {
            ranges.append(scratch.offsets[position]..<scratch.offsets[position + 1])
            previous = position
        }
        return Match(score: total, ranges: ranges)
    }

    private static let unmatched = Int.min / 4

    /// The best-scoring placement of `word` in the scratch's text, by dynamic
    /// programming over the columns where a match is possible at all. Leaves
    /// the matched indices in `scratch.aligned`.
    private static func align(_ word: [Unicode.Scalar], basename: Int, scratch: inout Scratch) -> Int? {
        let rows = word.count
        // The first column the first character can take, and the last the last can.
        guard let first = scratch.folded.firstIndex(of: word[0]),
              let last = scratch.folded.lastIndex(of: word[rows - 1]) else { return nil }
        let width = last - first + 1
        guard width >= rows else { return nil }
        let cells = rows * width
        if scratch.score.count < cells {
            scratch.score = [Int](repeating: 0, count: cells)
            scratch.chain = [Int](repeating: 0, count: cells)
            scratch.origin = [Int32](repeating: 0, count: cells)
        }
        // Moved out of the scratch while in use so the buffers can be borrowed together.
        var score = [Int](), chain = [Int](), origin = [Int32](), aligned = [Int]()
        swap(&score, &scratch.score)
        swap(&chain, &scratch.chain)
        swap(&origin, &scratch.origin)
        swap(&aligned, &scratch.aligned)
        defer {
            swap(&score, &scratch.score)
            swap(&chain, &scratch.chain)
            swap(&origin, &scratch.origin)
            swap(&aligned, &scratch.aligned)
        }
        let text = scratch.folded
        let bonuses = scratch.bonuses
        for row in 0..<rows {
            let character = word[row]
            let base = row * width
            let above = base - width
            var gap = unmatched
            var gapOrigin = -1
            for column in 0..<width { score[base + column] = unmatched }
            // A row can only start once every earlier character has room.
            for column in row..<width {
                if row > 0, column >= 2 {
                    let opened = score[above + column - 2]
                    let extended = gap == unmatched ? unmatched : gap - gapExtension
                    if opened != unmatched, opened - gapStart >= extended {
                        gap = opened - gapStart
                        gapOrigin = column - 2
                    } else {
                        gap = extended
                    }
                }
                let index = first + column
                guard text[index] == character else { continue }
                let bonus = bonuses[index]
                let inName = index >= basename ? bonusBasename : 0
                if row == 0 {
                    score[base + column] = matchScore + bonus * firstCharMultiplier + inName
                    chain[base + column] = bonus
                    continue
                }
                var best = unmatched
                if column >= 1, score[above + column - 1] != unmatched {
                    let carried = max(chain[above + column - 1], bonusConsecutive, bonus)
                    best = score[above + column - 1] + matchScore + carried + inName
                    chain[base + column] = carried
                    origin[base + column] = Int32(column - 1)
                }
                if gap != unmatched, gap + matchScore + bonus + inName > best {
                    best = gap + matchScore + bonus + inName
                    chain[base + column] = bonus
                    origin[base + column] = Int32(gapOrigin)
                }
                score[base + column] = best
            }
        }
        // Ties go to the later placement, which is nearer the file name.
        let lastRow = (rows - 1) * width
        var bestColumn = -1
        var bestScore = unmatched
        for column in (rows - 1)..<width where score[lastRow + column] != unmatched && score[lastRow + column] >= bestScore {
            bestScore = score[lastRow + column]
            bestColumn = column
        }
        guard bestColumn >= 0 else { return nil }
        aligned.removeAll(keepingCapacity: true)
        var column = bestColumn
        for row in stride(from: rows - 1, through: 0, by: -1) {
            aligned.append(first + column)
            column = Int(origin[row * width + column])
        }
        aligned.reverse()
        return bestScore
    }

    /// Extra credit when the word is, or starts, the file name or the whole
    /// candidate, so `permissions.ts` beats `key-permissions.ts`.
    private static func nameBonus(_ word: [Unicode.Scalar], _ text: [Unicode.Scalar], basename: Int, start: Int) -> Int {
        if word.elementsEqual(text) { return bonusExact }
        guard start >= basename else { return 0 }
        var name = text[basename...]
        if name.last == "/" { name = name.dropLast() }
        if word.elementsEqual(name) { return bonusExactName }
        if let dot = name.lastIndex(of: "."), dot > name.startIndex, word.elementsEqual(name[..<dot]) { return bonusExactName }
        if name.starts(with: word) { return bonusNamePrefix }
        return 0
    }

    /// How good a place each character is to match: the start of the text,
    /// a path component or a word, or a camel-case hump.
    private static func positionBonuses(_ scratch: inout Scratch) {
        scratch.bonuses.removeAll(keepingCapacity: true)
        var previous: Kind = .separator
        var atStart = true
        for scalar in scratch.scalars {
            let kind = Kind(scalar)
            var bonus = 0
            if kind.isWord {
                if atStart { bonus = bonusStart }
                else {
                    switch previous {
                    case .separator: bonus = bonusSeparator
                    case .delimiter: bonus = bonusDelimiter
                    case .lower where kind == .upper: bonus = bonusCamel
                    case .lower, .upper, .letter: bonus = kind == .digit ? bonusCamel : 0
                    case .digit: bonus = 0
                    }
                }
            }
            scratch.bonuses.append(bonus)
            previous = kind
            atStart = false
        }
    }

    private enum Kind: Equatable {
        case separator, delimiter, lower, upper, letter, digit

        init(_ scalar: Unicode.Scalar) {
            if scalar.isASCII {
                switch scalar.value {
                case 97...122: self = .lower
                case 65...90: self = .upper
                case 48...57: self = .digit
                case 47, 92, 32, 9, 10, 13: self = .separator
                default: self = .delimiter
                }
                return
            }
            let properties = scalar.properties
            if properties.isWhitespace { self = .separator }
            else if properties.isLowercase { self = .lower }
            else if properties.isUppercase { self = .upper }
            else if properties.isAlphabetic { self = .letter }
            else if properties.numericType != nil { self = .digit }
            else { self = .delimiter }
        }

        var isWord: Bool { self != .separator && self != .delimiter }
    }

    private static func isSubsequence(_ word: [Unicode.Scalar], of text: [Unicode.Scalar]) -> Bool {
        var next = 0
        for scalar in text where scalar == word[next] {
            next += 1
            if next == word.count { return true }
        }
        return false
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || (!scalar.isASCII && scalar.properties.isWhitespace)
    }

    /// Case- and diacritic-insensitive form of one scalar, so `e` finds `É`.
    private static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar.isASCII {
            let value = scalar.value
            return value >= 65 && value <= 90 ? Unicode.Scalar(value + 32)! : scalar
        }
        let lower = scalar.properties.lowercaseMapping
        let decomposed = lower.decomposedStringWithCanonicalMapping.unicodeScalars
        return decomposed.first ?? lower.unicodeScalars.first ?? scalar
    }
}
