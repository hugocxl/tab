import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

/// A repository that answers with queued replies and records what was asked.
private final class FakeGit: RepositoryGit, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<GitReply, AIActionError>]
    private var recorded: [GitAction] = []
    let files: [String: String]

    init(_ replies: [Result<GitReply, AIActionError>], files: [String: String] = [:]) {
        self.replies = replies
        self.files = files
    }

    var actions: [GitAction] { lock.withLock { recorded } }

    func git(_ action: GitAction, project: ProjectId) async throws -> GitReply {
        let reply: Result<GitReply, AIActionError> = lock.withLock {
            recorded.append(action)
            return replies.isEmpty ? .failure(AIActionError("missing fake reply")) : replies.removeFirst()
        }
        return try reply.get()
    }

    func readFile(_ path: String, project: ProjectId) async -> String? { files[path] }
}

final class AIRepositoryActionsTests: XCTestCase {
    private typealias Plan = RepositoryActions.Plan

    private func status(_ branch: String, conflicted: UInt32 = 0, head: String = "abc") -> GitReply {
        .status(GitStatus(
            summary: GitSummary(branch: branch, head: head, changed: 1, conflicted: conflicted),
            defaultBranch: "main",
            branches: [GitBranch(name: branch, current: true, checkedOut: true, isDefault: branch == "main")]
        ))
    }

    private func preview(_ branch: String, files: [(String, Bool)], remote: Bool = true) -> GitChangesPreview {
        GitChangesPreview(
            branch: branch, head: "abc", tree: "tree1",
            diff: GitRawDiff(diff: "diff --git a/file b/file\n+new line\n"),
            files: files.map { GitPreviewFile(path: ServerPath($0.0), added: 1, removed: 0, untracked: $0.1) },
            destination: remote ? GitPushDestination(remote: "origin", branch: branch) : nil
        )
    }

    private func plan(_ action: RepositoryAction, mode: RepositoryActions.Mode, branch: String,
                      files: [(String, Bool)], choices: CommitChoices = CommitChoices()) -> Plan {
        Plan(project: ProjectId(), action: action, mode: mode, choices: choices, branch: branch, defaultBranch: "main",
             preview: preview(branch, files: files), subjects: ["Fix: earlier change"],
             localBranches: ["main", "feature"], remoteBranches: ["main", "release", "feature"])
    }

    private func pullRequestDraft(_ branch: String, target: String = "main", title: String = "Fix status") -> RepositoryActions.Draft {
        .pullRequest(title: title, summary: "Summary", branch: branch, target: target)
    }

