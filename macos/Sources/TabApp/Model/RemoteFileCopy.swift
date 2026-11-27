import AppKit
import TabCore
import TabProtocol

/// A remote link opens a private, read-only copy on this computer.
enum RemoteFileCopy {
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Tab Copies", isDirectory: true) }

    static func contains(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// A portable pane reference keeps the core's project-relative path invariant.
    static func reference(for path: String) -> String? {
        guard contains(path) else { return nil }
        let relative = String(URL(fileURLWithPath: path).standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
        let reference = ".tab-remote-copy/" + relative
        return url(for: reference) == nil ? nil : reference
    }

    static func url(for reference: String) -> URL? {
        let parts = reference.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == ".tab-remote-copy", UUID(uuidString: String(parts[1])) != nil,
              !parts[2].isEmpty, parts[2] != ".", parts[2] != ".." else { return nil }
        return folder.appendingPathComponent(String(parts[1]), isDirectory: true).appendingPathComponent(String(parts[2]))
    }

    /// The most specific project root, including the remote Home, owns a link.
    static func project(for path: String, server: ServerId, in projects: [Project]) -> Project? {
        projects.filter { $0.serverId == server && relative(path, to: $0.directory) != nil }
            .max { $0.directory.rawValue.count < $1.directory.rawValue.count }
    }

    static func relative(_ path: String, to directory: ServerPath) -> String? {
        guard path.hasPrefix("/"), directory.isAbsolute else { return nil }
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = URL(fileURLWithPath: directory.rawValue).standardizedFileURL.path
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    static func download(_ path: String, project: ProjectId, directory: ServerPath, serverName: String, through api: ServerAPI) async throws -> URL {
        guard let relative = relative(path, to: directory) else { throw ModelError("The file is outside this server's projects and Home.") }
        let reply = try await api.files(FilesRequest(project: project, action: .readBytes(ServerPath(relative))))
        guard case .bytes(let file) = reply else { throw ModelError("The server did not return the file.") }
        return try save(file.bytes, original: path, serverName: serverName)
    }

    static func save(_ bytes: Data, original: String, serverName: String) throws -> URL {
        let source = URL(fileURLWithPath: original)
        let suffix = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
        let stem = suffix.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        let name = serverName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "-")
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = directory.appendingPathComponent("\(stem) (copy from \(name))\(suffix)")
        try bytes.write(to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: copy.path)
        return copy
    }
}

/// Reads a downloaded copy locally and refuses every mutation, even if an
/// editor action tries to save it.
final class RemoteCopyTransport: NativeTransport, Sendable {
    let url: URL

    init(url: URL) { self.url = url }

    func git(_ request: GitRequest) async throws -> GitReply { throw ModelError("This is a read-only copy.") }

    func files(_ request: FilesRequest) async throws -> FilesReply {
        guard case .read = request.action else { throw ModelError("This is a read-only copy.") }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 5 * 1024 * 1024 else { throw ModelError("This file is larger than 5 MB.") }
        guard let text = String(data: bytes, encoding: .utf8) else { throw ModelError("The file is not UTF-8.") }
        return .content(FileContent(path: ServerPath(url.path), content: text, size: UInt64(bytes.count)))
    }
}

/// Hosts a temporary local copy in the remote project's editor without
/// routing its reads or saves back to that server.
@MainActor
final class RemoteCopyHost: EditorHost {
    private let projectHost: ProjectHost
    private let transport: RemoteCopyTransport

    init(model: AppModel, project: ProjectId, path: String) {
        projectHost = model.projectHost(project)
        transport = RemoteCopyTransport(url: URL(fileURLWithPath: path))
    }

    var nativeProject: NativeProject {
        var project = projectHost.nativeProject
        project.isLocal = true
        project.path = transport.url.deletingLastPathComponent().path
        return project
    }

    var nativeTransport: NativeTransport? { transport }
    var theme: AppTheme { projectHost.theme }
    var codeFont: NSFont { projectHost.codeFont }
    func editorTitleDidChange(_ title: String, dirty: Bool) { projectHost.editorTitleDidChange(title, dirty: dirty) }
    func watchProjectFiles() {}
    func showToast(_ message: String, style: Toast.Style) { projectHost.showToast(message, style: style) }
    func confirm(title: String, message: String, confirmTitle: String, destructive: Bool, completion: @escaping (Bool) -> Void) {
        projectHost.confirm(title: title, message: message, confirmTitle: confirmTitle, destructive: destructive, completion: completion)
    }
}
