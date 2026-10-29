import AppKit
import XCTest
import TabCore
import TabProtocol
@testable import TabApp

/// The Files panel's tree, ported from Codesh's `files_panel` tests.
final class PanelsFilesTreeTests: XCTestCase {
    private func names(_ tree: FilesTree) -> [String] { tree.visible().map(\.node.name) }

    func testLazyNavigationAndSorting() {
        var tree = FilesTree()
        tree.setEntries("", [fileEntry("z"), fileEntry("Beta"), fileEntry("src", directory: true), fileEntry(".env")])
        XCTAssertEqual(names(tree), ["src", ".env", "Beta", "z"])
        XCTAssertEqual(tree.node(".env")?.dimmed, true)
        tree.step(forward: true)
        XCTAssertEqual(tree.selected, "src")
        XCTAssertTrue(tree.expand("src"))
        XCTAssertFalse(tree.expand("src"))
        tree.setEntries("src", [fileEntry("src/main.rs")])
        tree.step(forward: true)
        XCTAssertEqual(tree.selected, "src/main.rs")
        tree.collapse("src")
        XCTAssertEqual(tree.selected, "src")
        XCTAssertFalse(tree.expand("src"))
        tree.step(forward: false)
        XCTAssertEqual(tree.selected, "src")
    }

    func testIgnoredFilesAreDimmed() {
        var tree = FilesTree()
        tree.setEntries("", [fileEntry("target", directory: true, ignored: true), fileEntry("README.md")])
        XCTAssertEqual(tree.node("target")?.dimmed, true)
        XCTAssertEqual(tree.node("README.md")?.dimmed, false)
    }

    func testRefreshPreservesExpansionAndRemovesDeletedOrRenamedSubtrees() {
        var tree = FilesTree()
        tree.setEntries("", [fileEntry("src", directory: true), fileEntry("other", directory: true)])
        tree.expand("src")
        tree.setEntries("src", [fileEntry("src/old", directory: true)])
        tree.expand("src/old")
        tree.setEntries("src/old", [fileEntry("src/old/a")])
        tree.selected = "src/old/a"
        XCTAssertEqual(tree.refresh(paths: ["src/old/a"], rescan: false), ["src/old"])
        XCTAssertTrue(tree.isExpanded("src/old"))
        tree.setEntries("src", [fileEntry("src/new", directory: true)])
        XCTAssertEqual(tree.selected, "src")
        XCTAssertFalse(tree.isExpanded("src/old"))
        tree.setEntries("", [fileEntry("other", directory: true)])
        XCTAssertFalse(tree.isExpanded("src"))
        XCTAssertNil(tree.selected)
    }

    func testWatchDuringListQueuesAFreshListing() {
        var tree = FilesTree()
        XCTAssertTrue(tree.request(""))
        XCTAssertTrue(tree.refresh(paths: ["new"], rescan: false).isEmpty)
        XCTAssertTrue(tree.setEntries("", []))
        XCTAssertFalse(tree.setEntries("", [fileEntry("new")]))
        tree.setEntries("", [fileEntry("src", directory: true)])
        tree.expand("src")
        tree.setEntries("", [])
        XCTAssertFalse(tree.setEntries("src", [fileEntry("src/stale")]))
        XCTAssertTrue(tree.visible().isEmpty)
    }

    func testHorizontalNavigationDoesNotLeaveEmptyFolder() {
        var tree = FilesTree()
        tree.setEntries("", [fileEntry("a", directory: true), fileEntry("b", directory: true)])
        tree.step(forward: true)
        XCTAssertEqual(tree.right(), "a")
        tree.setEntries("a", [])
        XCTAssertNil(tree.right())
        XCTAssertEqual(tree.selected, "a")
        tree.setEntries("a", [fileEntry("a/file")])
        _ = tree.right()
        XCTAssertEqual(tree.selected, "a/file")
        tree.left()
        XCTAssertEqual(tree.selected, "a")
        tree.left()
        XCTAssertFalse(tree.isExpanded("a"))
        _ = tree.right()
        _ = tree.right()
        tree.collapseAll()
        XCTAssertEqual(tree.selected, "a")
        XCTAssertEqual(tree.visible().count, 2)
    }

