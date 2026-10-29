import Foundation

/// A file operation inside a server project. Paths are relative to the
/// project folder; the empty path is the folder itself.
public struct FilesRequest: Hashable, Codable, Sendable {
    public var project: ProjectId
    public var action: FilesAction

    public init(project: ProjectId, action: FilesAction) {
        self.project = project
        self.action = action
    }
}

public enum FilesAction: Hashable, Codable, Sendable {
    case list(ServerPath)
    /// Reads a UTF-8 text file.
    case read(ServerPath)
    /// Reads any file, such as an image, as it is on disk.
    case readBytes(ServerPath)
    case write(path: ServerPath, content: String)
    case writeBytes(path: ServerPath, bytes: Data)
    case stat(ServerPath)
    case mkdir(ServerPath)
    /// Renames within the same folder; `name` is one path component.
    case rename(path: ServerPath, name: ServerPath)
    case move(paths: [ServerPath], into: ServerPath)
    case delete([ServerPath])
    /// Replaces this connection's file watch with the project's folder.
    case watch
    case unwatch
    /// Every file in the project (`rg --files`, else `git ls-files`), for Go to File.
    case searchFiles(limit: UInt32)
    /// Find in Files with `rg`.
    case searchContent(ContentSearchQuery)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "list": self = .list(try c("path"))
        case "read": self = .read(try c("path"))
        case "readBytes": self = .readBytes(try c("path"))
        case "write": self = .write(path: try c("path"), content: try c("content"))
        case "writeBytes": self = .writeBytes(path: try c("path"), bytes: try c("bytes"))
        case "stat": self = .stat(try c("path"))
        case "mkdir": self = .mkdir(try c("path"))
        case "rename": self = .rename(path: try c("path"), name: try c("name"))
        case "move": self = .move(paths: try c("paths"), into: try c("into"))
        case "delete": self = .delete(try c("paths"))
        case "watch": self = .watch
        case "unwatch": self = .unwatch
        case "searchFiles": self = .searchFiles(limit: try c("limit"))
        case "searchContent": self = .searchContent(try c("query"))
        default: throw unknownCase(c.type, decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .list(let path):
            var c = try TaggedEncoding(encoder, "list")
            try c(path, "path")
        case .read(let path):
            var c = try TaggedEncoding(encoder, "read")
            try c(path, "path")
        case .readBytes(let path):
            var c = try TaggedEncoding(encoder, "readBytes")
            try c(path, "path")
        case .write(let path, let content):
            var c = try TaggedEncoding(encoder, "write")
            try c(path, "path")
            try c(content, "content")
        case .writeBytes(let path, let bytes):
            var c = try TaggedEncoding(encoder, "writeBytes")
            try c(path, "path")
            try c(bytes, "bytes")
        case .stat(let path):
            var c = try TaggedEncoding(encoder, "stat")
            try c(path, "path")
        case .mkdir(let path):
            var c = try TaggedEncoding(encoder, "mkdir")
            try c(path, "path")
        case .rename(let path, let name):
            var c = try TaggedEncoding(encoder, "rename")
            try c(path, "path")
            try c(name, "name")
        case .move(let paths, let into):
            var c = try TaggedEncoding(encoder, "move")
            try c(paths, "paths")
            try c(into, "into")
        case .delete(let paths):
            var c = try TaggedEncoding(encoder, "delete")
            try c(paths, "paths")
        case .watch: try TaggedEncoding(encoder, "watch")
        case .unwatch: try TaggedEncoding(encoder, "unwatch")
        case .searchFiles(let limit):
            var c = try TaggedEncoding(encoder, "searchFiles")
            try c(limit, "limit")
        case .searchContent(let query):
            var c = try TaggedEncoding(encoder, "searchContent")
            try c(query, "query")
        }
    }
}

public struct FileEntry: Hashable, Codable, Sendable {
    public var name: ServerPath
    public var path: ServerPath
    public var isDirectory: Bool
    /// Ignored by Git.
    public var isIgnored: Bool

    public init(name: ServerPath, path: ServerPath, isDirectory: Bool, isIgnored: Bool = false) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isIgnored = isIgnored
    }
}

public struct FileInfo: Hashable, Codable, Sendable {
    public var name: ServerPath
    public var path: ServerPath
    public var isDirectory: Bool
    public var size: UInt64

    public init(name: ServerPath, path: ServerPath, isDirectory: Bool, size: UInt64) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
    }
}

public struct FileContent: Hashable, Codable, Sendable {
    public var path: ServerPath
    public var content: String
    /// Bytes on disk.
    public var size: UInt64

    public init(path: ServerPath, content: String, size: UInt64) {
        self.path = path
        self.content = content
        self.size = size
    }
}

public struct FileBytes: Hashable, Codable, Sendable {
    public var path: ServerPath
    public var bytes: Data

