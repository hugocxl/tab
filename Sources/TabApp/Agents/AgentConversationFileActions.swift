import AppKit
import CryptoKit
import ImageIO
import TabClient
import TabCore
import TabProtocol
import UniformTypeIdentifiers

/// Conversation file services. Reads stay on the owning project server and every
/// path is resolved inside the session's project folder before any request.
@MainActor
enum AgentConversationFileActions {
    struct Scope {
        var project: ProjectId
        var session: SessionId
        var directory: String
    }
    typealias Read = @MainActor (FilesRequest) async throws -> FilesReply
    static let maximumAssetBytes = min(64 * 1024 * 1024, Limits.maxFileBytes)

    struct Metadata: Equatable {
        var isDirectory: Bool
        var byteLength: UInt64
        var mimeType: String?
        /// Unknown when the project server predates modification times.
        var modified: Date? = nil
    }

    struct Entries: Equatable {
        var paths: [String]
        var truncated: Bool
    }

    /// A project file pinned to the revision observed when it was opened.
    struct Media {
        var path: String
        var sourcePath: String
        var mimeType: String
        var revision: String
        var resource: AgentConversationRangedResource
        var pixelSize: CGSize?
    }

    /// Writes `contents` to `relativePath` under `cwd` (the project root by default)
    /// and returns the path the server confirmed.
    static func writeProjectFile(_ relativePath: String, contents: String, cwd: String? = nil, scope: Scope,
                                 createParents: Bool = false, read: Read) async throws -> String {
        try Task.checkCancellation()
        let base = cwd ?? scope.directory
        guard try resolve(base, scope: scope) == "", !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              contents.utf8.count <= Limits.maxFileBytes else {
            throw ModelError("Invalid project plan save request.")
        }
        let resolved = try resolve(relativePath, scope: scope, baseDirectory: base)
        guard !resolved.isEmpty,
              case .path(let path) = try await read(.init(project: scope.project, action: .write(path: ServerPath(resolved), content: contents, createParents: createParents))),
              !(try resolve(path.rawValue, scope: scope)).isEmpty else {
            throw ModelError("The project server did not confirm the saved plan path.")
        }
        return path.rawValue
    }

    /// One entry per path, in order; nil for paths that do not exist.
    static func filesystemMetadata(_ paths: [String], scope: Scope, read: Read) async throws -> [Metadata?] {
        try Task.checkCancellation()
        guard !paths.isEmpty, paths.count <= 64 else { throw ModelError("Invalid filesystem metadata request.") }
        var entries: [Metadata?] = []
        for path in paths {
            let resolved = try resolve(path, scope: scope)
            do {
                guard case .info(let info) = try await read(FilesRequest(project: scope.project, action: .stat(ServerPath(resolved)))) else {
                    throw ModelError("The project server returned invalid file metadata.")
                }
                entries.append(Metadata(isDirectory: info.isDirectory, byteLength: info.size,
                                        mimeType: info.isDirectory ? nil : mimeType(path: resolved),
                                        modified: info.modifiedAt.map { Date(timeIntervalSince1970: $0) }))
            } catch ClientError.server(let reply) where reply.code == .badPath { entries.append(nil) }
        }
        return entries
    }

    /// Project files whose path contains `query`, case-insensitively.
    static func searchProjectEntries(_ query: String, limit: Int, scope: Scope, read: Read) async throws -> Entries {
        try Task.checkCancellation()
        guard query.utf16.count <= 256, (1...1_000).contains(limit) else { throw ModelError("Invalid project file search request.") }
        guard case .fileList(let list) = try await read(FilesRequest(project: scope.project, action: .searchFiles(limit: 50_000))) else {
            throw ModelError("The project server returned an invalid file list.")
        }
        let matches = list.paths.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        return Entries(paths: Array(matches.prefix(limit)), truncated: list.truncated || matches.count > limit)
    }

