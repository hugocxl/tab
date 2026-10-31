import AppKit
import CryptoKit
import ImageIO
import TabClient
import TabCore
import TabProtocol
import UniformTypeIdentifiers

/// File reads stay on the owning project server; WebKit receives only scoped,
/// bounded asset URLs, never filesystem authority or embedded base64 payloads.
@MainActor
enum AgentConversationFileActions {
    struct Scope {
        var project: ProjectId
        var session: SessionId
        var directory: String
    }
    typealias Read = (FilesRequest) async throws -> FilesReply
    typealias Register = (Data, String, String) throws -> URL
    typealias RegisterRange = (FileByteRange, String, String) throws -> URL
    static let maximumAssetBytes = min(64 * 1024 * 1024, Limits.maxFileBytes)

    static func perform(_ kind: String, payload: [String: Any], scope: Scope,
                        read: Read, register: Register, registerRange: RegisterRange? = nil, createWriteParents: Bool = false) async throws -> Any {
        try Task.checkCancellation()
        if let environment = payload["environmentId"] as? String, environment != scope.project.description {
            throw ModelError("This file request belongs to another project.")
        }
        let input = payload["input"] as? [String: Any] ?? payload
        switch kind {
        case "writeProjectFile":
            guard payload["environmentId"] as? String == scope.project.description,
                  let cwd = input["cwd"] as? String, try resolve(cwd, scope: scope) == "",
                  let relative = input["relativePath"] as? String, !relative.isEmpty, !relative.hasPrefix("/"),
                  let contents = input["contents"] as? String, contents.utf8.count <= Limits.maxFileBytes else {
                throw ModelError("Invalid project plan save request.")
            }
            let resolved = try resolve(relative, scope: scope, baseDirectory: cwd)
            guard !resolved.isEmpty,
                  case .path(let path) = try await read(.init(project: scope.project, action: .write(path: ServerPath(resolved), content: contents, createParents: createWriteParents))),
                  !(try resolve(path.rawValue, scope: scope)).isEmpty else {
                throw ModelError("The project server did not confirm the saved plan path.")
            }
            return ["relativePath": path.rawValue]
        case "filesystemMetadata":
            guard let paths = input["paths"] as? [String], !paths.isEmpty, paths.count <= 64 else {
                throw ModelError("Invalid filesystem metadata request.")
            }
            var entries: [Any] = []
            for path in paths {
                let resolved = try resolve(path, scope: scope)
                do {
                    guard case .info(let info) = try await read(FilesRequest(project: scope.project, action: .stat(ServerPath(resolved)))) else {
                        throw ModelError("The project server returned invalid file metadata.")
                    }
                    var entry: [String: Any] = ["kind": info.isDirectory ? "directory" : "file", "byteLength": info.size]
                    if !info.isDirectory { entry["mimeType"] = mimeType(path: resolved) }
                    entries.append(entry)
                } catch ClientError.server(let reply) where reply.code == .badPath { entries.append(NSNull()) }
                catch { throw error }
            }
            return ["entries": entries]
        case "searchProjectEntries":
            guard let query = input["query"] as? String, query.utf16.count <= 256,
                  let limit = input["limit"] as? Int, (1...1_000).contains(limit),
                  input["kind"] == nil || input["kind"] as? String == "file" else {
                throw ModelError("Invalid project file search request.")
            }
            guard case .fileList(let list) = try await read(FilesRequest(project: scope.project, action: .searchFiles(limit: 50_000))) else {
                throw ModelError("The project server returned an invalid file list.")
            }
            let matches = list.paths.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            return ["entries": matches.prefix(limit).map { ["path": $0, "kind": "file"] },
                    "truncated": list.truncated || matches.count > limit]
        case "createAssetUrl":
            guard let resource = input["resource"] as? [String: Any],
                  let tag = resource["_tag"] as? String,
                  ["workspace-file", "media-file", "draft-workspace-file"].contains(tag),
                  let path = resource["path"] as? String else {
                throw ModelError("This conversation media resource is unavailable.")
            }
            if let thread = resource["threadId"] as? String, thread != scope.session.description {
                throw ModelError("This media request belongs to another conversation.")
            }
            let resolved = try resolve(path, scope: scope, baseDirectory: resource["cwd"] as? String)
            guard case .info(let info) = try await read(FilesRequest(project: scope.project, action: .stat(ServerPath(resolved)))), !info.isDirectory else {
                throw ModelError("This media file is unavailable.")
            }
            let mime = mimeType(path: resolved)
            guard mime.hasPrefix("image/") || mime.hasPrefix("audio/") || mime.hasPrefix("video/") || ["application/pdf", "text/html"].contains(mime) else {
                throw ModelError("Only images, video, audio, HTML, and PDF files can be previewed.")
            }
            let url: URL, revision: String, header: Data
            if let registerRange {
                guard case .byteRange(let first) = try await read(FilesRequest(project: scope.project, action: .readRange(path: ServerPath(resolved), offset: 0, length: UInt32(FileByteRange.maximumChunkBytes), expectedRevision: nil))),
                      first.offset == 0, first.bytes.count <= FileByteRange.maximumChunkBytes else {
                    throw ModelError("The project server returned invalid media metadata.")
                }
                try Task.checkCancellation()
                url = try registerRange(first, mime, resolved)
                revision = first.revision; header = first.bytes
            } else {
                guard info.size <= UInt64(Self.maximumAssetBytes) else { throw ModelError("This media file exceeds the project server’s \(Self.maximumAssetBytes / 1024 / 1024) MiB file read limit.") }
                guard case .bytes(let file) = try await read(FilesRequest(project: scope.project, action: .readBytes(ServerPath(resolved)))), file.bytes.count <= Self.maximumAssetBytes else {
                    throw ModelError("The project server returned invalid media bytes.")
                }
                try Task.checkCancellation()
                url = try register(file.bytes, mime, resolved)
                revision = SHA256.hash(data: file.bytes).map { String(format: "%02x", $0) }.joined()
                header = file.bytes
            }
            var result: [String: Any] = ["relativeUrl": url.absoluteString, "expiresAt": Date().addingTimeInterval(600).timeIntervalSince1970 * 1_000,
                                         "sourcePath": (scope.directory as NSString).appendingPathComponent(resolved), "fileRevision": revision]
            if mime.hasPrefix("image/"), let source = CGImageSourceCreateWithData(header as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
                result["imageDimensions"] = ["width": width, "height": height]
            }
            return result
        default:
            throw ModelError("Unsupported conversation file action: " + kind)
        }
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
