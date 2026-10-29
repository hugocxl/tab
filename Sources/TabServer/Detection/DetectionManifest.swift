import Foundation
import TabProtocol

/// A provider's rule manifest as stored in `Resources/Detection/*.json`.
struct DetectionManifest: Decodable {
    var id: String?
    var aliases: [String]?
    var rules: [Rule]

    struct Rule: Decodable {
        var id: String
        var state: String
        var priority: Int
        var region: String
        var visibleIdle: Bool
        var skipStateUpdate: Bool
        var gate: Gate

        enum CodingKeys: String, CodingKey {
            case id, state, priority, region
            case visibleIdle = "visible_idle"
            case skipStateUpdate = "skip_state_update"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            state = try container.decode(String.self, forKey: .state)
            priority = try container.decode(Int.self, forKey: .priority)
            region = try container.decode(String.self, forKey: .region)
            visibleIdle = try container.decodeIfPresent(Bool.self, forKey: .visibleIdle) ?? false
            skipStateUpdate = try container.decodeIfPresent(Bool.self, forKey: .skipStateUpdate) ?? false
            gate = try Gate(from: decoder)
        }
    }

    /// Conditions that all hold for a rule to match.
    struct Gate: Decodable {
        var contains: [String]
        var regex: [String]
        var lineRegex: [String]
        var all: [Gate]
        var any: [Gate]
        var not: [Gate]

        enum CodingKeys: String, CodingKey {
            case contains, regex, all, any, not
            case lineRegex = "line_regex"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            contains = try container.decodeIfPresent([String].self, forKey: .contains) ?? []
            regex = try container.decodeIfPresent([String].self, forKey: .regex) ?? []
            lineRegex = try container.decodeIfPresent([String].self, forKey: .lineRegex) ?? []
            all = try container.decodeIfPresent([Gate].self, forKey: .all) ?? []
            any = try container.decodeIfPresent([Gate].self, forKey: .any) ?? []
            not = try container.decodeIfPresent([Gate].self, forKey: .not) ?? []
        }
    }
}

/// A rule's region text, with its lowercase form and lines computed once
/// however many rules read it.
final class RegionText {
    let text: String
    let string: NSString
    private(set) lazy var lowercased: String = text.lowercased()
    private(set) lazy var lines: [NSString] = ScreenLines(text[...]).lines.map { String($0) as NSString }

    init(_ text: Substring) {
        self.text = String(text)
        self.string = self.text as NSString
    }
}

/// A gate compiled once: lowercase needles and `NSRegularExpression`s.
struct DetectionMatcher {
    var contains: [String]
    var regex: [NSRegularExpression]
    var lines: [NSRegularExpression]
    var all: [DetectionMatcher]
    var any: [DetectionMatcher]
    var none: [DetectionMatcher]

    init(_ gate: DetectionManifest.Gate) throws {
        contains = gate.contains.map { $0.lowercased() }
        regex = try gate.regex.map { try NSRegularExpression(pattern: $0) }
        lines = try gate.lineRegex.map { try NSRegularExpression(pattern: $0) }
        all = try gate.all.map(DetectionMatcher.init)
        any = try gate.any.map(DetectionMatcher.init)
        none = try gate.not.map(DetectionMatcher.init)
    }

    func matches(_ text: RegionText) -> Bool {
        contains.allSatisfy { text.lowercased.range(of: $0, options: .literal) != nil }
            && regex.allSatisfy { Self.isMatch($0, text.string) }
            && lines.allSatisfy { pattern in text.lines.contains { Self.isMatch(pattern, $0) } }
            && all.allSatisfy { $0.matches(text) }
            && (any.isEmpty || any.contains { $0.matches(text) })
            && !none.contains { $0.matches(text) }
    }

    private static func isMatch(_ pattern: NSRegularExpression, _ string: NSString) -> Bool {
        pattern.firstMatch(in: string as String, range: NSRange(location: 0, length: string.length)) != nil
    }
}

/// A rule ready to evaluate.
struct DetectionRule {
    var id: String
    var state: AgentState
    var priority: Int
    var region: String
    var visibleIdle: Bool
    var skipStateUpdate: Bool
    var matcher: DetectionMatcher
}

enum DetectionManifestError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): message
        }
    }
}

extension DetectionManifest {
    /// The manifest's rules compiled and ordered by descending priority,
    /// keeping file order among equal priorities.
    static func compile(_ data: Data) throws -> [DetectionRule] {
        let manifest = try JSONDecoder().decode(DetectionManifest.self, from: data)
        let ordered = manifest.rules.enumerated().sorted {
            $0.element.priority != $1.element.priority
                ? $0.element.priority > $1.element.priority : $0.offset < $1.offset
        }
        return try ordered.map { _, rule in
            guard let state = AgentState(rawValue: rule.state) else {
                throw DetectionManifestError.invalid("\(rule.id): unknown state \(rule.state)")
            }
            guard DetectionRegion.isKnown(rule.region) else {
                throw DetectionManifestError.invalid("\(rule.id): unknown region \(rule.region)")
            }
            do {
                return DetectionRule(id: rule.id, state: state, priority: rule.priority, region: rule.region,
                                     visibleIdle: rule.visibleIdle, skipStateUpdate: rule.skipStateUpdate,
                                     matcher: try DetectionMatcher(rule.gate))
            } catch {
                throw DetectionManifestError.invalid("\(rule.id): \(error.localizedDescription)")
            }
        }
    }
}
