import Foundation

/// Fuzzy matching and ranking shared by every list that filters as the user
/// types. Match ranges are UTF-16 offsets into the candidate, so they can
/// highlight an `NSAttributedString` directly.
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

    /// Lowercases a query into the characters `match` compares against.
    public static func normalize(_ query: String) -> [Unicode.Scalar] {
        query.unicodeScalars.map(lowered)
    }

    /// Scores `candidate` against a `normalize`d query. Every possible first
    /// character is tried so an early directory match cannot hide a stronger
    /// consecutive match in the basename. Matches after the last `/`, at word
    /// or camel-case boundaries, and consecutive matches score higher.
    public static func match(_ candidate: String, _ query: [Unicode.Scalar]) -> Match? {
        if query.isEmpty { return Match() }
        let scalars = Array(candidate.unicodeScalars)
        var offsets: [Int] = []
        offsets.reserveCapacity(scalars.count)
        var offset = 0
        var basename = 0
        for scalar in scalars {
            offsets.append(offset)
            offset += scalar.utf16.count
            if scalar == "/" { basename = offset }
        }
        var best: Match?
        for start in scalars.indices {
            var matched = 0
            var score = 0
            var ranges: [Range<Int>] = []
            var previous: Int?
            for index in start..<scalars.count {
                let scalar = scalars[index]
                guard lowered(scalar) == query[matched] else {
                    if index == start { break }
                    continue
                }
                score += 10 + (offsets[index] >= basename ? 20 : 0)
                if index == 0 || !isAlphanumeric(scalars[index - 1])
                    || (scalars[index - 1].properties.isLowercase && scalar.properties.isUppercase)
                {
                    score += 15
                }
                if let previous, previous == index - 1 { score += 25 }
                previous = index
                ranges.append(offsets[index]..<offsets[index] + scalar.utf16.count)
                matched += 1
                if matched == query.count {
                    if best.map({ score > $0.score }) ?? true { best = Match(score: score, ranges: ranges) }
                    break
                }
            }
        }
        return best
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
        let query = normalize(query)
        var ranked: [(Ranked<Item>, String)] = []
        for item in candidates {
            let text = key(item)
            guard let found = match(text, query) else { continue }
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

    private static func lowered(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        scalar.properties.lowercaseMapping.unicodeScalars.first ?? scalar
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}
