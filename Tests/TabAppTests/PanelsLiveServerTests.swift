import AppKit
import TabClient
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

/// A project's native host backed by a real `tabd` side connection.
@MainActor
final class LiveNativeHost: FilesPanelHost, SourceControlHost, EditorHost, DiffHost {
    let nativeProject: NativeProject
    let transport: ServerAPITransport
    var nativeTransport: NativeTransport? { transport }
    let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: true)
    var codeFont: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
    var toasts: [String] = []
    var opened: [String] = []
    var repositoryChanges = 0

    init(project: NativeProject, client: ServerClient) {
        nativeProject = project
        transport = ServerAPITransport(client)
    }

    func showToast(_ message: String, style: Toast.Style) { toasts.append(message) }
    func confirm(title: String, message: String, confirmTitle: String, destructive: Bool, completion: @escaping (Bool) -> Void) {
        completion(true)
    }
    func openEditor(path: String, line: Int?, column: Int?) { opened.append(path) }
    func watchProjectFiles() {
        let request = FilesRequest(project: nativeProject.id, action: .watch)
        Task { _ = try? await transport.files(request) }
    }
    func closeFilesPanel() {}
    func openDiff(path: String, staged: Bool) {}
    func repositoryDidChange() { repositoryChanges += 1 }
    func closeSourceControl() {}
    func editorTitleDidChange(_ title: String, dirty: Bool) {}
}

/// Starts a real `tabd` in a short temporary `TAB_DIR` with one project for a
/// fresh Git repository. Skips when `tabd` isn't built.
@MainActor
class LiveServerTestCase: XCTestCase {
    var root: URL!
    var repo: URL!
    var client: ServerClient!
    var host: LiveNativeHost!
    private var eventTask: Task<Void, Never>?
    private var windows: [NSWindow] = []
    var onFilesChanged: ((FileChanges) -> Void)?
    var onGitChanged: (() -> Void)?

    override func setUp() async throws {
        let root = URL(fileURLWithPath: "/tmp/tabp-\(UUID().uuidString.prefix(6))", isDirectory: true)
        self.root = root
        repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "qa@example.com")
        try git("config", "user.name", "QA")
        try write("README.md", "# Demo\n")
        try write("Sources/App.swift", "import Foundation\n\nlet answer = 42\n")
        try git("add", ".")
        try git("commit", "-q", "-m", "Initial")

        let server = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(Executable.server)
        guard Executable.isExecutableFile(server) else { throw XCTSkip("tabd isn't built at \(server.path)") }
        var local = LocalServer(dirs: TabDirs(root: root.appendingPathComponent("p")), executable: server)
        local.startTimeout = 10
        client = try await local.connect(kind: .desktop)
        let descriptor = ProjectDescriptor.new(directory: ServerPath(repo.path))
        _ = try await client.mutateProject(ProjectIntent(mutation: .create(descriptor)))
        let catalog = try await client.catalog()
        let project = try XCTUnwrap(catalog.projects.first { $0.directory.rawValue == repo.path })
        host = LiveNativeHost(
            project: NativeProject(id: project.id, name: project.name, path: repo.path, serverId: catalog.server, isLocal: true),
            client: client
        )
        let events = client.events
        eventTask = Task { [weak self] in
            for await event in events {
                switch event {
                case .filesChanged(_, let changes): self?.onFilesChanged?(changes)
                case .gitChanged: self?.onGitChanged?()
                default: break
                }
            }
        }
    }

    /// Safe after a failed or skipped `setUp`: stops a server that started
    /// without a connection through its pid file.
    override func tearDown() async throws {
        eventTask?.cancel()
        windows.forEach { $0.close() }
        windows.removeAll()
        guard let root: URL = root else { return }
        if let client: ServerClient = client {
            _ = try? await client.stopServer(force: true)
            client.close()
        } else {
            let pidFile = TabDirs(root: root.appendingPathComponent("p")).serverPid
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ path: String, _ text: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(path).path)
    }

    @discardableResult
    func git(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Hosts a controller's view in an offscreen window, kept until
    /// `tearDown`, so it lays out, appears and stays shown.
    @discardableResult
    func show(_ controller: NSViewController, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.appearance = host.theme.nsAppearance
        controller.view.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }
}