    func testRefreshOnlyTouchesAffectedExpandedDirectories() {
        var tree = FilesTree()
        tree.setEntries("", [fileEntry("a", directory: true), fileEntry("b", directory: true)])
        tree.expand("a")
        tree.expand("b")
        tree.setEntries("a", [fileEntry("a/x")])
        tree.setEntries("b", [fileEntry("b/y")])
        XCTAssertEqual(tree.refresh(paths: ["a/x"], rescan: false), ["a"])
        tree.setEntries("a", [fileEntry("a/x")])
        XCTAssertTrue(tree.isExpanded("a") && tree.isExpanded("b"))
        tree.collapse("a")
        XCTAssertTrue(tree.refresh(paths: ["a/x"], rescan: false).isEmpty)
        XCTAssertTrue(tree.expand("a"))
        XCTAssertFalse(tree.expand("b"))
    }

    func testRescanRetriesFailedInitialListing() {
        var tree = FilesTree()
        _ = tree.request("")
        tree.retry()
        XCTAssertEqual(tree.refresh(paths: [], rescan: true), [""])
        XCTAssertTrue(tree.refresh(paths: [], rescan: true).isEmpty)
        XCTAssertTrue(tree.setEntries("", []))
    }

    func testReconnectReissuesRootAndUnloadedExpandedFolders() {
        var tree = FilesTree()
        tree.setEntries("", [fileEntry("src", directory: true)])
        XCTAssertTrue(tree.expand("src"))
        tree.retry()
        XCTAssertEqual(tree.refresh(paths: [], rescan: true), ["", "src"])
        tree.retry()
        XCTAssertEqual(tree.refresh(paths: [], rescan: true), ["", "src"])
        XCTAssertTrue(tree.refresh(paths: [], rescan: true).isEmpty)
    }

    func testCollapsedAncestorsDoNotRefreshHiddenDescendants() {
        var tree = FilesTree()
        tree.setEntries("", [fileEntry("a", directory: true)])
        tree.expand("a")
        tree.setEntries("a", [fileEntry("a/sub", directory: true)])
        tree.expand("a/sub")
        tree.setEntries("a/sub", [fileEntry("a/sub/file")])
        tree.collapse("a")
        XCTAssertTrue(tree.refresh(paths: ["a/sub/file"], rescan: false).isEmpty)
        XCTAssertFalse(tree.expand("a"))
        XCTAssertTrue(tree.isExpanded("a/sub"))
        XCTAssertTrue(tree.request("a/sub"))
    }

    func testRevealExpandsAncestorsAndSelects() {
        var tree = FilesTree()
        tree.setEntries("", [fileEntry("a", directory: true)])
        XCTAssertEqual(tree.reveal("a/b/c.swift"), ["a", "a/b"])
        XCTAssertEqual(tree.selected, "a/b/c.swift")
        XCTAssertTrue(tree.isExpanded("a") && tree.isExpanded("a/b"))
        // A folder's listing arriving before its parent's is dropped, then asked again.
        XCTAssertFalse(tree.setEntries("a/b", [fileEntry("a/b/c.swift")]))
        XCTAssertFalse(tree.isLoaded("a/b"))
        tree.setEntries("a", [fileEntry("a/b", directory: true)])
        XCTAssertTrue(tree.request("a/b"))
    }