    /// An image, video, audio, HTML or PDF file of the project. `session`, when the
    /// request names one, must be this conversation. `ranged` streams large files.
    static func media(_ path: String, cwd: String? = nil, session: SessionId? = nil, scope: Scope,
                      ranged: Bool, read: @escaping Read) async throws -> Media {
        try Task.checkCancellation()
        if let session, session != scope.session { throw ModelError("This media request belongs to another conversation.") }
        let resolved = try resolve(path, scope: scope, baseDirectory: cwd)
        guard case .info(let info) = try await read(FilesRequest(project: scope.project, action: .stat(ServerPath(resolved)))), !info.isDirectory else {
            throw ModelError("This media file is unavailable.")
        }
        let mime = mimeType(path: resolved)
        guard mime.hasPrefix("image/") || mime.hasPrefix("audio/") || mime.hasPrefix("video/") || ["application/pdf", "text/html"].contains(mime) else {
            throw ModelError("Only images, video, audio, HTML, and PDF files can be previewed.")
        }
        let loaded = try await resource(resolved, size: info.size, mimeType: mime, scope: scope, ranged: ranged, read: read)
        var pixelSize: CGSize?
        if mime.hasPrefix("image/"), let source = CGImageSourceCreateWithData(loaded.header as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = CGSize(width: width, height: height)
        }
        return Media(path: resolved, sourcePath: (scope.directory as NSString).appendingPathComponent(resolved), mimeType: mime,
                     revision: loaded.resource.revision, resource: loaded.resource, pixelSize: pixelSize)
    }

    /// A revision-pinned resource for `relative`. Ranged reads fetch only the first
    /// chunk now; otherwise the whole file is read, within the server's read limit.
    static func resource(_ relative: String, size: UInt64, mimeType: String, scope: Scope, ranged: Bool,
                         read: @escaping Read) async throws -> (resource: AgentConversationRangedResource, header: Data) {
        let path = ServerPath(relative), project = scope.project
        if ranged {
            guard case .byteRange(let first) = try await read(FilesRequest(project: project, action: .readRange(path: path, offset: 0, length: UInt32(FileByteRange.maximumChunkBytes), expectedRevision: nil))),
                  first.offset == 0, first.bytes.count <= FileByteRange.maximumChunkBytes else {
                throw ModelError("The project server returned invalid media metadata.")
            }
            try Task.checkCancellation()
            let total = first.totalSize, revision = first.revision
            let resource = AgentConversationRangedResource(length: total, mimeType: mimeType, revision: revision, read: { offset, length in
                guard case .byteRange(let chunk) = try await read(FilesRequest(project: project, action: .readRange(path: path, offset: offset, length: length, expectedRevision: revision))),
                      chunk.offset == offset, chunk.totalSize == total, chunk.revision == revision,
                      chunk.bytes.count == Int(min(UInt64(length), total - min(offset, total))) else {
                    throw ModelError("This media file changed; refresh its preview.")
                }
                return chunk.bytes
            })
            return (resource, first.bytes)
        }
        guard size <= UInt64(maximumAssetBytes) else { throw ModelError("This media file exceeds the project server’s \(maximumAssetBytes / 1024 / 1024) MiB file read limit.") }
        guard case .bytes(let file) = try await read(FilesRequest(project: project, action: .readBytes(path))), file.bytes.count <= maximumAssetBytes else {
            throw ModelError("The project server returned invalid media bytes.")
        }
        try Task.checkCancellation()
        let revision = SHA256.hash(data: file.bytes).map { String(format: "%02x", $0) }.joined()
        return (AgentConversationRangedResource(data: file.bytes, mimeType: mimeType, revision: revision), file.bytes)
    }

    static func resolve(_ path: String, scope: Scope, baseDirectory: String? = nil) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.contains("\0"),
              !path.contains("://"), !path.hasPrefix("~") else { throw ModelError("Invalid project file path.") }
        let root = (scope.directory as NSString).standardizingPath
        let base = baseDirectory ?? root
        let resolved = ((path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)) as NSString).standardizingPath
        if resolved == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        guard resolved.hasPrefix(prefix) else { throw ModelError("This file is outside the owning project folder.") }
        return String(resolved.dropFirst(prefix.count))
    }

    static func mimeType(path: String) -> String {
        let suffix = (path as NSString).pathExtension.lowercased()
        return UTType(filenameExtension: suffix)?.preferredMIMEType ?? "application/octet-stream"
    }
}