    func testConflictsAndStaleBranchesAreRefusedBeforeReadingChanges() async {
        let conflicted = FakeGit([.success(status("feature", conflicted: 1))])
        do {
            _ = try await RepositoryActions.prepare(conflicted, project: ProjectId(), action: .commit,
                                                    choices: CommitChoices(), branch: "feature", head: "abc")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? AIActionError)?.message, "Resolve merge conflicts first")
        }
        XCTAssertEqual(conflicted.actions.count, 1)

        let moved = FakeGit([.success(status("other"))])
        do {
            _ = try await RepositoryActions.prepare(moved, project: ProjectId(), action: .commit,
                                                    choices: CommitChoices(), branch: "feature", head: "abc")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? AIActionError)?.message, RepositoryActions.changed)
        }
    }

    func testCommitUsesTheReviewedTreeThenPushesToItsDestination() async {
        let plan = plan(.commit, mode: .commit, branch: "feature", files: [("file", false)])
        let git = FakeGit([.success(status("feature")), .success(.commit("deadbeef00")), .success(.done)])
        let outcome = await RepositoryActions.apply(git, plan: plan, draft: .commit(message: "Explain the change"))
        XCTAssertEqual(outcome, .success(.committed(hash: "deadbeef00", branch: "feature", pushed: plan.preview.destination)))
        XCTAssertEqual(git.actions[1], .commitAll(message: "Explain the change", expectedHead: "abc", expectedTree: "tree1"))
        XCTAssertEqual(git.actions[2], .publishBranch(branch: "feature",
                                                      destination: GitPushDestination(remote: "origin", branch: "feature")))
    }

    func testStagedOnlyCommitsLeaveTheIndexAloneAndSkipPushing() async throws {
        let stagedOnly = CommitChoices(includeUnstaged: false, push: false)
        let reading = FakeGit([
            .success(status("feature")),
            .success(.changesPreview(preview("feature", files: [("staged", false)]))),
            .success(.log([])),
        ])
        let plan = try await RepositoryActions.prepare(reading, project: ProjectId(), action: .commit, choices: stagedOnly,
                                                       branch: "feature", head: "abc")
        XCTAssertEqual(reading.actions[1], .stagedPreview(lineLimit: RepositoryActions.diffLines))

        let git = FakeGit([.success(status("feature")), .success(.commit("deadbeef00"))])
        let outcome = await RepositoryActions.apply(git, plan: plan, draft: .commit(message: "Explain the change"))
        XCTAssertEqual(outcome, .success(.committed(hash: "deadbeef00", branch: "feature", pushed: nil)))
        XCTAssertEqual(Array(git.actions.dropFirst()),
                       [.commitStaged(message: "Explain the change", expectedHead: "abc", expectedTree: "tree1")])
    }

    func testRepositoryChangesBeforeApplyAreRefusedWithoutMutating() async {
        let plan = plan(.commit, mode: .commit, branch: "feature", files: [("file", false)])
        let git = FakeGit([.success(.status(GitStatus(summary: GitSummary(branch: "feature", head: "moved"))))])
        let outcome = await RepositoryActions.apply(git, plan: plan, draft: .commit(message: "Change"))
        guard case .failure(let failure) = outcome else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.title, "No commit was created")
        XCTAssertEqual(git.actions.count, 1)
    }

    func testPullRequestsFromTheDefaultBranchMoveChangesToANewBranch() async throws {
        let reading = FakeGit([
            .success(status("main")),
            .success(.pullRequest(nil)),
            .success(.done),
            .success(.changesPreview(preview("main", files: [("file", false)]))),
            .success(.log([])),
            .success(.remoteBranches(["main"])),
            .success(.rawDiff(GitRawDiff(diff: ""))),
        ], files: [".github/pull_request_template.md": "## Summary"])
        let plan = try await RepositoryActions.prepare(reading, project: ProjectId(), action: .createPullRequest,
                                                       choices: CommitChoices(), branch: "main", head: "abc")
        XCTAssertEqual(plan.mode, .newBranch)
        XCTAssertEqual(plan.template, "## Summary")
        let draft = try RepositoryActions.parseDraft(plan, output: #"{"title":"Fix status","summary":"Summary","newBranchName":"fix/status","targetBranchName":"main"}"#)
        XCTAssertEqual(draft, pullRequestDraft("fix/status"))

        let url = "https://github.com/example/repo/pull/12"
        let git = FakeGit([
            .success(status("main")),
            .success(.done),
            .success(.commit("def0000")),
            .success(.done),
            .success(.pullRequest(GitPullRequest(number: 12, url: url, title: "Fix status", headBranch: "fix/status",
                                                 baseBranch: "main", state: "OPEN"))),
        ])
        let outcome = await RepositoryActions.apply(git, plan: plan, draft: draft)
        XCTAssertEqual(outcome, .success(.pullRequest(url: url)))
        let actions = git.actions
        XCTAssertEqual(actions[1], .createBranch("fix/status"))
        guard case .commitAll(let message, _, _) = actions[2] else { return XCTFail("expected a commit") }
        XCTAssertEqual(message, "Fix status")
        XCTAssertEqual(actions[3], .publishBranch(branch: "fix/status",
                                                  destination: GitPushDestination(remote: "origin", branch: "fix/status")))
        guard case .pullRequest(.create(_, _, let base, _)) = actions[4] else { return XCTFail("expected a pull request") }
        XCTAssertEqual(base, "main")
    }

    func testReviewedDraftsAreValidatedBeforeAnyChange() async {
        let plan = plan(.createPullRequest, mode: .newBranch, branch: "main", files: [("file", false)])
        let cases: [(RepositoryActions.Draft, String)] = [
            (pullRequestDraft("feature"), "Choose a new branch name that isn't used yet"),
            (pullRequestDraft("bad name"), "Choose a new branch name that isn't used yet"),
            (pullRequestDraft("fix-x", target: "missing"), "Choose a target branch that exists on the remote"),
            (pullRequestDraft("fix-x", title: " "), "Enter a title of up to 256 characters"),
        ]
        for (draft, error) in cases {
            let git = FakeGit([])
            let outcome = await RepositoryActions.apply(git, plan: plan, draft: draft)
            guard case .failure(let failure) = outcome else { return XCTFail("expected a failure for \(draft)") }
            XCTAssertEqual(failure.detail, "\(error)\n\nChanges were staged before generating AI metadata.")
            XCTAssertTrue(git.actions.isEmpty)
        }
    }

    func testAPushFailureSaysTheCommitIsSavedLocally() async {
        let plan = plan(.commit, mode: .commit, branch: "feature", files: [("file", false)])
        let git = FakeGit([.success(status("feature")), .success(.commit("deadbeef00")), .failure(AIActionError("rejected"))])
        let outcome = await RepositoryActions.apply(git, plan: plan, draft: .commit(message: "Change"))
        XCTAssertEqual(outcome, .failure(RepositoryActions.Failure(
            "Committed deadbee on feature, but couldn't push",
            "rejected. The commit is saved locally; push it when you're ready."
        )))
    }

    // MARK: Prompts and answers

    func testPromptCarriesInstructionsAndTheRepositoryAsSortedJSON() throws {
        var plan = plan(.createPullRequest, mode: .newBranch, branch: "main", files: [("src/a.swift", false)])
        plan.template = "## Summary"
        let prompt = RepositoryActions.prompt(plan, instructions: "Be brief.")
        XCTAssertTrue(prompt.hasPrefix("Generate pull request metadata from the repository context below."))
        XCTAssertTrue(prompt.contains("User instructions:\nBe brief.\n"))
        XCTAssertTrue(prompt.hasSuffix("When pullRequestTemplate is present, follow its structure in the summary.\nDo not use Markdown fences or include any other text."))
        let start = try XCTUnwrap(prompt.range(of: "<repository_context>\n"))
        let end = try XCTUnwrap(prompt.range(of: "\n</repository_context>"))
        let json = String(prompt[start.upperBound..<end.lowerBound])
        XCTAssertTrue(json.hasPrefix(#"{"changedFiles":[{"added":1,"path":"src/a.swift","removed":0,"untracked":false}]"#), json)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(context["currentBranch"] as? String, "main")
        XCTAssertEqual(context["pullRequestTemplate"] as? String, "## Summary")
        XCTAssertEqual(context["remoteBranches"] as? [String], ["main", "release", "feature"])
        XCTAssertEqual(context["diffWasTruncated"] as? Bool, false)
        XCTAssertNil(context["branchDiff"])

        let commit = RepositoryActions.prompt(self.plan(.commit, mode: .commit, branch: "feature", files: []), instructions: "x")
        XCTAssertFalse(commit.contains("remoteBranches"))
        XCTAssertTrue(commit.contains(#"{"message":"Concise commit subject and optional body"}"#))
    }

    func testLongDiffsAreCutOnACharacterBoundaryAndMarkedTruncated() throws {
        var plan = plan(.commit, mode: .commit, branch: "feature", files: [("file", false)])
        plan.preview.diff = GitRawDiff(diff: String(repeating: "é", count: 40_000))
        let prompt = RepositoryActions.prompt(plan, instructions: "")
        XCTAssertTrue(prompt.contains(#""diffWasTruncated":true"#))
        let clipped = RepositoryActions.clip("aé", bytes: 2)
        XCTAssertEqual(clipped.text, "a")
        XCTAssertTrue(clipped.clipped)
    }

    func testProjectPullRequestPromptsWinOverTheActionPrompt() {
        let project = ProjectId()
        let settings = AISettings(prompts: ["create_pr": "Action prompt", "commit": "  "],
                                  projectPrPrompts: [project.description: "Project prompt"])
        XCTAssertEqual(RepositoryActions.configuredPrompt(.createPullRequest, settings: settings, promptProject: project),
                       "Project prompt")
        XCTAssertEqual(RepositoryActions.configuredPrompt(.createPullRequest, settings: settings, promptProject: ProjectId()),
                       "Action prompt")
        XCTAssertEqual(RepositoryActions.configuredPrompt(.commit, settings: settings, promptProject: project),
                       RepositoryAction.commit.defaultPrompt)
        XCTAssertEqual(RepositoryActions.instructions(configured: "Base", additional: "  extra \n"), "Base\n\nextra")
        XCTAssertEqual(RepositoryActions.instructions(configured: "Base", additional: " "), "Base")
    }

    func testAnswersWrappedInPreambleOrFencesAreDecoded() throws {
        let plan = plan(.commit, mode: .commit, branch: "feature", files: [("file", false)])
        let wrapped = "Here you go:\n```json\n{\"message\": \"Fix {braces} and \\\"quotes\\\"\"}\n```"
        XCTAssertEqual(try RepositoryActions.parseDraft(plan, output: wrapped), .commit(message: "Fix {braces} and \"quotes\""))
        XCTAssertThrowsError(try RepositoryActions.parseDraft(plan, output: "no json here")) { error in
            XCTAssertEqual((error as? AIActionError)?.message, RepositoryActions.invalidResponse)
        }
        XCTAssertThrowsError(try RepositoryActions.parseDraft(plan, output: #"{"message":"  "}"#))
    }

    func testBranchNamesFollowGitRules() {
        for valid in ["fix/status", "feature-1", "a.b_c"] { XCTAssertTrue(RepositoryActions.validBranch(valid), valid) }
        for invalid in ["", "-x", "/x", "x/", "x.", "x.lock", "a..b", "a//b", "bad name", "ü"] {
            XCTAssertFalse(RepositoryActions.validBranch(invalid), invalid)
        }
    }

    func testStepsSayWhatAlreadyHappened() {
        XCTAssertEqual(RepositoryActions.steps([], failed: "couldn't push"), "Couldn't push")
        XCTAssertEqual(RepositoryActions.steps(["Created branch x"], failed: "couldn't push"), "Created branch x, but couldn't push")
        XCTAssertEqual(RepositoryActions.steps(["a", "b", "c"], failed: "d"), "a, b and c, but d")
    }

    // MARK: Providers and confirmation

    func testConfiguredProvidersMustBeInstalled() {
        let claude = AIProvider.provider(id: "claude")!
        let codex = AIProvider.provider(id: "codex")!
        XCTAssertEqual(AIProvider.resolve(.commit, settings: AISettings(), installed: [codex, claude]), .success(codex))
        XCTAssertEqual(AIProvider.resolve(.commit, settings: AISettings(providers: ["commit": "claude"]), installed: [codex]),
                       .failure(AIActionError("Claude Code CLI is not installed. Choose another provider or install its CLI.")))
        guard case .failure(let gone) = AIProvider.resolve(.commit, settings: AISettings(providers: ["commit": "gone"]),
                                                           installed: [codex]) else { return XCTFail("expected a failure") }
        XCTAssertTrue(gone.message.contains("no longer supported"))
        XCTAssertEqual(AIProvider.resolve(.createPullRequest, settings: AISettings(), installed: []),
                       .failure(AIActionError("Install a supported AI provider CLI or choose one in Settings → AI.")))
    }

    func testNothingStagedIncludesUnstagedChangesButKeepsTheRememberedChoice() {
        let providers = Array(AIProvider.all.prefix(2))
        var confirmation = AIConfirmation(action: .commit, provider: providers[0], providers: providers,
                                          choices: CommitChoices(includeUnstaged: false, push: true), staged: false,
                                          branch: "feature")
        XCTAssertTrue(confirmation.commitChoices.includeUnstaged)
        confirmation.confirm(.init(prompt: "", provider: providers[1], includeUnstaged: true, push: false))
        XCTAssertEqual(confirmation.provider, providers[1])
        XCTAssertFalse(confirmation.choices.includeUnstaged)
        XCTAssertFalse(confirmation.choices.push)
        XCTAssertTrue(confirmation.commitChoices.includeUnstaged)
    }
}
