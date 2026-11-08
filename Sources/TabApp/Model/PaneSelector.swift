import Foundation
import TabCore
import TabProtocol

/// How `tab pane` names a pane: by its ID or a unique start of one, by the ID
/// or name of the terminal or agent it shows, by its exact title, or by a word
/// that is relative to the pane the command runs in: `self`, `focused`, or
/// `left`, `right`, `up` and `down` for its neighbors. A missing name means
/// the caller's pane.
struct PaneSelector {
    /// A pane that can be named.
    struct Candidate: Equatable {
        var id: PaneId
        /// The terminal or agent conversation it shows.
        var session: SessionId?
        var title: String
    }

    var candidates: [Candidate]
    /// The pane the command runs in.
    var caller: PaneId?
    /// The pane the user last focused.
    var focused: PaneId?
    /// The pane touching another on a side, in the same tab.
    var neighbor: (PaneId, Direction) -> PaneId?

    func resolve(_ name: String?) throws -> PaneId {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return try own() }
        let word = name.lowercased()
        switch word {
        case "self":
            return try own()
        case "focused":
            guard let focused else { throw ModelError("no pane has the focus") }
            return focused
        default:
            break
        }
        if let direction = Direction(rawValue: word) {
            guard let origin = caller ?? focused else {
                throw ModelError("\(word) names the pane beside yours, and this command doesn't run in a Tab pane")
            }
            guard let pane = neighbor(origin, direction) else {
                throw ModelError("no pane is \(Self.phrase(direction)) \(caller == nil ? "the focused one" : "yours")")
            }
            return pane
        }
        if let uuid = UUID(uuidString: name) {
            let found = candidates.filter { $0.id.uuid == uuid || $0.session?.uuid == uuid }
            guard let pane = found.first else { throw unknown(name) }
            return pane.id
        }
        if SessionName.isName(word) {
            let named = candidates.filter { $0.session.map(SessionName.of) == word }
            if !named.isEmpty { return try unique(named, name) }
        }
        if Self.isPrefix(word) {
            let started = candidates.filter {
                $0.id.description.hasPrefix(word) || $0.session?.description.hasPrefix(word) == true
            }
            if !started.isEmpty { return try unique(started, name) }
        }
        let titled = candidates.filter { $0.title.compare(name, options: [.caseInsensitive]) == .orderedSame }
        guard !titled.isEmpty else { throw unknown(name) }
        return try unique(titled, name)
    }

    private func own() throws -> PaneId {
        guard let caller else {
            throw ModelError("this command doesn't run in a Tab pane; name a pane from tab pane list")
        }
        return caller
    }

    private func unique(_ found: [Candidate], _ name: String) throws -> PaneId {
        let ids = Set(found.map(\.id))
        guard ids.count == 1, let pane = ids.first else {
            throw ModelError("\(name) names more than one pane; use its ID from tab pane list")
        }
        return pane
    }

    private func unknown(_ name: String) -> ModelError {
        ModelError("no pane is named \(name); run tab pane list")
    }

    /// Whether `word` could start an ID: 4 or more hex digits and dashes.
    static func isPrefix(_ word: String) -> Bool {
        word.count >= 4 && word.count < 36
            && word.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef-").contains($0) }
    }

    static func phrase(_ direction: Direction) -> String {
        switch direction {
        case .left: "left of"
        case .right: "right of"
        case .up: "above"
        case .down: "below"
        }
    }

    /// Where a pane of `rect` sits in its tab, as people say it: `left`,
    /// `top right`, `bottom`, `center` or `whole`.
    static func position(_ rect: UnitRect) -> String {
        let tolerance = 0.001
        let across = rect.width > 1 - tolerance ? nil
            : rect.x < tolerance ? "left" : rect.x + rect.width > 1 - tolerance ? "right" : "middle"
        let down = rect.height > 1 - tolerance ? nil
            : rect.y < tolerance ? "top" : rect.y + rect.height > 1 - tolerance ? "bottom" : "middle"
        switch (down, across) {
        case (nil, nil): return "whole"
        case (let down?, nil): return down
        case (nil, let across?): return across
        case ("middle", "middle"): return "center"
        case (let down?, let across?): return "\(down) \(across)"
        }
    }
}
