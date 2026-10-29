import Foundation
import XCTest
@testable import TabServer
import TabProtocol

final class HooksTests: XCTestCase {
    private func configure(_ repo: GitTestRepo, setup: [String], teardown: [String]) throws {
        let config = try JSONSerialization.data(withJSONObject: ["setup": setup, "teardown": teardown])
        try repo.write(".tab/worktree.json", String(decoding: config, as: UTF8.self))
    }

    private func preview(_ repo: GitTestRepo, teardown: Bool) throws -> [WorktreeHook] {
        guard case .worktreeHooks(let hooks) = try repo.git(.worktreeHooks(teardown: teardown)) else {
            throw GitTestError.failed("hooks")
        }
        return hooks
    }

    private func createAction(_ repo: GitTestRepo, hooks: [WorktreeHook]?) -> GitAction {
        .worktree(WorktreeIntent(action: .create(project: ProjectId(),
                                                 directory: ServerPath(repo.path + "/nested/trees/feature"),
                                                 branch: "feature", base: "main"),
                                 options: WorktreeOptions(name: "Friendly name", hooks: hooks)))
    }

    private func removeAction(_ repo: GitTestRepo, _ project: ProjectId, hooks: [WorktreeHook]?) throws -> GitAction {
        guard case .removal(let expected) = try repo.git(.inspectRemoval, project: project) else {
            throw GitTestError.failed("removal")
        }
        return .worktree(WorktreeIntent(action: .remove(expected: expected), options: WorktreeOptions(hooks: hooks)))
    }

