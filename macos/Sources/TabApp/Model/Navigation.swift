import TabCore

/// Back and forward through the projects and Home terminals the window
/// showed, like a browser's history.
public struct NavigationHistory: Equatable, Sendable {
    public struct Location: Hashable, Sendable {
        public var project: ProjectId
        public var tab: TabId?

        public init(project: ProjectId, tab: TabId?) {
            self.project = project
            self.tab = tab
        }
    }

    public static let limit = 100

    public private(set) var entries: [Location] = []
    public private(set) var cursor = 0

    public init() {}

    /// Records a visit; going somewhere new drops what was forward.
    public mutating func record(_ location: Location) {
        if entries.indices.contains(cursor), entries[cursor] == location { return }
        if !entries.isEmpty { entries.removeSubrange(min(cursor + 1, entries.count)...) }
        entries.append(location)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        cursor = entries.count - 1
    }

    /// The nearest place back or forward that still exists, and its index.
    public func target(forward: Bool, live: (Location) -> Bool) -> (Int, Location)? {
        if forward {
            guard cursor + 1 < entries.count else { return nil }
            for index in (cursor + 1)..<entries.count where live(entries[index]) { return (index, entries[index]) }
            return nil
        }
        guard cursor > 0 else { return nil }
        for index in stride(from: cursor - 1, through: 0, by: -1) where live(entries[index]) {
            return (index, entries[index])
        }
        return nil
    }

    /// Moves the cursor to a target that was navigated to.
    public mutating func commit(_ index: Int) {
        if entries.indices.contains(index) { cursor = index }
    }
}
