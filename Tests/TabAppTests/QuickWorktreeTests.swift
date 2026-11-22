import XCTest
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class QuickWorktreeTests: XCTestCase {
    func testLastPaneAsksBeforeClosingWorktreeAndCancelKeepsItOpen() async throws {
        let parent = ProjectDescriptor(directory: ServerPath(try ModelFixtures.folder("parent")), name: "parent")
        let worktree = ProjectDescriptor(directory: ServerPath(try ModelFixtures.folder("feature")),
                                         name: "feature", kind: .worktree, parentId: parent.id)
        try Data("gitdir: ../parent/.git/worktrees/feature\n".utf8)
            .write(to: URL(fileURLWithPath: worktree.directory.rawValue + "/.git"))
        let home = ProjectDescriptor.home(directory: "/tmp")
        let identity = ServerId()
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(
            server: identity, home: home.id, revision: 1, projects: [home, parent, worktree]
        ))
        server.gitReply = { request in
            switch request.action {
            case .inspectRemoval:
                return .removal(WorktreeRemoval(directory: worktree.directory, device: 1, inode: 1,
                                               dirty: false, branch: "feature", ignoredPaths: []))
            case .worktreeHooks:
                return .worktreeHooks([])
            default:
                return .summary(GitSummary(branch: "feature", base: "main"))
            }
        }
        let model = ModelFixtures.model(try ModelFixtures.profile(), server: server)
        let presenter = ModelTestPresenter()
        presenter.confirms = false
        model.presenter = presenter
        model.start()
        defer { model.connection(.local)?.disconnect() }
        let ready = await ModelFixtures.wait { model.state.project(worktree.id) != nil }
        XCTAssertTrue(ready)
        let pane = Pane(content: .browser(BrowserPane(url: "about:blank")))
        XCTAssertTrue(model.edit { try $0.openPane(worktree.id, pane) })

        model.git[worktree.id] = GitInfo(summary: GitSummary(branch: "feature", base: "main"))
        model.closePane(pane.id)
        let asked = await ModelFixtures.wait { !presenter.confirmations.isEmpty }
        XCTAssertTrue(asked)
        XCTAssertEqual(presenter.confirmations, ["Close Worktree?"])
        XCTAssertNotNil(model.state.pane(pane.id))
        XCTAssertFalse(server.gitRequests.contains {
            if case .worktree = $0.action { return true }
            return false
        })

        let second = Pane(content: .browser(BrowserPane(url: "about:blank")))
        XCTAssertTrue(model.edit { try $0.openPane(worktree.id, second) })
        model.closePane(second.id)
        let closed = await ModelFixtures.wait { model.state.pane(second.id) == nil }
        XCTAssertTrue(closed)
        XCTAssertNotNil(model.state.pane(pane.id))
        XCTAssertEqual(presenter.confirmations.count, 1, "Closing a split must not remove its worktree")

        // The command line may be at another computer than this window, so it
        // never leaves a question here: its last pane points at tab tab close.
        do {
            _ = try await model.control(AppPaneControl(.close, pane: pane.id.description))
            XCTFail("closed a worktree's last pane from the command line")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("tab tab close"))
        }
        XCTAssertNotNil(model.state.pane(pane.id))
        XCTAssertEqual(presenter.confirmations.count, 1)

        presenter.confirms = true
        model.closePane(pane.id)
        let removed = await ModelFixtures.wait {
            server.gitRequests.contains {
                if case .worktree = $0.action { return true }
                return false
            }
        }
        XCTAssertTrue(removed)
        XCTAssertNil(model.state.pane(pane.id))
        XCTAssertEqual(presenter.confirmations.count, 2)
    }

    /// An agent told to close its worktree's tab, with the user at another
    /// computer: what would be lost fails the command instead of a question
    /// nobody sees, and `--force` closes it without asking here.
    func testCommandClosesWorktreeTabWithoutAQuestionHere() async throws {
        let parent = ProjectDescriptor(directory: ServerPath(try ModelFixtures.folder("parent")), name: "parent")
        let worktree = ProjectDescriptor(directory: ServerPath(try ModelFixtures.folder("feature")),
                                         name: "feature", kind: .worktree, parentId: parent.id)
        try Data("gitdir: ../parent/.git/worktrees/feature\n".utf8)
            .write(to: URL(fileURLWithPath: worktree.directory.rawValue + "/.git"))
        let home = ProjectDescriptor.home(directory: "/tmp")
        let identity = ServerId()
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(
            server: identity, home: home.id, revision: 1, projects: [home, parent, worktree]
        ))
        server.gitReply = { request in
            switch request.action {
            case .inspectRemoval:
                return .removal(WorktreeRemoval(directory: worktree.directory, device: 1, inode: 1, dirty: true,
                                               branch: "feature", ignoredPaths: []))
            case .worktreeHooks:
                return .worktreeHooks([])
            default:
                return .summary(GitSummary(branch: "feature", base: nil))
            }
        }
        let model = ModelFixtures.model(try ModelFixtures.profile(), server: server)
        let presenter = ModelTestPresenter()
        model.presenter = presenter
        model.start()
        defer { model.connection(.local)?.disconnect() }
        let ready = await ModelFixtures.wait { model.state.project(worktree.id) != nil }
        XCTAssertTrue(ready)
        let pane = Pane(content: .browser(BrowserPane(url: "about:blank")))
        XCTAssertTrue(model.edit { try $0.openPane(worktree.id, pane) })
        func removed() -> Bool {
            server.gitRequests.contains {
                if case .worktree = $0.action { return true }
                return false
            }
        }

        do {
            _ = try await model.control(AppPaneControl(.closeTab, pane: pane.id.description))
            XCTFail("closed a worktree with uncommitted changes without --force")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("uncommitted changes"))
        }
        XCTAssertNotNil(model.state.pane(pane.id))
        XCTAssertFalse(removed())

        let forced = try await model.control(AppPaneControl(.closeTab, pane: pane.id.description, force: true))
        XCTAssertEqual(forced, .bool(true))
        let gone = await ModelFixtures.wait { removed() && model.state.pane(pane.id) == nil }
        XCTAssertTrue(gone)
        XCTAssertEqual(presenter.confirmations, [])
    }

    /// The setup line is typed into a shell, so a worktree name or path with
    /// quotes or `$(…)` must stay data, and a failing command must stop the rest.
    func testSetupCommandQuotesValuesPassesVariablesAndStopsAtTheFirstFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tab it's \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worktree = ProjectDescriptor(directory: ServerPath(directory.path), name: "it's $(touch injected)",
                                         kind: .worktree, parentId: ProjectId())
        let hooks = [
            WorktreeHook(command: #"printf '%s|%s|%s\n' "$TAB_WORKTREE_NAME" "$TAB_WORKTREE_BRANCH" "$TAB_WORKTREE_PATH" > out"#, project: true),
            WorktreeHook(command: "false", project: true),
            WorktreeHook(command: "touch never", project: false),
        ]
        let command = AppModel.setupCommand(hooks, worktree: worktree, repository: "/repo", branch: "feat/x")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        let output = try String(contentsOf: directory.appendingPathComponent("out"), encoding: .utf8)
        XCTAssertEqual(output, "it's $(touch injected)|feat/x|\(directory.path)\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("injected").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("never").path))
    }

    /// A line editor acts on tabs and newlines as they're typed, so such a
    /// command travels encoded and still runs as written.
    func testSetupCommandWithControlCharactersIsEncodedAndStillRuns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tab-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worktree = ProjectDescriptor(directory: ServerPath(directory.path), name: "w", kind: .worktree, parentId: ProjectId())
        let hooks = [WorktreeHook(command: "printf 'a\\tb\\n' > first\nprintf '%s\\n' \"$TAB_WORKTREE_NAME\" > second", project: true)]
        let command = AppModel.setupCommand(hooks, worktree: worktree, repository: "/repo", branch: "w")
        XCTAssertFalse(command.unicodeScalars.contains { $0.value < 0x20 })

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("first"), encoding: .utf8), "a\tb\n")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("second"), encoding: .utf8), "w\n")
    }

    /// Closing a worktree deletes without asking only folders a build fills
    /// again; ignored files and other ignored folders may be the user's.
    func testOnlyWholeBuildFoldersCountAsRebuildable() {
        XCTAssertTrue(AppModel.isRebuildable("node_modules/"))
        XCTAssertTrue(AppModel.isRebuildable("packages/web/.next/"))
        XCTAssertFalse(AppModel.isRebuildable(".env"))
        XCTAssertFalse(AppModel.isRebuildable("node_modules"))
        XCTAssertFalse(AppModel.isRebuildable("secrets/"))
        XCTAssertFalse(AppModel.isRebuildable("data/"))
    }

    /// `tab tab close` can't ask the user, so it closes a worktree without
    /// `--force` only when nothing is lost; anything else stops it.
    func testCommandCloseStopsAtAnythingLost() {
        func losses(dirty: Bool = false, branch: String? = "task", ignored: [String]? = [],
                    hooks: Result<[WorktreeHook], ModelError> = .success([])) -> [String] {
            let removal = WorktreeRemoval(directory: ServerPath("/w"), device: 1, inode: 1, dirty: dirty,
                                          branch: branch, ignoredPaths: ignored)
            return AppModel.losses(AppModel.RemovalInspection(removal: removal, hooks: hooks))
        }
        XCTAssertEqual(losses(ignored: [".build/", "node_modules/"]), [])
        XCTAssertEqual(losses(dirty: true).count, 1)
        XCTAssertEqual(losses(branch: nil).count, 1)
        XCTAssertTrue(losses(ignored: [".build/", "vendor/Lib.xcframework/"])[0].contains("vendor/Lib.xcframework/"))
        XCTAssertEqual(losses(ignored: nil).count, 1)
        XCTAssertEqual(losses(ignored: Array(repeating: ".build/", count: 50)).count, 1)
        XCTAssertEqual(losses(hooks: .success([WorktreeHook(command: "make clean", project: true)])).count, 1)
        XCTAssertEqual(losses(hooks: .failure(ModelError("offline"))).count, 1)
    }

    func testOnlyAHashAndAPositiveNumberNameAPullRequest() {
        XCTAssertEqual(PaletteSource.pullRequestNumber("#482"), 482)
        XCTAssertEqual(PaletteSource.pullRequestNumber(" #7 "), 7)
        XCTAssertNil(PaletteSource.pullRequestNumber("482"))
        XCTAssertNil(PaletteSource.pullRequestNumber("#0"))
        XCTAssertNil(PaletteSource.pullRequestNumber("#12a"))
        XCTAssertNil(PaletteSource.pullRequestNumber("fix-#12"))
    }
}