    func testFriendlyErrorsHideProtocolCodes() {
        XCTAssertEqual(NativeErrors.friendly("badPath: No such file or directory (os error 2)", folder: false), "File not found")
        XCTAssertEqual(NativeErrors.friendly("badPath: No such file or directory", folder: true), "Folder not found")
        XCTAssertEqual(NativeErrors.friendly("fatal: not a git repository (or any parent)", folder: true), "Not a Git repository")
        XCTAssertEqual(NativeErrors.friendly("permissionDenied: Permission denied", folder: false), "Permission denied")
    }
}

/// The Files panel against a stubbed server.
@MainActor
final class PanelsFilesControllerTests: XCTestCase {
    func testListsRootAndRelistsOnlyChangedFolders() async {
        let host = StubNativeHost()
        let transport = host.transport!
        transport.filesHandler = { action in
            switch action {
            case .list(let path) where path.rawValue.isEmpty:
                return .entries([fileEntry("src", directory: true), fileEntry("README.md")])
            case .list(let path) where path.rawValue == "src":
                return .entries([fileEntry("src/main.swift")])
            default:
                return .entries([])
            }
        }
        let panel = FilesPanelController(host: host)
        panel.loadView()
        panel.ensureRoot()
        await settle { panel.tree.isLoaded("") }
        XCTAssertEqual(panel.tree.visible().map(\.node.path), ["src", "README.md"])
        panel.open("src")
        await settle { panel.tree.isLoaded("src") }
        XCTAssertEqual(panel.tree.visible().map(\.node.path), ["src", "src/main.swift", "README.md"])

        let before = transport.filesRequests.count
        panel.filesChanged(FileChanges(paths: ["src/new.swift"]))
        await settle { transport.filesRequests.count > before }
        XCTAssertEqual(Array(transport.filesRequests.dropFirst(before)), [.list("src")])

        panel.open("README.md")
        XCTAssertEqual(host.opened, ["README.md"])
    }

    func testWaitsForConnectionInsteadOfFailing() async {
        let host = StubNativeHost()
        let transport = host.transport!
        host.transport = nil
        transport.filesHandler = { _ in .entries([fileEntry("a")]) }
        let panel = FilesPanelController(host: host)
        panel.loadView()
        panel.ensureRoot()
        XCTAssertTrue(transport.filesRequests.isEmpty)
        host.transport = transport
        panel.reconnected()
        await settle { panel.tree.isLoaded("") }
        XCTAssertEqual(panel.tree.visible().map(\.node.path), ["a"])
    }
}

/// The Source Control panel's grouping and commit rules, ported from
/// Codesh's `git_panel` tests.
final class PanelsSourceControlTests: XCTestCase {
    private func status() -> GitStatus {
        let files: [(String, Character, Character)] = [
            ("staged.rs", "A", " "), ("changed.rs", " ", "M"), ("both.rs", "M", "M"), ("new.rs", "?", "?"),
            ("conflict.rs", "U", "U"), ("both-added.rs", "A", "A"), ("both-deleted.rs", "D", "D"),
        ]
        return GitStatus(summary: GitSummary(branch: "main"), files: files.map { path, index, worktree in
            GitFileStatus(
                file: GitFile(path: ServerPath(path), index: GitStatusCode(porcelain: index), worktree: GitStatusCode(porcelain: worktree)),
                staged: GitLineStat(additions: 3, deletions: 1),
                unstaged: GitLineStat(additions: 7, deletions: 2)
            )
        })
    }

    func testGroupsPartialStagingAndConflictsWithoutDuplicates() {
        var model = SourceControlModel()
        model.setStatus(status())
        XCTAssertEqual(model.files(in: .staged), [0, 2])
        XCTAssertEqual(model.files(in: .changes), [1, 2])
        XCTAssertEqual(model.files(in: .untracked), [3])
        XCTAssertEqual(model.files(in: .conflicts), [4, 5, 6])
        XCTAssertEqual(model.rows.first, .header(.conflicts))
        XCTAssertEqual(model.rows.count, 4 + 8)
        model.toggle(.conflicts)
        XCTAssertEqual(model.rows.count, 4 + 5)
        XCTAssertEqual(model.paths(in: .staged), ["staged.rs", "both.rs"])
    }

