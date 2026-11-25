import Foundation
import TabProtocol

/// Gives a simulator's elements refs such as `e3` that last while they stay
/// on screen: an element keeps its ref across snapshots while its role,
/// label and identifier stay the same, even when it moves, so an agent can
/// act on a ref it saw before a scroll. New elements get new numbers; a
/// ref is never reused for another element.
public struct SimulatorRefs: Sendable {
    public private(set) var elements: [SimulatorElement] = []
    private var refs: [Key: String] = [:]
    private var next = 1
    /// Whether a snapshot was taken.
    public var isEmpty: Bool { elements.isEmpty }

    public init() {}

    /// What changed between two snapshots.
    public struct Changes: Equatable, Sendable {
        public var added: [SimulatorElement] = []
        public var removed: [SimulatorElement] = []
        /// Still there, with another value or state.
        public var changed: [SimulatorElement] = []
        public var unchanged = 0
    }

    /// Takes a new snapshot, giving each element its ref; returns them and
    /// what changed since the last one.
    @discardableResult
    public mutating func update(_ fresh: [SimulatorElement]) -> (elements: [SimulatorElement], changes: Changes) {
        let keyed = Self.keys(for: elements)
        var previousByKey: [Key: SimulatorElement] = [:]
        for (element, key) in zip(elements, keyed) { previousByKey[key] = element }

        var changes = Changes()
        var seen: Set<Key> = []
        var assigned: [SimulatorElement] = []
        var refs: [Key: String] = [:]
        for (var element, key) in zip(fresh, Self.keys(for: fresh)) {
            if let ref = self.refs[key] {
                element.ref = ref
                if let before = previousByKey[key] {
                    // A move alone isn't a change: the ref still works, and a scroll moves everything.
                    if before.value != element.value || before.enabled != element.enabled {
                        changes.changed.append(element)
                    } else {
                        changes.unchanged += 1
                    }
                }
            } else {
                element.ref = "e\(next)"
                next += 1
                changes.added.append(element)
            }
            refs[key] = element.ref
            seen.insert(key)
            assigned.append(element)
        }
        for (element, key) in zip(elements, keyed) where !seen.contains(key) {
            changes.removed.append(element)
        }
        self.refs = refs
        elements = assigned
        return (assigned, changes)
    }

    /// The element `ref` names in the last snapshot.
    public func element(_ ref: String) -> SimulatorElement? {
        let name = ref.hasPrefix("@") ? String(ref.dropFirst()) : ref
        return elements.first { $0.ref == name }
    }

    /// Forgets the snapshot, such as when the simulator restarted.
    public mutating func reset() {
        elements = []
        refs = [:]
    }

    /// Who an element is: its role, label and identifier, and which of the
    /// elements alike it is, in order.
    private struct Key: Hashable {
        var role: String
        var label: String?
        var identifier: String?
        var occurrence: Int

        init(_ element: SimulatorElement, occurrence: Int) {
            role = element.role
            label = element.label
            identifier = element.identifier
            self.occurrence = occurrence
        }
    }

    private static func keys(for elements: [SimulatorElement]) -> [Key] {
        var counts: [Key: Int] = [:]
        return elements.map { element in
            let base = Key(element, occurrence: 0)
            let occurrence = counts[base, default: 0]
            counts[base] = occurrence + 1
            return Key(element, occurrence: occurrence)
        }
    }

    // MARK: Finding

    /// The first element whose label is `text`, ignoring case, else the
    /// first whose label or value contains it; interactive ones first.
    public static func find(label text: String, in elements: [SimulatorElement]) -> SimulatorElement? {
        let ordered = elements.filter(\.interactive) + elements.filter { !$0.interactive }
        let needle = text.lowercased()
        if let exact = ordered.first(where: { $0.label?.lowercased() == needle }) { return exact }
        return ordered.first { ($0.label?.lowercased().contains(needle) ?? false) || ($0.value?.lowercased().contains(needle) ?? false) }
    }

    public static func find(identifier: String, in elements: [SimulatorElement]) -> SimulatorElement? {
        elements.first { $0.identifier == identifier }
    }

    // MARK: Compacting

    /// Drops what an agent can't use: zero-sized elements and unnamed
    /// groups, keeping their children one level up.
    public static func compact(_ elements: [SimulatorElement]) -> [SimulatorElement] {
        var kept: [SimulatorElement] = []
        /// The original depths of the kept ancestors of the next element.
        var ancestors: [Int] = []
        for var element in elements {
            while let last = ancestors.last, last >= element.depth { ancestors.removeLast() }
            let named = element.label != nil || element.identifier != nil || element.value != nil
            let structural = ["group", "element", "scroll-view", "collection", "list", "toolbar"].contains(element.role)
            let empty = element.width < 1 || element.height < 1
            if empty || (structural && !named && !element.interactive) { continue }
            let depth = element.depth
            element.depth = ancestors.count
            ancestors.append(depth)
            kept.append(element)
        }
        return kept
    }
}
