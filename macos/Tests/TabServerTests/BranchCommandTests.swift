import Foundation
import XCTest
@testable import TabServer
import TabProtocol

/// The `open` and `close` commands of `settings.json`, for worktrees and for
/// a project's default branch, and the default branch it names.
final class BranchCommandTests: XCTestCase {
    private func projectSettings(_ repo: GitTestRepo, _ json: String) throws {
        try repo.write(".config/tab/settings.json", json)
    }

    private func userSettings(_ repo: GitTestRepo, _ json: String) throws {
        try repo.write("user-settings.json", json)
    }

    private func createAction(_ repo: GitTestRepo, runCommands: Bool? = true, hooks: [WorktreeHook]? = nil,
                              branch: String = "feature") -> GitAction {
        .worktree(WorktreeIntent(action: .create(project: ProjectId(),
                                                 directory: ServerPath(repo.path + "/nested/trees/" + branch),
                                                 branch: branch, base: "main"),
                                 options: WorktreeOptions(name: "Friendly name", hooks: hooks, runCommands: runCommands)))
    }

    private func removeAction(_ repo: GitTestRepo, _ project: ProjectId, runCommands: Bool? = true) throws -> GitAction {
        guard case .removal(let expected) = try repo.git(.inspectRemoval, project: project) else {
            throw GitTestError.failed("removal")
        }
        return .worktree(WorktreeIntent(action: .remove(expected: expected), options: WorktreeOptions(runCommands: runCommands)))
    }

