import Foundation
import TabProtocol
import TabShared

/// Finds a project's icon among its files on the server, as the desktop
/// sidebar does: an app's `.icns`, a `favicon.ico` or a `logo.png`, listing
/// artwork folders first so a large project costs a handful of listings.
/// Git-ignored folders are skipped. Returns the file's bytes; the app decodes them.
enum ProjectIconFinder {
    static let artworkFolders: Set<String> = [
        ".github", "app", "art", "artwork", "assets", "brand", "branding", "build", "design", "docs",
        "icon", "icons", "images", "img", "logo", "logos", "mac", "macos", "media", "packaging",
        "public", "res", "resources", "src-tauri", "static", "windows",
    ]
    static let skippedFolders: Set<String> = [
        "__tests__", "coverage", "dist", "e2e", "fixtures", "node_modules", "out", "target", "test", "tests", "vendor",
    ]
    static let artworkCost = 0
    static let otherCost = 3
    static let nestedCost = 6
    static let maxDepth = 6
    static let maxListings = 48
    static let maxReads = 3

    struct Rank: Comparable {
        var name: Int
        var format: Int
        var depth: Int

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            (lhs.name, lhs.format, -lhs.depth) < (rhs.name, rhs.format, -rhs.depth)
        }
    }

    /// The best icon file's bytes that `isImage` accepts, or nil.
    static func find(client: ServerClient, project: ProjectId, isImage: (Data) -> Bool) async -> Data? {
        let paths = await candidates { directory in
            let reply = try? await client.files(FilesRequest(project: project, action: .list(ServerPath(directory))))
            guard case .entries(let entries)? = reply else { return [] }
            return entries.map { ($0.name.rawValue, $0.path.rawValue, $0.isDirectory, $0.isIgnored) }
        }
        for path in paths.prefix(maxReads) {
            let reply = try? await client.files(FilesRequest(project: project, action: .readBytes(ServerPath(path))))
            if case .bytes(let file)? = reply, isImage(file.bytes) { return file.bytes }
        }
        return nil
    }

    typealias Entry = (name: String, path: String, isDirectory: Bool, isIgnored: Bool)

    /// Icon files from the project root, best first. Directories are listed
    /// cheapest first, deepest first among equals.
    static func candidates(list: (String) async -> [Entry]) async -> [String] {
        struct Pending { var cost: Int; var depth: Int; var directory: String; var inArtwork: Bool }
        var found: [(Rank, String)] = []
        var queue = [Pending(cost: 0, depth: 0, directory: "", inArtwork: false)]
        var listings = 0
        while !queue.isEmpty, listings < maxListings {
            guard let next = queue.indices.min(by: { a, b in
                let x = queue[a], y = queue[b]
                if x.cost != y.cost { return x.cost < y.cost }
                if x.depth != y.depth { return x.depth > y.depth }
                return x.directory < y.directory
            }) else { break }
            let pending = queue.remove(at: next)
            listings += 1
            for entry in await list(pending.directory) where !entry.isIgnored {
                let name = entry.name.lowercased()
                guard entry.isDirectory else {
                    if let rank = rank(name, depth: pending.depth) { found.append((rank, entry.path)) }
                    continue
                }
                guard pending.depth + 1 < maxDepth else { continue }
                let artwork = isArtwork(name)
                let step: Int
                if artwork {
                    step = artworkCost
                } else if name.hasPrefix(".") || skippedFolders.contains(name) {
                    continue
                } else {
                    step = pending.inArtwork ? nestedCost : otherCost
                }
                queue.append(Pending(cost: pending.cost + step, depth: pending.depth + 1, directory: entry.path,
                                     inArtwork: artwork))
            }
        }
        return found.enumerated()
            .sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }
            .map(\.element.1)
    }

    static func isArtwork(_ name: String) -> Bool {
        artworkFolders.contains(name) || name.hasSuffix(".xcassets") || name.hasSuffix(".appiconset") || name.hasSuffix(".iconset")
    }

    static func rank(_ name: String, depth: Int) -> Rank? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let format: Int
        switch name[name.index(after: dot)...] {
        case "icns": format = 3
        case "png": format = 2
        case "ico": format = 1
        default: return nil
        }
        let stem = name[..<dot].filter { !"-_ ".contains($0) }
        let named = ["appicon", "icon", "logo", "favicon"].contains(stem)
        let mentions = stem.contains("icon") || stem.contains("logo")
        if !named && !mentions && format == 2 { return nil }
        let variant = ["beta", "dev", "nightly", "canary", "debug", "preview", "dark"].contains { stem.contains($0) }
        let nameRank: Int
        switch (named, mentions, variant) {
        case (true, _, _): nameRank = 3
        case (false, true, false): nameRank = 2
        case (false, false, false): nameRank = 1
        case (false, _, true): nameRank = 0
        }
        return Rank(name: nameRank, format: format, depth: depth)
    }
}
