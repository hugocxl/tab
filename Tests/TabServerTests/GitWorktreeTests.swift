import Foundation
import XCTest
@testable import TabServer
import TabProtocol

final class GitWorktreeTests: XCTestCase {
    private func create(_ repo: GitTestRepo, directory: String? = nil, branch: String = "feature",
                        base: String? = "main") throws -> (ProjectId, String, GitAction) {
        let id = ProjectId()
        let directory = directory ?? repo.path + "/checkout"
        let action = GitAction.worktree(WorktreeIntent(action: .create(project: id, directory: ServerPath(directory),
                                                                       branch: branch, base: base)))
        _ = try repo.git(action)
        return (id, directory, action)
    }

    private func inspect(_ repo: GitTestRepo, _ project: ProjectId) throws -> WorktreeRemoval {
        guard case .removal(let removal) = try repo.git(.inspectRemoval, project: project) else {
            throw GitTestError.failed("removal")
        }
        return removal
    }

    func testCreateListInspectAndRemoveWithRetries() throws {
        let repo = try GitTestRepo(commit: true)
        let (id, directory, action) = try create(repo)
        XCTAssertEqual(try repo.git(action), try repo.git(action))
        var isDirectory: ObjCBool = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory + "/.git", isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
        let project = try repo.catalog.project(id)
        XCTAssertEqual(project.kind, .worktree)
        XCTAssertEqual(project.parentId, repo.project)
        XCTAssertEqual(project.name, "feature")
        guard case .worktrees(let entries) = try repo.git(.worktrees) else { return XCTFail("worktrees") }
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].primary)
        XCTAssertTrue(entries.contains { $0.registered == id && $0.branch == "feature" })
        XCTAssertEqual(try repo.git(.summary, project: id), .summary(try repo.summary(at: directory)))

        let expected = try inspect(repo, id)
        XCTAssertFalse(expected.dirty)
        XCTAssertEqual(expected.branch, "feature")
        let remove = GitAction.worktree(WorktreeIntent(action: .remove(expected: expected)))
        XCTAssertEqual(try repo.git(remove, project: id), .done)
        XCTAssertEqual(try repo.git(remove, project: id), .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
        XCTAssertFalse(repo.catalog.contains(id))
        XCTAssertTrue(repo.exists(".git"))
        XCTAssertEqual(repo.catalog.endedSessions.first?.0, id)
    }

    func testInspectRemovalReportsUncommittedChangesAndStaleConfirmationsKeepFiles() throws {
        let repo = try GitTestRepo(commit: true)
        let (id, directory, _) = try create(repo)
        let clean = try inspect(repo, id)
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: directory + "/new"))
        let dirty = try inspect(repo, id)
        XCTAssertTrue(dirty.dirty)
        XCTAssertFalse(dirty.status.isEmpty)
        let message = repo.errorMessage {
            try repo.git(.worktree(WorktreeIntent(action: .remove(expected: clean))), project: id)
        }
        XCTAssertTrue(message.contains("inspect and confirm removal again"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory + "/new"))
        XCTAssertTrue(repo.errorMessage { try repo.git(.inspectRemoval) }.contains("Only a child worktree"))
    }

    func testCreatingInAnExistingFolderSaysSoAndKeepsIt() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.write("taken/keep", "keep me")
        let message = repo.errorMessage { try self.create(repo, directory: repo.path + "/taken", base: "HEAD") }
        XCTAssertTrue(message.contains("already exists"), message)
        XCTAssertEqual(try repo.read("taken/keep"), "keep me")
    }

    func testFailedCreationRemovesOnlyTheFolderItReserved() throws {
        let repo = try GitTestRepo(commit: true)
        XCTAssertThrowsError(try create(repo, directory: repo.path + "/nested/new", base: "missing-base"))
        XCTAssertFalse(repo.exists("nested/new"))
        XCTAssertThrowsError(try create(repo, directory: repo.path + "/nested/existing", branch: "main", base: nil))
        XCTAssertFalse(repo.exists("nested/existing"))
    }

    func testCreatingFromAnExistingBranchReusesABranchHeldByADeletedWorktree() throws {
        let repo = try GitTestRepo(commit: true)
        let stale = repo.path + "/stale"
        try repo.run("worktree", "add", "-b", "release", stale)
        try FileManager.default.removeItem(atPath: stale)
        _ = try create(repo, directory: repo.path + "/release", branch: "release", base: nil)
        let worktrees = try GitRepository(path: repo.path, git: GitCommand()).worktrees()
        XCTAssertTrue(worktrees.allSatisfy { !$0.prunable })
        XCTAssertTrue(worktrees.contains { $0.branch == "release" && $0.directory.rawValue.hasSuffix("/release") })
    }

    func testCheckoutHookFailureStillRegistersTheCreatedWorktree() throws {
        let repo = try GitTestRepo(commit: true)
        try makeExecutable(repo.path + "/.git/hooks/post-checkout", "#!/bin/sh\nexit 1\n")
        let (id, directory, action) = try create(repo)
        XCTAssertTrue(repo.catalog.contains(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory + "/.git"))
        guard case .project = try repo.git(action) else { return XCTFail("project") }
    }

    func testRegisterAddsAnExistingWorktreeAndRefusesThePrimary() throws {
        let repo = try GitTestRepo(commit: true)
        let outside = repo.path + "/outside-tab"
        try repo.run("worktree", "add", "-b", "made-outside", outside)
        guard case .worktrees(let listed) = try repo.git(.worktrees) else { return XCTFail("worktrees") }
        let discovered = try XCTUnwrap(listed.first { $0.directory.rawValue == outside })
        XCTAssertEqual(discovered.branch, "made-outside")
        XCTAssertNil(discovered.registered)
        XCTAssertFalse(discovered.primary || discovered.bare || discovered.prunable)
        let id = ProjectId()
        guard case .project(let project) = try repo.git(.worktree(WorktreeIntent(action: .register(
            project: id, directory: discovered.directory)))) else { return XCTFail("project") }
        XCTAssertEqual(project.name, "made-outside")
        XCTAssertEqual(project.kind, .worktree)
        XCTAssertTrue(repo.catalog.contains(id))
        guard case .worktrees(let imported) = try repo.git(.worktrees) else { return XCTFail("worktrees") }
        XCTAssertEqual(imported.first { $0.directory == discovered.directory }?.registered, id)
        XCTAssertTrue(repo.errorMessage {
            try repo.git(.worktree(WorktreeIntent(action: .register(project: ProjectId(), directory: ServerPath(outside)))))
        }.contains("already registered"))
        XCTAssertTrue(repo.errorMessage {
            try repo.git(.worktree(WorktreeIntent(action: .register(project: ProjectId(), directory: ServerPath(repo.path)))))
        }.contains("already the parent project"))
        XCTAssertThrowsError(try repo.git(.worktree(WorktreeIntent(action: .register(
            project: ProjectId(), directory: ServerPath(repo.path + "/missing"))))))
    }

    func testRemovalStopsProcessesStillRunningInTheWorktree() throws {
        let repo = try GitTestRepo(commit: true)
        let (id, directory, _) = try create(repo)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let expected = try inspect(repo, id)
        XCTAssertEqual(try repo.git(.worktree(WorktreeIntent(action: .remove(expected: expected))), project: id), .done)
        process.waitUntilExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
    }

    func testOperationIdsCannotBeReusedForADifferentRequest() throws {
        let repo = try GitTestRepo(commit: true)
        let operation = OperationId()
        _ = try repo.git(.worktree(WorktreeIntent(operation: operation, action: .create(
            project: ProjectId(), directory: ServerPath(repo.path + "/one"), branch: "one", base: "main"))))
        let message = repo.errorMessage {
            try repo.git(.worktree(WorktreeIntent(operation: operation, action: .create(
                project: ProjectId(), directory: ServerPath(repo.path + "/two"), branch: "two", base: "main"))))
        }
        XCTAssertTrue(message.contains("reused"), message)
    }

    func testActiveOperationsBlockCatalogChangesAndSessionsInRemovedFolders() throws {
        let operations = WorktreeOperations()
        let project = ProjectId()
        try operations.reserve([project], removal: "/tmp/tree") {
            XCTAssertThrowsError(try operations.checkMutation(of: [project]))
            XCTAssertThrowsError(try operations.reserve([project], removal: nil) {})
            XCTAssertThrowsError(try operations.checkSession(directory: "/tmp/tree/sub"))
            XCTAssertNoThrow(try operations.checkSession(directory: "/tmp/treehouse"))
        }
        XCTAssertNoThrow(try operations.checkMutation(of: [project]))
    }

    func testRepositoryReadsOverlapAndMutationsWaitForReaders() throws {
        let repo = try GitTestRepo(commit: true)
        let lock = try repo.service.lock(forRepository: repo.path)
        let readDone = expectation(description: "read")
        let writeDone = expectation(description: "write")
        let wrote = NSLock()
        var finishedWrite = false
        lock.reading { () -> Void in
            DispatchQueue.global().async {
                do { _ = try repo.git(.summary) } catch { XCTFail("\(error)") }
                readDone.fulfill()
            }
            wait(for: [readDone], timeout: 5)
            DispatchQueue.global().async {
                do { _ = try repo.git(.createBranch("parallel")) } catch { XCTFail("\(error)") }
                wrote.lock()
                finishedWrite = true
                wrote.unlock()
                writeDone.fulfill()
            }
            Thread.sleep(forTimeInterval: 0.2)
            wrote.lock()
            XCTAssertFalse(finishedWrite)
            wrote.unlock()
        }
        wait(for: [writeDone], timeout: 5)
    }
}

extension GitTestRepo {
    func summary(at directory: String) throws -> GitSummary {
        try GitRepository(path: directory, git: GitCommand()).summary()
    }
}
