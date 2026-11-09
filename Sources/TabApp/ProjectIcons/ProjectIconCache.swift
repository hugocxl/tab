import AppKit
import Foundation

/// What a project icon lookup found.
public enum ProjectIconLookup: Sendable {
    case found(NSImage)
    /// The project has no icon.
    case none
    /// The project couldn't be searched now, such as while its server is
    /// away; the icon shown stays.
    case unavailable
}

/// Project icons, looked up once per project off the main thread and kept
/// as small thumbnails until the project is no longer shown. The icon
/// remembered from the last launch shows at once while the lookup checks it.
@MainActor
public final class ProjectIconCache {
    /// Finds the icon for a project key, such as a local folder's path.
    public typealias Lookup = @Sendable (String) async -> ProjectIconLookup

    private enum Entry {
        case loading(Task<Void, Never>)
        case loaded
    }

    private var entries: [String: Entry] = [:]
    /// Each key's thumbnail PNG, `nil` when it has none.
    private var thumbnails: [String: Data?] = [:]
    private var images: [String: NSImage] = [:]
    private var sized: [SizedKey: NSImage] = [:]
    private let lookup: Lookup
    /// Called with a project's key when its icon changes, to redraw its row.
    public var onChange: ((String) -> Void)?
    /// The thumbnail remembered from the last launch, if any.
    var remembered: ((String) -> Data?)?
    /// Called with a key's thumbnail, `nil` for none, after each lookup that
    /// changed it, so the next launch remembers it.
    var onLookedUp: ((String, Data?) -> Void)?

    private struct SizedKey: Hashable {
        var key: String
        var points: CGFloat
    }

    /// - Parameter lookup: how to find a key's icon; local folders by default.
    public init(lookup: @escaping Lookup = { path in
        await ProjectIconFinder.findLocal(root: URL(fileURLWithPath: path)).map { .found($0) } ?? .none
    }) {
        self.lookup = lookup
    }

    /// The icon for `key` at `points` (16 or 32 in the sidebar), or `nil`
    /// while it loads or when the project has none. The first call starts the
    /// lookup; `onChange` reports a changed icon.
    public func icon(for key: String, points: CGFloat = 16) -> NSImage? {
        if entries[key] == nil { load(key) }
        return sizedIcon(key, points: points)
    }

    /// The icon for `key` known so far, without starting a lookup.
    public func knownIcon(for key: String, points: CGFloat = 16) -> NSImage? {
        if thumbnails[key] == nil, let png = remembered?(key) { show(key, png: png) }
        return sizedIcon(key, points: points)
    }

    /// Whether `key`'s icon has been looked up.
    public func isLoaded(_ key: String) -> Bool {
        if case .loaded = entries[key] { return true }
        return false
    }

    /// Looks again for `key`'s icon next time it is asked for, such as after
    /// its files changed or its server reconnected. The icon shown stays
    /// until the new one arrives.
    public func invalidate(_ key: String) {
        if case .loading(let task) = entries[key] { task.cancel() }
        entries[key] = nil
    }

    /// Drops the icons of projects not in `keys`.
    public func retain(_ keys: Set<String>) {
        for key in Set(entries.keys).union(thumbnails.keys) where !keys.contains(key) {
            invalidate(key)
            thumbnails[key] = nil
            images[key] = nil
            sized = sized.filter { $0.key.key != key }
        }
    }

    private func sizedIcon(_ key: String, points: CGFloat) -> NSImage? {
        guard let image = images[key] else { return nil }
        let sizedKey = SizedKey(key: key, points: points)
        if let cached = sized[sizedKey] { return cached }
        let scaled = Self.scaled(image, to: points)
        sized[sizedKey] = scaled
        return scaled
    }

    private func load(_ key: String) {
        if thumbnails[key] == nil, let png = remembered?(key) { show(key, png: png) }
        let lookup = lookup
        let task = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> (Data?, Bool) in
                switch await lookup(key) {
                case .found(let image): return (SidebarMemory.thumbnail(image), true)
                case .none: return (nil, true)
                case .unavailable: return (nil, false)
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            // An unavailable project waits for `invalidate`, such as on reconnecting.
            self.entries[key] = .loaded
            guard found.1 else { return }
            let png = found.0
            let changed = self.thumbnails[key] != .some(png)
            self.show(key, png: png)
            if changed || self.remembered?(key) != png { self.onLookedUp?(key, png) }
            if changed { self.onChange?(key) }
        }
        entries[key] = .loading(task)
    }

    private func show(_ key: String, png: Data?) {
        if thumbnails[key] == .some(png) { return }
        thumbnails[key] = .some(png)
        images[key] = png.flatMap { NSImage(data: $0) }
        sized = sized.filter { $0.key.key != key }
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
