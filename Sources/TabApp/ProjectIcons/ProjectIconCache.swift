import AppKit
import Foundation

/// Project icons, looked up once per project folder off the main thread and
/// kept until the folder is invalidated or no longer shown.
@MainActor
public final class ProjectIconCache {
    /// Finds the icon for a project key, such as a local folder's path.
    public typealias Lookup = @Sendable (String) async -> NSImage?

    private enum Entry {
        case loading(Task<Void, Never>)
        case loaded(NSImage?)
    }

    private var entries: [String: Entry] = [:]
    private var sized: [SizedKey: NSImage] = [:]
    private let lookup: Lookup
    /// Called with a project's key when its icon arrives, to redraw its row.
    public var onChange: ((String) -> Void)?

    private struct SizedKey: Hashable {
        var key: String
        var points: CGFloat
    }

    /// - Parameter lookup: how to find a key's icon; local folders by default.
    public init(lookup: @escaping Lookup = { path in await ProjectIconFinder.findLocal(root: URL(fileURLWithPath: path)) }) {
        self.lookup = lookup
    }

    /// The icon for `key` at `points` (16 or 32 in the sidebar), or `nil`
    /// while it loads or when the project has none. The first call starts the
    /// lookup; `onChange` reports its end.
    public func icon(for key: String, points: CGFloat = 16) -> NSImage? {
        switch entries[key] {
        case .loaded(let image?):
            let sizedKey = SizedKey(key: key, points: points)
            if let cached = sized[sizedKey] { return cached }
            let scaled = Self.scaled(image, to: points)
            sized[sizedKey] = scaled
            return scaled
        case .loaded(nil), .loading:
            return nil
        case nil:
            load(key)
            return nil
        }
    }

    /// Whether `key`'s icon has been looked up.
    public func isLoaded(_ key: String) -> Bool {
        if case .loaded = entries[key] { return true }
        return false
    }

    /// Looks again for `key`'s icon next time it is asked for, such as after
    /// its files changed or its server reconnected.
    public func invalidate(_ key: String) {
        if case .loading(let task) = entries[key] { task.cancel() }
        entries[key] = nil
        sized = sized.filter { $0.key.key != key }
    }

    /// Drops the icons of projects not in `keys`.
    public func retain(_ keys: Set<String>) {
        for key in entries.keys where !keys.contains(key) { invalidate(key) }
    }

    private func load(_ key: String) {
        let lookup = lookup
        let task = Task { [weak self] in
            let image = await Task.detached(priority: .utility) { await lookup(key) }.value
            guard !Task.isCancelled, let self else { return }
            self.entries[key] = .loaded(image)
            self.onChange?(key)
        }
        entries[key] = .loading(task)
    }

    /// A copy drawn at `points` square, keeping the best representations for
    /// Retina screens.
    static func scaled(_ image: NSImage, to points: CGFloat) -> NSImage {
        let size = NSSize(width: points, height: points)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}