    func testWorktreeCommandsMergeBothFilesRunInOrderWithTheirVariablesAndOnce() throws {
        let repo = try GitTestRepo(commit: true)
        try userSettings(repo, #"{"worktrees":{"open":["printf user > order"],"close":[{"name":"User","command":"printf user >> \"$TAB_PROJECT_PATH/removed\""}]}}"#)
        try projectSettings(repo, #"""
            {"worktrees":{"open":["printf project >> order",
              "printf '%s\\n' \"$TAB_PROJECT_PATH\" \"$TAB_BRANCH_PATH\" \"$TAB_BRANCH\" \"$TAB_WORKTREE_NAME\" \"$TAB_WORKTREE_ID\" > environment"],
             "close":["printf project > \"$TAB_PROJECT_PATH/removed\""]}}
            """#)
        guard case .branchSettings(let settings) = try repo.git(.branchSettings) else { return XCTFail("settings") }
        XCTAssertEqual(settings.worktreeCommands.open.map(\.project), [false, true, true])
        XCTAssertEqual(settings.worktreeCommands.close.map(\.project), [true, false])
        XCTAssertEqual(settings.worktreeCommands.close.last?.name, "User")

        let action = createAction(repo)
        guard case .project(let project) = try repo.git(action) else { return XCTFail("project") }
        XCTAssertEqual(project.name, "Friendly name")
        let target = project.directory.rawValue
        XCTAssertEqual(try String(contentsOfFile: target + "/order", encoding: .utf8), "userproject")
        let values = try String(contentsOfFile: target + "/environment", encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(values.map(String.init), [repo.path, target, "feature", "Friendly name", project.id.description])
        // A retry gets the first answer without running anything again.
        XCTAssertEqual(try repo.git(action), .project(project))
        XCTAssertEqual(try String(contentsOfFile: target + "/order", encoding: .utf8), "userproject")

        let removal = try removeAction(repo, project.id)
        XCTAssertEqual(try repo.git(removal, project: project.id), .done)
        XCTAssertEqual(try repo.git(removal, project: project.id), .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
        XCTAssertEqual(try repo.read("removed"), "projectuser")
    }

    func testCommandsRunOnlyWhenAskedAndABrokenFileStopsOnlyThoseThatAsk() throws {
        let repo = try GitTestRepo(commit: true)
        try projectSettings(repo, #"{"worktrees":{"open":["touch open-ran"],"close":["touch \"$TAB_PROJECT_PATH/close-ran\""]}}"#)
        guard case .project(let quiet) = try repo.git(createAction(repo, runCommands: nil)) else { return XCTFail("project") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: quiet.directory.rawValue + "/open-ran"))
        XCTAssertEqual(try repo.git(try removeAction(repo, quiet.id, runCommands: nil), project: quiet.id), .done)
        XCTAssertFalse(repo.exists("close-ran"))

        try projectSettings(repo, #"{"worktrees":{"location":"../fixed"}}"#)
        XCTAssertTrue(repo.errorMessage { try repo.git(self.createAction(repo, branch: "broken")) }.contains("{branch}"))
        XCTAssertFalse(repo.exists("nested/trees/broken"))
        guard case .project(let project) = try repo.git(createAction(repo, runCommands: nil, branch: "other")) else {
            return XCTFail("project")
        }
        XCTAssertEqual(try repo.git(try removeAction(repo, project.id, runCommands: nil), project: project.id), .done)
    }

    func testOpenFailureKeepsTheWorktreeAndReportsItOnReplay() throws {
        let repo = try GitTestRepo(commit: true)
        try projectSettings(repo, #"{"worktrees":{"open":["printf once >> attempted; echo open-failure >&2; exit 1","touch should-not-run"]}}"#)
        let action = createAction(repo)
        let reply = try repo.git(action)
        guard case .worktreeSetupFailed(let project, let message) = reply else { return XCTFail("open failure") }
        XCTAssertTrue(message.contains("open-failure"), message)
        XCTAssertEqual(try repo.catalog.project(project.id), project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.directory.rawValue + "/.git"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.directory.rawValue + "/should-not-run"))
        XCTAssertEqual(try repo.git(action), reply)
        XCTAssertEqual(try String(contentsOfFile: project.directory.rawValue + "/attempted", encoding: .utf8), "once")
    }

    func testCloseFailureStillRemovesTheWorktreeAndSaysWhatFailed() throws {
        let repo = try GitTestRepo(commit: true)
        guard case .project(let project) = try repo.git(createAction(repo)) else { return XCTFail("project") }
        let target = project.directory.rawValue
        try projectSettings(repo, #"{"worktrees":{"close":["echo close-failure >&2; exit 1"]}}"#)
        guard case .commandsFailed(let message) = try repo.git(try removeAction(repo, project.id), project: project.id) else {
            return XCTFail("close failure")
        }
        XCTAssertTrue(message.contains("close-failure"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
        XCTAssertFalse(repo.catalog.contains(project.id))
    }

    func testOlderClientsSeeTheCommandsAsHooksAndStillRunWhatTheySend() throws {
        let repo = try GitTestRepo(commit: true)
        try projectSettings(repo, #"{"worktrees":{"open":[{"name":"Mark","command":"touch open-ran"}],"close":["true"]}}"#)
        guard case .worktreeHooks(let hooks) = try repo.git(.worktreeHooks(teardown: false)) else { return XCTFail("hooks") }
        XCTAssertEqual(hooks, [WorktreeHook(command: "touch open-ran", name: "Mark", project: true)])
        guard case .project(let project) = try repo.git(createAction(repo, runCommands: nil, hooks: hooks)) else {
            return XCTFail("project")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.directory.rawValue + "/open-ran"))
    }

    func testVariablesKeepTheProjectPathAndCanonicalizeTheWorktreePath() throws {
        let repo = try GitTestRepo(commit: true)
        let alias = repo.path + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: repo.path)
        repo.catalog.add(ProjectDescriptor(id: repo.project, directory: ServerPath(alias), name: "Alias"))
        try projectSettings(repo, #"{"worktrees":{"open":["printf '%s\\n' \"$TAB_PROJECT_PATH\" \"$TAB_BRANCH_PATH\" \"$PWD\" > environment"]}}"#)
        let target = alias + "/tree"
        guard case .project(let project) = try repo.git(.worktree(WorktreeIntent(action: .create(
            project: ProjectId(), directory: ServerPath(target), branch: "feature", base: "main"),
            options: WorktreeOptions(runCommands: true)))) else {
            return XCTFail("project")
        }
        let canonicalTarget = repo.path + "/tree"
        XCTAssertEqual(project.directory.rawValue, canonicalTarget)
        let values = try String(contentsOfFile: canonicalTarget + "/environment", encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(values, [alias, canonicalTarget, canonicalTarget])
    }

    func testTheNamedDefaultBranchWinsOverDetectionForBranchesAndStatus() throws {
        let repo = try GitTestRepo(commit: true)
        _ = try repo.run("branch", "develop")
        guard case .branches(let detected) = try repo.git(.branches) else { return XCTFail("branches") }
        XCTAssertEqual(detected.filter(\.isDefault).map(\.name), ["main"])
        try userSettings(repo, #"{"defaultBranch":{"name":"main"}}"#)
        try projectSettings(repo, #"{"defaultBranch":{"name":"develop"}}"#)
        guard case .branches(let branches) = try repo.git(.branches) else { return XCTFail("branches") }
        XCTAssertEqual(branches.filter(\.isDefault).map(\.name), ["develop"])
        guard case .status(let status) = try repo.git(.status(local: true)) else { return XCTFail("status") }
        XCTAssertEqual(status.defaultBranch, "develop")
        // A broken file never breaks Git.
        try projectSettings(repo, "{")
        guard case .branches(let fallback) = try repo.git(.branches) else { return XCTFail("branches") }
        XCTAssertEqual(fallback.filter(\.isDefault).map(\.name), ["main"])
        XCTAssertTrue(repo.errorMessage { try repo.git(.branchSettings) }.contains(".config/tab/settings.json"))
    }

    func testDefaultBranchCommandsRunInTheBackgroundAndReportFailures() throws {
        let repo = try GitTestRepo(commit: true)
        try projectSettings(repo, #"""
            {"defaultBranch":{"open":["printf '%s %s' \"$TAB_BRANCH\" \"$TAB_BRANCH_PATH\" > opened"],
             "close":["echo close-failure >&2; exit 1"]}}
            """#)
        let project = try repo.catalog.project(repo.project)
        repo.service.runDefaultBranchCommands(project, closing: false)
        try waitUntil { repo.exists("opened") }
        XCTAssertEqual(try repo.read("opened"), "main \(repo.path)")
        repo.service.runDefaultBranchCommands(project, closing: true)
        try waitUntil { !repo.events.broadcasts.isEmpty }
        guard case .branchCommandsFailed(let id, let message) = repo.events.broadcasts.first else { return XCTFail("event") }
        XCTAssertEqual(id, project.id)
        XCTAssertTrue(message.contains("close-failure"), message)
        // Worktrees and Home never run default-branch commands.
        var worktree = project
        worktree.kind = .worktree
        worktree.parentId = ProjectId()
        repo.service.runDefaultBranchCommands(worktree, closing: true)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(repo.events.broadcasts.count, 1)
    }

    func testCommandsShareOneTimeLimit() throws {
        XCTAssertEqual(BranchCommandRunner.limit, 300)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tab-commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = BranchCommandRunner(userFile: directory.appendingPathComponent("none.json"))
        let started = Date()
        XCTAssertThrowsError(try runner.run([BranchCommand(command: "sleep 0.3", project: true),
                                             BranchCommand(command: "sleep 10", project: true)],
                                            in: directory.path, variables: [:], limit: 0.6)) {
            XCTAssertTrue(($0 as? ServiceError)?.message.contains("timed out") == true, "\($0)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw GitTestError.failed("timed out waiting") }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}