/// The Files panel, Source Control, diff and editor against a real server.
@MainActor
final class PanelsLiveServerTests: LiveServerTestCase {
    func testFilesPanelCreatesRenamesDeletesAndFollowsTheDisk() async throws {
        let panel = FilesPanelController(host: host)
        show(panel, size: NSSize(width: 300, height: 600))
        host.watchProjectFiles()
        onFilesChanged = { [weak panel] in panel?.filesChanged($0) }
        panel.ensureRoot()
        await settle { panel.tree.isLoaded("") }
        XCTAssertEqual(panel.tree.visible().map(\.node.path), ["Sources", "README.md"], "folders first, .git hidden")

        panel.beginNewItem(folder: false)
        try XCTUnwrap(panel.newItemField).onSubmit?("notes.txt")
        await settle { panel.tree.node("notes.txt") != nil }
        XCTAssertTrue(exists("notes.txt"))
        XCTAssertEqual(host.opened, ["notes.txt"], "a new file opens in an editor")

        panel.beginRename("notes.txt")
        try XCTUnwrap(panel.renameField).onSubmit?("todo.txt")
        await settle { panel.tree.node("todo.txt") != nil }
        XCTAssertTrue(exists("todo.txt") && !exists("notes.txt"))
        XCTAssertNil(panel.tree.node("notes.txt"))

        panel.confirmDelete("todo.txt")
        await settle { panel.tree.node("todo.txt") == nil }
        XCTAssertFalse(exists("todo.txt"))

        try write("outside.txt", "made in a shell\n")
        await settle(timeout: 5) { panel.tree.node("outside.txt") != nil }
        XCTAssertNotNil(panel.tree.node("outside.txt"), "the tree follows files made outside Tab")
    }

    func testSourceControlStagesUnstagesDiscardsCommitsAndAmends() async throws {
        try write("README.md", "# Demo\nchanged\n")
        try write("new.txt", "new\n")
        let panel = SourceControlController(host: host)
        show(panel, size: NSSize(width: 300, height: 600))
        panel.refresh()
        await settle { panel.model.status != nil }
        XCTAssertEqual(panel.model.paths(in: .changes), ["README.md"])
        XCTAssertEqual(panel.model.paths(in: .untracked), ["new.txt"])

        panel.stage(["README.md", "new.txt"])
        await settle { panel.model.paths(in: .staged).count == 2 && !panel.isBusy }
        XCTAssertEqual(Set(panel.model.paths(in: .staged)), ["README.md", "new.txt"])

        panel.unstage(["new.txt"])
        await settle { panel.model.paths(in: .untracked) == ["new.txt"] && !panel.isBusy }

        panel.discard(["new.txt"])
        await settle { panel.model.paths(in: .untracked).isEmpty && !panel.isBusy }
        XCTAssertFalse(exists("new.txt"), "discarding an untracked file removes it")

        panel.messageField.string = "Change the readme"
        panel.commit()
        await settle { panel.messageField.string.isEmpty && !panel.isBusy && panel.model.paths(in: .staged).isEmpty }
        XCTAssertTrue(try git("log", "-1", "--format=%s").hasPrefix("Change the readme"))

        try write("README.md", "# Demo\nchanged again\n")
        await settle { true }
        panel.refresh()
        await settle { panel.model.paths(in: .changes) == ["README.md"] }
        panel.stage(["README.md"])
        await settle { panel.model.paths(in: .staged) == ["README.md"] && !panel.isBusy }
        panel.setAmend(true)
        panel.messageField.string = "Change the readme twice"
        panel.commit()
        await settle { panel.messageField.string.isEmpty && !panel.isBusy }
        XCTAssertEqual(try git("rev-list", "--count", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines), "2", "amend replaces the last commit")
        XCTAssertTrue(try git("log", "-1", "--format=%s").hasPrefix("Change the readme twice"))
        XCTAssertGreaterThanOrEqual(host.repositoryChanges, 5)
        XCTAssertTrue(host.toasts.isEmpty, "\(host.toasts)")
    }

    func testSourceControlRefreshesWhenTheWorkingTreeChanges() async throws {
        let panel = SourceControlController(host: host)
        show(panel, size: NSSize(width: 300, height: 600))
        onGitChanged = { [weak panel] in panel?.gitChanged() }
        _ = try await client.git(GitRequest(project: host.nativeProject.id, action: .watch))
        panel.refresh()
        await settle { panel.model.status != nil }
        XCTAssertTrue(panel.model.rows.isEmpty)
        try write("changed.txt", "x\n")
        await settle(timeout: 6) { panel.model.paths(in: .untracked) == ["changed.txt"] }
        XCTAssertEqual(panel.model.paths(in: .untracked), ["changed.txt"], "the panel follows a change made in a shell")
    }