    public init(path: ServerPath, bytes: Data) {
        self.path = path
        self.bytes = bytes
    }
}

public struct ContentSearchQuery: Hashable, Codable, Sendable {
    public var query: String
    public var caseSensitive: Bool
    /// The query is a regular expression rather than literal text.
    public var regex: Bool
    /// Matches kept per file.
    public var maxMatchesPerFile: UInt32

    public init(query: String, caseSensitive: Bool = false, regex: Bool = false,
                maxMatchesPerFile: UInt32 = UInt32(Limits.maxMatchesPerFile)) {
        self.query = query
        self.caseSensitive = caseSensitive
        self.regex = regex
        self.maxMatchesPerFile = maxMatchesPerFile
    }
}

/// The project's files, relative to its folder.
public struct FileList: Hashable, Codable, Sendable {
    public var paths: [String]
    /// More files exist than the limit allowed.
    public var truncated: Bool

    public init(paths: [String], truncated: Bool = false) {
        self.paths = paths
        self.truncated = truncated
    }
}

public struct ContentMatch: Hashable, Codable, Sendable {
    /// One-based line.
    public var line: UInt32
    /// One-based character column of the match start.
    public var column: UInt32
    /// The matching line.
    public var preview: String
    /// Character ranges of the matches within `preview`, end exclusive.
    public var ranges: [MatchRange]

    public init(line: UInt32, column: UInt32, preview: String, ranges: [MatchRange] = []) {
        self.line = line
        self.column = column
        self.preview = preview
        self.ranges = ranges
    }
}

public struct MatchRange: Hashable, Codable, Sendable {
    public var start: UInt32
    public var end: UInt32

    public init(start: UInt32, end: UInt32) {
        self.start = start
        self.end = end
    }
}

public struct FileMatches: Hashable, Codable, Sendable {
    public var path: String
    public var matches: [ContentMatch]

    public init(path: String, matches: [ContentMatch]) {
        self.path = path
        self.matches = matches
    }
}

public struct ContentSearchResult: Hashable, Codable, Sendable {
    public var files: [FileMatches]
    /// Some matches were left out to stay within limits.
    public var truncated: Bool

    public init(files: [FileMatches], truncated: Bool = false) {
        self.files = files
        self.truncated = truncated
    }
}

public enum FilesReply: Hashable, Codable, Sendable {
    case entries([FileEntry])
    case content(FileContent)
    case bytes(FileBytes)
    case info(FileInfo)
    case path(ServerPath)
    case paths([ServerPath])
    case done
    case fileList(FileList)
    case searchResults(ContentSearchResult)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "entries": self = .entries(try c("entries"))
        case "content": self = .content(try c("file"))
        case "bytes": self = .bytes(try c("file"))
        case "info": self = .info(try c("info"))
        case "path": self = .path(try c("path"))
        case "paths": self = .paths(try c("paths"))
        case "done": self = .done
        case "fileList": self = .fileList(try c("list"))
        case "searchResults": self = .searchResults(try c("results"))
        default: throw unknownCase(c.type, decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .entries(let entries):
            var c = try TaggedEncoding(encoder, "entries")
            try c(entries, "entries")
        case .content(let file):
            var c = try TaggedEncoding(encoder, "content")
            try c(file, "file")
        case .bytes(let file):
            var c = try TaggedEncoding(encoder, "bytes")
            try c(file, "file")
        case .info(let info):
            var c = try TaggedEncoding(encoder, "info")
            try c(info, "info")
        case .path(let path):
            var c = try TaggedEncoding(encoder, "path")
            try c(path, "path")
        case .paths(let paths):
            var c = try TaggedEncoding(encoder, "paths")
            try c(paths, "paths")
        case .done: try TaggedEncoding(encoder, "done")
        case .fileList(let list):
            var c = try TaggedEncoding(encoder, "fileList")
            try c(list, "list")
        case .searchResults(let results):
            var c = try TaggedEncoding(encoder, "searchResults")
            try c(results, "results")
        }
    }
}

/// Paths that changed in a watched project, relative to its folder.
public struct FileChanges: Hashable, Codable, Sendable {
    public var paths: [ServerPath]
    /// Too much changed to list; read everything again.
    public var rescan: Bool

    public init(paths: [ServerPath] = [], rescan: Bool = false) {
        self.paths = paths
        self.rescan = rescan
    }

    /// Adds `other`, turning into a rescan past `Limits.maxFileChanges` paths.
    public mutating func merge(_ other: FileChanges) {
        if rescan || other.rescan {
            rescan = true
            paths.removeAll()
            return
        }
        for path in other.paths where !paths.contains(path) {
            paths.append(path)
            if paths.count > Limits.maxFileChanges {
                rescan = true
                paths.removeAll()
                return
            }
        }
    }
}