    func testCommitEnablementProtectsIndexAndAllowsAmendWithoutStaging() {
        for amend in [false, true] {
            for staged in [0, 1, 4] {
                for message in ["", " \n\t", "Fix regression"] {
                    let enabled = amend || (staged > 0 && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    XCTAssertEqual(SourceControlModel.canCommit(message: message, amend: amend, busy: false, staged: staged, conflicts: 0), enabled)
                    XCTAssertFalse(SourceControlModel.canCommit(message: message, amend: amend, busy: true, staged: staged, conflicts: 0))
                    XCTAssertFalse(SourceControlModel.canCommit(message: message, amend: amend, busy: false, staged: staged, conflicts: 2))
                }
            }
        }
    }

    func testStatusLettersAndTones() {
        let model = { () -> SourceControlModel in
            var model = SourceControlModel()
            model.setStatus(self.status())
            return model
        }()
        let both = model.file(2)!.file
        XCTAssertEqual(SourceControlModel.letter(both, in: .staged), "M")
        XCTAssertEqual(SourceControlModel.letter(model.file(0)!.file, in: .staged), "A")
        XCTAssertEqual(SourceControlModel.letter(model.file(3)!.file, in: .untracked), "U")
        XCTAssertEqual(SourceControlModel.tone("U", in: .conflicts), .conflict)
        XCTAssertEqual(SourceControlModel.tone("U", in: .untracked), .added)
        XCTAssertEqual(SourceControlModel.tone("D", in: .changes), .deleted)
        XCTAssertEqual(SourceControlModel.tone("R", in: .staged), .renamed)
        XCTAssertEqual(SourceControlModel.tone("M", in: .changes), .modified)
    }

    func testDiscardAsksWithTheFileName() {
        XCTAssertTrue(SourceControlModel.discardMessage(["a.rs"]).hasPrefix("Discard changes to “a.rs”?"))
        XCTAssertTrue(SourceControlModel.discardMessage(["a", "b"]).hasPrefix("Discard changes to 2 files?"))
    }

    @MainActor
    func testCommitSendsMessageAndClearsItOnSuccess() async {
        let host = StubNativeHost()
        let transport = host.transport!
        var staged = status()
        staged.files = [staged.files[0]]
        let clean = staged
        transport.gitHandler = { action in
            switch action {
            case .status: return .status(clean)
            default: return .commit("abc")
            }
        }
        let panel = SourceControlController(host: host)
        panel.loadView()
        panel.refresh()
        await settle { panel.model.status != nil }
        XCTAssertEqual(panel.model.files(in: .staged), [0])
        panel.messageField.string = "Ship it"
        XCTAssertTrue(panel.commitButton.isEnabled)
        panel.commit()
        await settle { panel.messageField.string.isEmpty && !panel.isBusy }
        XCTAssertTrue(transport.gitRequests.contains(.commit(message: "Ship it", stageAll: false, amend: false)))
        XCTAssertEqual(host.repositoryChanges, 1)
    }

    @MainActor
    func testCommitFailureIsAToastAndKeepsTheMessage() async {
        let host = StubNativeHost()
        let transport = host.transport!
        let clean = { () -> GitStatus in var s = self.status(); s.files = [s.files[0]]; return s }()
        transport.gitHandler = { action in
            if case .commit = action { throw ErrorReply(code: .badRequest, message: "nothing to commit") }
            return .status(clean)
        }
        let panel = SourceControlController(host: host)
        panel.loadView()
        panel.refresh()
        await settle { panel.model.status != nil }
        panel.messageField.string = "Ship it"
        panel.commit()
        await settle { !host.toasts.isEmpty }
        XCTAssertEqual(host.toasts, ["nothing to commit"])
        XCTAssertEqual(panel.messageField.string, "Ship it")
    }
}