    func testHooksUseTheSourceConfigEnvironmentAndOrderAndRunOnce() throws {
        let repo = try GitTestRepo(commit: true)
        try repo.write("machine-worktree.json", #"{"setup":["printf global > order"],"teardown":[{"name":"Global","command":"printf global >> \"$TAB_PROJECT_PATH/removed\""}]}"#)
        try configure(repo, setup: [
            "printf project >> order",
            #"printf '%s\n' "$TAB_PROJECT_PATH" "$TAB_WORKTREE_PATH" "$TAB_WORKTREE_NAME" "$TAB_WORKTREE_BRANCH" "$TAB_WORKTREE_ID" > environment"#,
        ], teardown: [#"printf project > "$TAB_PROJECT_PATH/removed""#, "rm order"])
        let setup = try preview(repo, teardown: false)
        XCTAssertEqual(setup.map(\.project), [false, true, true])
        let teardown = try preview(repo, teardown: true)
        XCTAssertEqual(teardown.map(\.project), [true, true, false])
        XCTAssertEqual(teardown.last?.name, "Global")

        let action = createAction(repo, hooks: setup)
        guard case .project(let project) = try repo.git(action) else { return XCTFail("project") }
        XCTAssertEqual(project.name, "Friendly name")
        let target = project.directory.rawValue
        XCTAssertEqual(try String(contentsOfFile: target + "/order", encoding: .utf8), "globalproject")
        let values = try String(contentsOfFile: target + "/environment", encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(values.map(String.init), [repo.path, target, "Friendly name", "feature", project.id.description])
        XCTAssertEqual(try repo.git(action), .project(project))
        XCTAssertEqual(try String(contentsOfFile: target + "/order", encoding: .utf8), "globalproject")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/.tab/worktree.json"))

        let removal = try removeAction(repo, project.id, hooks: try preview(repo, teardown: true))
        XCTAssertEqual(try repo.git(removal, project: project.id), .done)
        XCTAssertEqual(try repo.git(removal, project: project.id), .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
        XCTAssertEqual(try repo.read("removed"), "projectglobal")
    }

    func testHooksAreOptInAndChangedApprovalIsRejectedBeforeCreation() throws {
        let repo = try GitTestRepo(commit: true)
        try configure(repo, setup: ["touch setup-ran"], teardown: ["touch teardown-ran"])
        let approved = try preview(repo, teardown: false)
        try configure(repo, setup: ["touch changed"], teardown: [])
        XCTAssertTrue(repo.errorMessage { try repo.git(self.createAction(repo, hooks: approved)) }
            .contains("changed after approval"))
        XCTAssertFalse(repo.exists("nested"))
        // Invalid repository configuration can neither force hooks nor block opting out.
        try repo.write(".tab/worktree.json", "invalid")
        guard case .project(let project) = try repo.git(createAction(repo, hooks: nil)) else {
            return XCTFail("project")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.directory.rawValue + "/setup-ran"))
        XCTAssertEqual(try repo.git(try removeAction(repo, project.id, hooks: nil), project: project.id), .done)
    }

    func testSetupFailureKeepsTheRegisteredWorktreeAndReportsItOnReplay() throws {
        let repo = try GitTestRepo(commit: true)
        try configure(repo, setup: ["printf once >> attempted; echo setup-failure >&2; exit 1", "touch should-not-run"],
                      teardown: [])
        let action = createAction(repo, hooks: try preview(repo, teardown: false))
        let reply = try repo.git(action)
        guard case .worktreeSetupFailed(let project, let message) = reply else { return XCTFail("setup failure") }
        XCTAssertTrue(message.contains("setup-failure"), message)
        XCTAssertEqual(try repo.catalog.project(project.id), project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.directory.rawValue + "/.git"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.directory.rawValue + "/should-not-run"))
        XCTAssertEqual(try repo.git(action), reply)
        XCTAssertEqual(try String(contentsOfFile: project.directory.rawValue + "/attempted", encoding: .utf8), "once")
    }

    func testTeardownFailurePreservesFilesAndChangedHooksNeedNewApproval() throws {
        let repo = try GitTestRepo(commit: true)
        guard case .project(let project) = try repo.git(createAction(repo, hooks: nil)) else { return XCTFail("project") }
        let target = project.directory.rawValue
        try Data("keep".utf8).write(to: URL(fileURLWithPath: target + "/keep"))
        try configure(repo, setup: [], teardown: ["echo teardown-failure >&2; exit 1"])
        let failed = try removeAction(repo, project.id, hooks: try preview(repo, teardown: true))
        XCTAssertTrue(repo.errorMessage { try repo.git(failed, project: project.id) }.contains("teardown-failure"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target + "/keep"))
        XCTAssertTrue(repo.catalog.contains(project.id))
        let changed = try removeAction(repo, project.id, hooks: try preview(repo, teardown: true))
        try configure(repo, setup: [], teardown: ["touch unexpected"])
        XCTAssertTrue(repo.errorMessage { try repo.git(changed, project: project.id) }.contains("changed after approval"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/unexpected"))
        XCTAssertEqual(try repo.git(try removeAction(repo, project.id, hooks: nil), project: project.id), .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testHooksShareOneTimeLimit() throws {
        XCTAssertEqual(WorktreeHooks.limit, 300)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tab-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = WorktreeHooks(userConfig: directory.appendingPathComponent("none.json"))
        let worktree = ProjectDescriptor(directory: ServerPath(directory.path), name: "tree")
        let started = Date()
        XCTAssertThrowsError(try hooks.run([WorktreeHook(command: "sleep 0.3", project: true),
                                            WorktreeHook(command: "sleep 10", project: true)],
                                           repository: directory.path, worktree: worktree, branch: "main", limit: 0.6)) {
            XCTAssertTrue(($0 as? ServiceError)?.message.contains("timed out") == true, "\($0)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testConfigurationAcceptsStringsAndNamedCommandsAndSkipsBlankOnes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tab-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("worktree.json")
        try Data(#"{"setup":["  npm ci  ",{"name":"Start","command":"docker compose up -d"}," "],"unknown":1}"#.utf8).write(to: file)
        XCTAssertEqual(try WorktreeHooks.load(file.path, teardown: false, project: true), [
            WorktreeHook(command: "npm ci", project: true),
            WorktreeHook(command: "docker compose up -d", name: "Start", project: true),
        ])
        XCTAssertEqual(try WorktreeHooks.load(file.path, teardown: true, project: true), [])
        XCTAssertEqual(try WorktreeHooks.load(directory.appendingPathComponent("missing").path, teardown: false,
                                              project: false), [])
    }
}
