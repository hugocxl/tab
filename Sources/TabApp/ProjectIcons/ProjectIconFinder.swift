import AppKit
import Foundation
import TabClient
import TabProtocol

/// One entry of a project folder listing, relative to the project root.
public struct ProjectIconEntry: Equatable, Sendable {
    public var name: String
    /// Relative to the project root; the root itself is "".
    public var path: String
    public var isDirectory: Bool
    /// Ignored by Git.
    public var isIgnored: Bool

    public init(name: String, path: String, isDirectory: Bool, isIgnored: Bool = false) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isIgnored = isIgnored
    }
}

/// Finds an icon among a project's files, such as an app's `.icns`, a
/// `favicon.ico`, or a `logo.png`, listing artwork folders first so a large
/// project costs a handful of listings. Git-ignored folders are skipped.
public enum ProjectIconFinder {
    /// Directories that commonly hold a project's artwork, searched first.
    static let artworkFolders: Set<String> = [
        ".github", "app", "art", "artwork", "assets", "brand", "branding", "build", "design", "docs",
        "icon", "icons", "images", "img", "logo", "logos", "mac", "macos", "media", "packaging",
        "public", "res", "resources", "src-tauri", "static", "windows",
    ]
    /// Directories that never hold a project's own icon.
    static let skippedFolders: Set<String> = [
        "__tests__", "coverage", "dist", "e2e", "fixtures", "node_modules", "out", "target", "test", "tests", "vendor",
    ]
    /// Search cost of entering a directory. Artwork folders are free, so a
    /// search that finds one finishes it first; folders within them rarely
    /// hold the icon.
    static let artworkCost = 0
    static let otherCost = 3
    static let nestedCost = 6
    static let maxDepth = 6
    static let maxListings = 48
    /// Candidates read before giving up, in case the best ones don't decode.
    static let maxReads = 3

    struct Rank: Comparable {
        var name: Int
        var format: Int
        var depth: Int

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            (lhs.name, lhs.format, -lhs.depth) < (rhs.name, rhs.format, -rhs.depth)
        }
    }

    /// The project's icon from `list` (a folder's entries, relative to the
    /// root) and `read` (a file's bytes), or `nil` when it has no readable one.
    public static func find(list: (String) async -> [ProjectIconEntry], read: (String) async -> Data?) async -> NSImage? {
        for path in await candidates(list: list).prefix(maxReads) {
            if let data = await read(path), let image = decode(data) { return image }
        }
        return nil
    }

    /// The icon of a folder on this computer. Run it off the main thread.
    public static func findLocal(root: URL) async -> NSImage? {
        let lister = LocalProjectLister(root: root)
        return await find(list: { lister.list($0) }, read: { try? Data(contentsOf: root.appendingPathComponent($0)) })
    }

    /// The icon of `project` on a server, listed and read through `client`.
    public static func findRemote(client: ServerClient, project: ProjectId) async -> NSImage? {
        await find(
            list: { directory in
                let reply = try? await client.files(FilesRequest(project: project, action: .list(ServerPath(directory))))
                guard case .entries(let entries)? = reply else { return [] }
                return entries.map {
                    ProjectIconEntry(name: $0.name.rawValue, path: $0.path.rawValue, isDirectory: $0.isDirectory, isIgnored: $0.isIgnored)
                }
            },
            read: { path in
                let reply = try? await client.files(FilesRequest(project: project, action: .readBytes(ServerPath(path))))
                guard case .bytes(let file)? = reply else { return nil }
                return file.bytes
            }
        )
    }

    /// Icon files from the project root, best first. Directories are listed
    /// cheapest first, deepest first among equals, so artwork folders nested
    /// in a monorepo's packages are reached without listing every source
    /// folder.
    static func candidates(list: (String) async -> [ProjectIconEntry]) async -> [String] {
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
                queue.append(Pending(cost: pending.cost + step, depth: pending.depth + 1, directory: entry.path, inArtwork: artwork))
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
        // Any .icns or .ico is an icon; a .png only when it says so.
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

    /// An image from PNG, ICO or ICNS bytes, or `nil` when they don't decode.
    static func decode(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.isValid,
              image.representations.contains(where: { $0.pixelsWide > 0 && $0.pixelsHigh > 0 })
        else { return nil }
        return image
    }
}

/// Lists a local project's folders, marking what Git ignores with
/// `git check-ignore`.
struct LocalProjectLister {
    let root: URL

    func list(_ directory: String) -> [ProjectIconEntry] {
        let folder = directory.isEmpty ? root : root.appendingPathComponent(directory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var entries = names.sorted().map { name -> ProjectIconEntry in
            let path = directory.isEmpty ? name : "\(directory)/\(name)"
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return ProjectIconEntry(name: name, path: path, isDirectory: isDirectory.boolValue)
        }
        let ignored = ignoredPaths(entries.map { $0.isDirectory ? $0.path + "/" : $0.path })
        for index in entries.indices {
            let entry = entries[index]
            entries[index].isIgnored = ignored.contains(entry.path) || ignored.contains(entry.path + "/")
        }
        return entries
    }

    /// The paths Git ignores among `paths`; none outside a repository.
    func ignoredPaths(_ paths: [String]) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path, "--no-literal-pathspecs", "check-ignore", "-z", "--stdin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let request = Data(paths.joined(separator: "\0").utf8) + Data([0])
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            writer.write(request)
            try? writer.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Set(data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    }
}