    func testDiffShowsWorkingTreeAndStagedChangesAndRefreshes() async throws {
        try write("Sources/App.swift", "import Foundation\n\nlet answer = 43\n")
        let diff = DiffPaneController(host: host, path: "Sources/App.swift", staged: false)
        show(diff, size: NSSize(width: 700, height: 400))
        diff.refresh()
        await settle { diff.document != nil }
        let document = try XCTUnwrap(diff.document)
        XCTAssertEqual(document.diff.additions, 1)
        XCTAssertEqual(document.diff.deletions, 1)

        try write("Sources/App.swift", "import Foundation\n\nlet answer = 44\nlet more = 1\n")
        diff.gitChanged()
        await settle { diff.document?.diff.additions == 2 }
        XCTAssertEqual(diff.document?.diff.additions, 2, "gitChanged reads the diff again")

        try git("add", "Sources/App.swift")
        let staged = DiffPaneController(host: host, path: "Sources/App.swift", staged: true)
        show(staged, size: NSSize(width: 700, height: 400))
        staged.refresh()
        await settle { staged.document != nil }
        XCTAssertEqual(staged.document?.diff.additions, 2)
    }

    func testEditorOpensSavesReloadsAndRefusesBinaries() async throws {
        let editor = EditorPaneController(host: host, path: "Sources/App.swift")
        show(editor, size: NSSize(width: 700, height: 400))
        editor.viewDidAppear()
        await settle { editor.text.contains("answer") }
        XCTAssertEqual(editor.text, "import Foundation\n\nlet answer = 42\n")
        editor.go(line: 3, column: 5)
        XCTAssertEqual(editor.textView.selectedRange().location, "import Foundation\n\n".utf16.count + 4)

        editor.textView.insertText("// edited\n", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.isDirty)
        XCTAssertTrue(editor.paneTitle.hasSuffix("•") || editor.paneTitle != EditorModel.title(path: "Sources/App.swift", dirty: false))
        var saved: Bool?
        editor.save { saved = $0 }
        await settle { saved != nil }
        XCTAssertEqual(saved, true)
        XCTAssertEqual(read("Sources/App.swift"), "// edited\nimport Foundation\n\nlet answer = 42\n")
        XCTAssertFalse(editor.isDirty)

        try write("Sources/App.swift", "let fromDisk = true\n")
        editor.filesChanged(FileChanges(paths: [ServerPath("Sources/App.swift")]))
        await settle { editor.text == "let fromDisk = true\n" }
        XCTAssertEqual(editor.text, "let fromDisk = true\n", "an unchanged editor takes the disk's text")

        editor.textView.insertText("mine ", replacementRange: NSRange(location: 0, length: 0))
        try write("Sources/App.swift", "let fromDisk = false\n")
        editor.filesChanged(FileChanges(paths: [ServerPath("Sources/App.swift")]))
        await settle { !editor.banner.isHidden }
        XCTAssertFalse(editor.banner.isHidden, "unsaved edits are kept and the disk's version offered")
        XCTAssertTrue(editor.text.hasPrefix("mine "))
        editor.resolveDiskChange(reload: true)
        XCTAssertEqual(editor.text, "let fromDisk = false\n")

        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0xFF, 0xFE]).write(to: repo.appendingPathComponent("logo.png"))
        let binary = EditorPaneController(host: host, path: "logo.png")
        show(binary, size: NSSize(width: 400, height: 300))
        binary.viewDidAppear()
        await settle { binary.messageText != nil }
        XCTAssertNotNil(binary.messageText, "binary files are refused")
        XCTAssertTrue(binary.text.isEmpty)
    }

    func testGoToFileAndFindInFilesThroughThePanelsTransport() async throws {
        try write("Sources/Other.swift", "let answer2 = 1\n")
        let files = try await host.transport.files(FilesRequest(project: host.nativeProject.id, action: .searchFiles(limit: 1000)))
        guard case .fileList(let list) = files else { return XCTFail("unexpected \(files)") }
        XCTAssertEqual(Set(list.paths), ["README.md", "Sources/App.swift", "Sources/Other.swift"])

        let content = try await host.transport.files(FilesRequest(project: host.nativeProject.id, action: .searchContent(ContentSearchQuery(query: "ANSWER"))))
        guard case .searchResults(let result) = content else { return XCTFail("unexpected \(content)") }
        XCTAssertEqual(Set(result.files.map(\.path)), ["Sources/App.swift", "Sources/Other.swift"])

        let sensitive = try await host.transport.files(FilesRequest(project: host.nativeProject.id, action: .searchContent(ContentSearchQuery(query: "ANSWER", caseSensitive: true))))
        guard case .searchResults(let none) = sensitive else { return XCTFail("unexpected \(sensitive)") }
        XCTAssertTrue(none.files.isEmpty)

        let regex = try await host.transport.files(FilesRequest(project: host.nativeProject.id, action: .searchContent(ContentSearchQuery(query: "answer\\d", regex: true))))
        guard case .searchResults(let one) = regex else { return XCTFail("unexpected \(regex)") }
        XCTAssertEqual(one.files.map(\.path), ["Sources/Other.swift"])
    }
}
