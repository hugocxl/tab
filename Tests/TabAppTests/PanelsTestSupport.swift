import AppKit
import TabCore
import TabProtocol
@testable import TabApp

/// Stands in for a server's side connection: answers from closures and
/// records what was asked.
final class StubTransport: NativeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _files: [FilesAction] = []
    private var _git: [GitAction] = []
    var filesHandler: @Sendable (FilesAction) throws -> FilesReply = { _ in .done }
    var gitHandler: @Sendable (GitAction) throws -> GitReply = { _ in .done }

    var filesRequests: [FilesAction] { lock.withLock { _files } }
    var gitRequests: [GitAction] { lock.withLock { _git } }

    func files(_ request: FilesRequest) async throws -> FilesReply {
        lock.withLock { _files.append(request.action) }
        return try filesHandler(request.action)
    }

    func git(_ request: GitRequest) async throws -> GitReply {
        lock.withLock { _git.append(request.action) }
        return try gitHandler(request.action)
    }
}

/// A host for every native panel and pane, recording what they asked of the app.
@MainActor
final class StubNativeHost: FilesPanelHost, SourceControlHost, EditorHost, DiffHost {
    var nativeProject = NativeProject(id: ProjectId(), name: "demo", path: "/tmp/demo", serverId: ServerId(), isLocal: true)
    var transport: StubTransport? = StubTransport()
    var nativeTransport: NativeTransport? { transport }
    let theme = AppTheme(systemIsDark: true)
    var codeFont: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    var canGenerateCommitMessage = false
    var toasts: [String] = []
    var confirmAnswer = true
    var opened: [String] = []
    var diffs: [(String, Bool)] = []
    var titles: [String] = []
    var repositoryChanges = 0
    var watches = 0

    func showToast(_ message: String, style: Toast.Style) { toasts.append(message) }
    func confirm(title: String, message: String, confirmTitle: String, destructive: Bool, completion: @escaping (Bool) -> Void) {
        completion(confirmAnswer)
    }
    func openEditor(path: String, line: Int?, column: Int?) { opened.append(path) }
    func watchProjectFiles() { watches += 1 }
    func closeFilesPanel() {}
    func openDiff(path: String, staged: Bool) { diffs.append((path, staged)) }
    func repositoryDidChange() { repositoryChanges += 1 }
    func generateCommitMessage() async throws -> String { "Generated" }
    func closeSourceControl() {}
    func editorTitleDidChange(_ title: String, dirty: Bool) { titles.append(title) }
}

func fileEntry(_ path: String, directory: Bool = false, ignored: Bool = false) -> FileEntry {
    FileEntry(name: ServerPath(NativePath.basename(path)), path: ServerPath(path), isDirectory: directory, isIgnored: ignored)
}

/// Waits for queued main-actor tasks until `condition` holds.
@MainActor
func settle(timeout: TimeInterval = 2, _ condition: @escaping @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
