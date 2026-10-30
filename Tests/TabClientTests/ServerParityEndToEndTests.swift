import Darwin
import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabClient

/// Exercises the installed command line and a real daemon with isolated HOME,
/// PATH and profile folders. Socket restrictions skip only the live checks.
final class ServerParityEndToEndTests: XCTestCase {
    private var root: URL!
    private var environment: [String: String] = [:]
    private var daemon: Process?
    private var client: ServerClient?
    private var readers: [Task<Void, Never>] = []

    private var products: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent() }
    private var profile: URL { root.appendingPathComponent("p") }
    private var repository: URL { root.appendingPathComponent("repo") }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/ts2-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let resolved = realpath(root.path, nil) else { throw POSIXError(.EIO) }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved))
        for folder in [profile, repository, root.appendingPathComponent("home/.config/tab"),
                       root.appendingPathComponent("bin"), root.appendingPathComponent("tmp")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        environment = ProcessInfo.processInfo.environment
        environment["TAB_DIR"] = profile.path
        environment["TAB_SERVER_BIN"] = products.appendingPathComponent("tabd").path
        environment["HOME"] = root.appendingPathComponent("home").path
        environment["TMPDIR"] = root.appendingPathComponent("tmp").path + "/"
        environment["PATH"] = root.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        environment["SHELL"] = "/bin/bash"
        environment["GH_PARITY_LOG"] = root.appendingPathComponent("gh-calls").path
        environment["GH_PARITY_FIXTURE"] = root.appendingPathComponent("gh-response").path
        environment["GH_REPO"] = "must-be-removed"
        for key in ["XDG_CONFIG_HOME", "ZDOTDIR", "TAB_SESSION_ID", "TAB_SERVER_ID", "BASH_ENV", "ENV", "PROMPT_COMMAND"] {
            environment.removeValue(forKey: key)
        }
    }

    override func tearDown() async throws {
        readers.forEach { $0.cancel() }
        if daemon?.isRunning == true {
            let stopped = try run("tab", ["server", "stop", "--force"])
            XCTAssertEqual(stopped.status, 0, stopped.text)
            if stopped.status != 0 { _ = try? await client?.stopServer(force: true) }
            for _ in 0..<100 where daemon?.isRunning == true {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if daemon?.isRunning == true {
                daemon?.terminate()
                daemon?.waitUntilExit()
                XCTFail("the daemon did not exit after tab server stop --force")
            }
        }
        client?.close()
        let log = (try? String(contentsOf: profile.appendingPathComponent("server.log"), encoding: .utf8)) ?? ""
        let problems = log.split(separator: "\n").filter { $0.contains(" ERROR ") || $0.contains(" WARN ") }
        if !problems.allSatisfy({ $0.contains("Operation not permitted") || $0.contains("Permission denied") }) {
            XCTFail("server.log: \(problems.joined(separator: "\n"))")
        }
        try? FileManager.default.removeItem(at: root)
    }

    private struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var text: String { String(decoding: stdout + stderr, as: UTF8.self) }
    }

    private func run(_ executable: String, _ arguments: [String], env: [String: String]? = nil) throws -> Output {
        let process = Process()
        process.executableURL = executable.hasPrefix("/") ? URL(fileURLWithPath: executable)
            : products.appendingPathComponent(executable)
        process.arguments = arguments
        process.environment = env ?? environment
        process.currentDirectoryURL = repository
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    @discardableResult
    private func cli(_ arguments: [String]) throws -> Data {
        let result = try run("tab", arguments)
        guard result.status == 0 else { throw Failure.message("tab \(arguments): \(result.status): \(result.text)") }
        return result.stdout
    }

    private func git(_ arguments: [String]) throws -> String {
        let result = try run("/usr/bin/git", arguments)
        guard result.status == 0 else { throw Failure.message("git \(arguments): \(result.text)") }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ path: String, _ text: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func start() async throws -> ServerClient {
        let executable = products.appendingPathComponent("tabd")
        guard Executable.isExecutableFile(executable) else { throw XCTSkip("Build tabd before running ServerParityEndToEndTests") }
        let process = Process()
        process.executableURL = executable
        process.arguments = []
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        daemon = process
        let local = LocalServer(dirs: TabDirs(root: profile))
        var lastError: Error?
        for _ in 0..<200 {
            do {
                let connected = try await local.connect(kind: .desktop, start: false)
                client = connected
                return connected
            } catch {
                lastError = error
                if !process.isRunning { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        let log = (try? String(contentsOf: profile.appendingPathComponent("server.log"), encoding: .utf8)) ?? ""
        if log.contains("Operation not permitted") || log.contains("Permission denied") {
            throw XCTSkip("ServerParityEndToEndTests needs unsandboxed Unix sockets: \(log)")
        }
        throw Failure.message("tabd failed to serve (status \(process.isRunning ? -1 : process.terminationStatus)): \(String(describing: lastError)); \(log)")
    }

    private func project(_ client: ServerClient) async throws -> ProjectDescriptor {
        _ = try git(["init", "-b", "main"])
        _ = try git(["config", "user.name", "Tab Tests"])
        _ = try git(["config", "user.email", "tab@example.invalid"])
        try write("repo/file", "initial\n")
        _ = try git(["add", "file"])
        _ = try git(["commit", "-m", "initial"])
        let project = ProjectDescriptor(directory: ServerPath(repository.path), name: "Parity")
        _ = try await client.mutateProject(ProjectIntent(mutation: .create(project)))
        return project
    }

    private func action(_ project: ProjectId, _ action: GitAction) throws -> GitReply {
        let json = String(decoding: try WireJSON.encode(action), as: UTF8.self)
        return try WireJSON.decode(GitReply.self, from: cli(["git", project.description, json]))
    }

    func testBuildInfoNeedsNoProfileAndMatchesBothExecutables() throws {
        var env = environment
        let absent = root.appendingPathComponent("uncreated/profile")
        env["TAB_DIR"] = absent.path
        var builds: [BuildInfo] = []
        for name in ["tabd", "tab"] {
            let result = try run(name, ["--build-info"], env: env)
            XCTAssertEqual(result.status, 0, result.text)
            XCTAssertTrue(result.stderr.isEmpty, result.text)
            XCTAssertFalse(result.stdout.contains(10), "Codesh prints one JSON value without a newline")
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["version", "compatibility", "protocol"])
            XCTAssertEqual(object["compatibility"] as? Int, 21)
            XCTAssertEqual(object["protocol"] as? [Int], [1])
            builds.append(try JSONDecoder().decode(BuildInfo.self, from: result.stdout))
            XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        }
        XCTAssertEqual(builds.first, builds.last)
        for flag in ["--version", "-V", "--help", "-h"] {
            XCTAssertEqual(try run("tabd", [flag], env: env).status, 0)
        }
    }

    func testUserAndProjectHooksThroughCLIWithOverriddenHome() async throws {
        let client = try await start()
        let parent = try await project(client)
        try write("home/.config/tab/worktree.json", #"{"setup":["printf user > order"],"teardown":["printf user >> \"$TAB_PROJECT_PATH/removed\""]}"#)
        try write("repo/.tab/worktree.json", #"{"setup":["printf project >> order","printf '%s\\n' \"$TAB_PROJECT_PATH\" \"$TAB_WORKTREE_PATH\" \"$TAB_WORKTREE_NAME\" \"$TAB_WORKTREE_BRANCH\" \"$TAB_WORKTREE_ID\" \"$PWD\" > hook-env"],"teardown":["printf project > \"$TAB_PROJECT_PATH/removed\""]}"#)
        let target = root.appendingPathComponent("hook-tree")
        let data = try cli(["worktree", "create", parent.id.description, "Friendly", "--branch", "feature", "--base", "main",
                            "--directory", target.path, "--hooks", "--json"])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let id = try XCTUnwrap(object["id"] as? String)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("order"), encoding: .utf8), "userproject")
        let values = try String(contentsOf: target.appendingPathComponent("hook-env"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(object["directory"] as? String, target.path)
        XCTAssertEqual(values, [repository.path, target.path, "Friendly", "feature", id, target.path])
        _ = try cli(["worktree", "remove", id, "--force", "--hooks", "--yes"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try String(contentsOf: repository.appendingPathComponent("removed"), encoding: .utf8), "projectuser")
    }

    func testExternalWorktreeDiscoveryVisibilityAndPruning() async throws {
        let client = try await start()
        let parent = try await project(client)
        let target = root.appendingPathComponent("external")
        _ = try git(["worktree", "add", "-b", "external", target.path])
        guard case .worktrees(let before) = try action(parent.id, .worktrees) else { return XCTFail("worktrees") }
        let discovered = before.filter {
            !$0.primary && !$0.bare && !$0.prunable
                && $0.directory.rawValue != repository.path
        }
        let external = try XCTUnwrap(discovered.first { $0.directory.rawValue == target.path })
        XCTAssertEqual(external.branch, "external")
        XCTAssertNil(external.registered)
        let registered = try cli(["worktree", "register", parent.id.description, external.directory.rawValue, "--json"])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: registered) as? [String: Any])
        let id = try XCTUnwrap((object["id"] as? String).flatMap(ProjectId.init(string:)))
        let catalog = try await client.catalog()
        XCTAssertEqual(catalog.projects.first { $0.id == id }?.parentId, parent.id)
        guard case .worktrees(let imported) = try action(parent.id, .worktrees) else { return XCTFail("worktrees") }
        XCTAssertEqual(imported.first { $0.directory == external.directory }?.registered, id)
        for visible in [false, true] {
            _ = try await client.mutateProject(ProjectIntent(mutation: .setWorktreesVisible(project: parent.id, visible: visible)))
            let page = try await client.catalog()
            XCTAssertEqual(page.projects.first { $0.id == parent.id }?.worktreesHidden, !visible)
            XCTAssertTrue(page.projects.contains { $0.id == id })
        }
        _ = try await client.mutateProject(ProjectIntent(mutation: .pruneWorktree(id)))
        var page = try await client.catalog()
        XCTAssertTrue(page.projects.contains { $0.id == id }, "existing directories are retained")
        _ = try git(["worktree", "remove", target.path])
        guard case .worktrees(let removed) = try action(parent.id, .worktrees) else { return XCTFail("worktrees") }
        XCTAssertFalse(removed.contains { $0.registered == id || $0.directory == external.directory })
        _ = try await client.mutateProject(ProjectIntent(mutation: .pruneWorktree(id)))
        page = try await client.catalog()
        XCTAssertFalse(page.projects.contains { $0.id == id })
        guard case .worktrees(let after) = try action(parent.id, .worktrees) else { return XCTFail("worktrees") }
        XCTAssertEqual(after.count, 1)
        let kept = root.appendingPathComponent("kept-history")
        _ = try git(["worktree", "add", "-b", "kept-history", kept.path])
        guard case .project(let child) = try action(parent.id, .worktree(WorktreeIntent(action: .register(
            project: ProjectId(), directory: ServerPath(kept.path))))) else { return XCTFail("register") }
        let session = try await client.createSession(CreateSession(project: child.id, directory: child.directory, size: Size(cols: 80, rows: 24)))
        try await client.endSession(session.id)
        _ = try git(["worktree", "remove", "--force", kept.path])
        _ = try await client.mutateProject(ProjectIntent(mutation: .pruneWorktree(child.id)))
        page = try await client.catalog()
        XCTAssertTrue(page.projects.contains { $0.id == child.id }, "saved sessions prevent pruning")
        try await client.discardSession(session.id)
        _ = try await client.mutateProject(ProjectIntent(mutation: .pruneWorktree(child.id)))
        page = try await client.catalog()
        XCTAssertFalse(page.projects.contains { $0.id == child.id })
    }


    func testPullRequestActionsThroughCLIAndCheckoutPRWorktree() async throws {
        try write("bin/gh", #"""
        #!/bin/sh
        test "$GH_PROMPT_DISABLED:$GH_PAGER:$NO_COLOR:${GH_REPO-unset}" = '1:cat:1:unset' || exit 9
        { printf '%s\0' "$@"; printf '\0'; } >> "$GH_PARITY_LOG"
        case "$1 $2" in
          'repo view') printf '%s' '{"url":"https://github.com/example/repository"}';;
          'pr view') cat "$GH_PARITY_FIXTURE";;
          'pr list') printf '['; cat "$GH_PARITY_FIXTURE"; printf ']';;
          'pr create') printf '%s' 'https://github.com/example/repository/pull/42';;
          'pr merge'|'pr close') exit 0;;
          'pr diff') printf 'diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new\n';;
          *) exit 2;;
        esac
        """#)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("bin/gh").path)
        let client = try await start()
        let parent = try await project(client)
        let remote = root.appendingPathComponent("remote.git").path
        _ = try git(["init", "--bare", remote])
        _ = try git(["remote", "add", "origin", remote])
        _ = try git(["push", "-u", "origin", "main"])
        _ = try git(["switch", "-c", "feature"])
        try write("repo/feature", "feature\n")
        _ = try git(["add", "feature"])
        _ = try git(["commit", "-m", "feature"])
        _ = try git(["push", "-u", "origin", "feature"])
        let head = try git(["rev-parse", "HEAD"])
        _ = try git(["switch", "main"])
        try write("repo/base", "base\n")
        _ = try git(["add", "base"])
        _ = try git(["commit", "-m", "base"])
        _ = try git(["push", "origin", "main"])
        _ = try git(["switch", "feature"])
        var response: [String: Any] = [
            "number": 42, "url": "https://github.com/example/repository/pull/42", "title": "A PR",
            "author": ["login": "contributor"], "headRefName": "feature", "headRefOid": head, "baseRefName": "main",
            "state": "OPEN", "isDraft": false, "updatedAt": "2026-09-18T00:00:00Z", "mergeable": "MERGEABLE",
            "mergeStateStatus": "BEHIND", "isCrossRepository": false,
            "headRepository": ["name": "repository"], "headRepositoryOwner": ["login": "example"],
            "statusCheckRollup": [
                ["__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"],
                ["__typename": "CheckRun", "status": "IN_PROGRESS"],
                ["__typename": "StatusContext", "state": "FAILURE"],
            ],
        ]
        func save() throws {
            try JSONSerialization.data(withJSONObject: response).write(to: root.appendingPathComponent("gh-response"))
        }
        try save()
        XCTAssertEqual(try action(parent.id, .pullRequest(.number)), .pullRequestNumber(42))
        guard case .pullRequest(let info?) = try action(parent.id, .pullRequest(.info)) else { return XCTFail("info") }
        XCTAssertEqual(info.number, 42)
        XCTAssertEqual(info.author, "contributor")
        XCTAssertEqual(info.headOid, head)
        XCTAssertEqual(info.mergeable, true)
        XCTAssertEqual(info.checks, GitChecks(passing: 1, failing: 1, pending: 1))
        for checks in [false, true] {
            guard case .pullRequests(let values) = try action(parent.id, .pullRequest(.list(filter: .open, limit: 50, checks: checks)))
            else { return XCTFail("list") }
            XCTAssertEqual(values, [info])
        }
        guard case .rawDiff(let diff) = try action(parent.id, .pullRequest(.diff(number: 42, lineLimit: 2)))
        else { return XCTFail("diff") }
        XCTAssertTrue(diff.truncated)
        guard case .pullRequest(let created?) = try action(parent.id, .pullRequest(.create(
            title: "  A title  ", body: "body\nsecond line", baseBranch: "main", draft: true)))
        else { return XCTFail("create") }
        XCTAssertEqual(created.number, 42)
        for method in GitMergeMethod.allCases {
            XCTAssertEqual(try action(parent.id, .pullRequest(.merge(number: 42, method: method, deleteBranch: true,
                                                                     expectedHead: head))), .done)
        }
        XCTAssertEqual(try action(parent.id, .pullRequest(.close(number: 42))), .done)
        XCTAssertEqual(try action(parent.id, .pullRequest(.updateBranch(number: 42, expectedHead: head))), .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appendingPathComponent("base").path))
        let updated = try git(["rev-parse", "HEAD"])
        XCTAssertEqual(try git(["--git-dir", remote, "rev-parse", "feature"]), updated)
        response["headRefOid"] = updated
        try save()
        _ = try git(["config", "url.\(remote).insteadOf", "https://github.com/example/repository.git"])
        _ = try git(["switch", "main"])
        XCTAssertEqual(try action(parent.id, .pullRequest(.checkout(number: 42))), .done)
        XCTAssertEqual(try git(["branch", "--show-current"]), "pr/42/feature")
        XCTAssertEqual(try git(["config", "branch.pr/42/feature.tab-pr-number"]), "42")
        _ = try git(["switch", "main"])
        let target = root.appendingPathComponent("pr-tree")
        _ = try cli(["worktree", "checkout-pr", parent.id.description, "42", "--directory", target.path, "--json"])
        XCTAssertEqual(try git(["-C", target.path, "branch", "--show-current"]), "pr/42/feature")
        let calls = try String(contentsOf: root.appendingPathComponent("gh-calls"), encoding: .utf8)
            .components(separatedBy: "\0\0").filter { !$0.isEmpty }.map { $0.components(separatedBy: "\0") }
        let repo = "https://github.com/example/repository"
        let fields = "number,url,title,author,headRefName,headRefOid,baseRefName,state,isDraft,updatedAt,mergeable,mergeStateStatus,isCrossRepository"
        XCTAssertEqual(calls.first, ["repo", "view", "--json", "url"])
        XCTAssertTrue(calls.contains(["pr", "view", "--json", "number,headRefName,headRefOid,state,isCrossRepository"]))
        XCTAssertTrue(calls.contains(["pr", "view", "--json", fields + ",statusCheckRollup"]))
        for checks in [false, true] {
            XCTAssertTrue(calls.contains(["pr", "list", "--repo", repo, "--state", "open", "--limit", "50", "--json",
                                         fields + (checks ? ",statusCheckRollup" : "")]))
        }
        XCTAssertTrue(calls.contains(["pr", "create", "--repo", repo, "--head", "feature", "--base", "main",
                                     "--title", "A title", "--body", "body\nsecond line", "--draft"]))
        for method in GitMergeMethod.allCases {
            XCTAssertTrue(calls.contains(["pr", "merge", "42", "--repo", repo, "--\(method.rawValue)", "--delete-branch",
                                         "--match-head-commit", head]))
        }
        XCTAssertTrue(calls.contains(["pr", "close", "42", "--repo", repo]))
        XCTAssertTrue(calls.contains(["pr", "diff", "42", "--repo", repo, "--color", "never"]))
        XCTAssertEqual(calls.filter { $0 == ["pr", "view", "42", "--repo", repo, "--json",
                                             "headRefName,headRepository,headRepositoryOwner"] }.count, 2)
    }

    func testChunkedUploadsOrderingLimitsAndCleanupThroughDaemon() async throws {
        let client = try await start()
        let home = try await client.catalogPage().home
        let session = try await client.createSession(CreateSession(project: home, directory: ServerPath(root.path),
                                                                    size: Size(cols: 80, rows: 24)))
        let data = Data((0..<(Limits.maxUploadChunk + 17)).map { UInt8($0 % 251) })
        let path = try await client.upload(session: session.id, name: "../shot.png", bytes: data)
        XCTAssertEqual(path.lastComponent, "shot.png")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path.rawValue)), data)
        let folder = URL(fileURLWithPath: path.rawValue).deletingLastPathComponent()
        let uploads = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tab-uploads-\(geteuid())").resolvingSymlinksInPath()
        XCTAssertTrue(path.isAbsolute)
        XCTAssertEqual(folder.path, uploads.appendingPathComponent(session.id.description).path)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.rawValue)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let copy = try await client.upload(session: session.id, name: "shot.png", bytes: Data([42]))
        XCTAssertEqual(copy.lastComponent, "shot-2.png")
        let upload = OperationId()
        let first = UploadChunk(session: session.id, upload: upload, name: "bad", offset: 0, bytes: Data([1, 2]), last: false)
        let reply = try await client.request(.upload(first))
        XCTAssertEqual(reply, .uploaded(nil))
        do {
            _ = try await client.request(.upload(UploadChunk(session: session.id, upload: upload, name: "bad", offset: 5,
                                                           bytes: Data([3]), last: true)))
            XCTFail("out-of-order chunks must fail")
        } catch let error as ClientError { XCTAssertEqual(error.serverCode, .badRequest) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(upload).part").path))
        let raw = FrameConnection(stream: try FileDescriptorStream.connect(unixSocket: profile.appendingPathComponent("server.sock").path))
        defer { raw.close() }
        let timeout = DispatchWorkItem { raw.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }
        func request(_ id: UInt32, _ body: RequestBody) throws -> ReplyBody {
            try raw.send(.request(RequestId(id), body))
            while let frame = try raw.receive() {
                if case .message(.reply(let request, let reply)) = frame, request.rawValue == id { return reply }
            }
            throw Failure.message("raw upload connection ended")
        }
        _ = try request(1, .hello(Hello(client: .cli)))
        let invalid = [
            UploadChunk(session: session.id, upload: OperationId(), name: "large", offset: 0,
                        bytes: Data(repeating: 1, count: Limits.maxUploadChunk + 1), last: true),
            UploadChunk(session: session.id, upload: OperationId(), name: "large", offset: Limits.maxUploadBytes,
                        bytes: Data([1]), last: true),
            UploadChunk(session: session.id, upload: OperationId(), name: "missing", offset: 2,
                        bytes: Data([1]), last: true),
        ]
        for (index, chunk) in invalid.enumerated() {
            guard case .error(let error) = try request(UInt32(index + 2), .upload(chunk)) else { return XCTFail("upload limit") }
            XCTAssertEqual(error.code, .badRequest)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["shot.png", "shot-2.png"])
        let partial = OperationId()
        _ = try await client.request(.upload(UploadChunk(session: session.id, upload: partial, name: "unfinished", offset: 0,
                                                       bytes: Data([1]), last: false)))
        try await client.endSession(session.id)
        try await client.discardSession(session.id)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
                       ["shot.png", "shot-2.png", "\(partial).part"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path.rawValue)), data)
        do {
            _ = try await client.request(.upload(UploadChunk(session: session.id, upload: OperationId(), name: "discarded",
                                                           offset: 0, bytes: Data([1]), last: true)))
            XCTFail("discarded sessions must refuse uploads")
        } catch let error as ClientError { XCTAssertEqual(error.serverCode, .unknownSession) }
    }


    private func shell(_ client: ServerClient, zsh: Bool = false) async throws -> (SessionInfo, Attachment, Capture) {
        try await client.writeServerSettings(ServerSettingsDoc(defaultShell: ServerPath(zsh ? "/bin/zsh" : "/bin/bash"),
                                                                shellIntegration: zsh))
        let home = try await client.catalogPage().home
        let session = try await client.createSession(CreateSession(project: home, directory: ServerPath(root.path),
                                                                    size: Size(cols: 80, rows: 24)))
        let attachment = try await client.attach(session: session.id, size: Size(cols: 80, rows: 24))
        try await client.syncSessionReferences(sessions: [session.id])
        let capture = Capture(attachment.snapshot)
        readers.append(Task {
            for await event in attachment.events {
                capture.add(event)
                if case .frame(let frame) = event { try? client.ack(channel: attachment.channel, seq: frame.seq) }
            }
        })
        readers.append(Task {
            for await event in client.events {
                if case .progress(let id, let value) = event, id == session.id { capture.add(value) }
            }
        })
        if zsh {
            try await wait("initial semantic shell prompt", capture) {
                $0.grid.prompts.contains($0.grid.history.count + Int($0.grid.cursor.row))
            }
        }
        try send(session.id, "stty -echo; printf '\\nSHELL_READY\\n'")
        try await wait("shell ready", capture) { $0.hasLine("SHELL_READY") }
        if zsh {
            try await wait("semantic shell prompt", capture) {
                $0.grid.prompts.contains($0.grid.history.count + Int($0.grid.cursor.row))
            }
        }
        return (session, attachment, capture)
    }

    private func send(_ session: SessionId, _ command: String) throws {
        _ = try cli(["session", "send", session.description, command + "\r"])
    }

    private func emit(_ session: SessionId, _ text: String, suffix: String = "") throws {
        let escaped = text.utf8.map { String(format: "\\0%03o", $0) }.joined()
        try send(session, "printf '%b' '\(escaped)'" + suffix)
    }

    private func wait(_ label: String, _ capture: Capture, timeout: TimeInterval = 8,
                      until predicate: (Capture.State) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(capture.state) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure.message("Timed out waiting for \(label); screen: \(capture.state.text); metadata: \(capture.state.metadata); progress: \(capture.state.progress); modes: \(capture.state.frames.map(\.modes))")
    }

    func testTerminalThemeOverridesAndCursorDefaultsReachExistingAndNewSessions() async throws {
        let client = try await start()
        let (session, _, capture) = try await shell(client)
        let colors = TerminalColors(foreground: RGB(17, 34, 51), background: RGB(68, 85, 102), cursor: RGB(119, 136, 153),
                                    ansi: Array(repeating: RGB(170, 187, 204), count: 16), palette: [200: RGB(221, 238, 255)],
                                    cursorStyle: .bar, cursorBlink: false)
        try await client.setTerminalColors(colors)
        try await wait("theme cursor", capture) { state in
            state.grid.cursor.shape == .bar && state.metadata.contains(.cursorBlinking(false))
        }
        func query(_ session: SessionId, name: String) throws {
            let queries = "\u{1b}]10;?\u{07}\u{1b}]11;?\u{07}\u{1b}]12;?\u{07}\u{1b}]4;1;?\u{07}\u{1b}]4;200;?\u{07}"
            let escaped = queries.utf8.map { String(format: "\\%03o", $0) }.joined()
            try send(session, "stty -echo -icanon min 0 time 2; printf '%b' '\(escaped)'; dd bs=1 count=4096 of='\(root.path)/\(name)' 2>/dev/null; stty icanon; printf '\\n\(name)_DONE\\n'")
        }
        try query(session.id, name: "existing")
        try await wait("existing color query", capture) { $0.hasLine("existing_DONE") }
        let expected = ["rgb:1111/2222/3333", "rgb:4444/5555/6666", "rgb:7777/8888/9999",
                        "rgb:aaaa/bbbb/cccc", "rgb:dddd/eeee/ffff"]
        let replies = try String(contentsOf: root.appendingPathComponent("existing"), encoding: .utf8).lowercased()
        for color in expected { XCTAssertTrue(replies.contains(color), replies.debugDescription) }
        let home = try await client.catalogPage().home
        let newer = try await client.createSession(CreateSession(project: home, directory: ServerPath(root.path),
                                                                  size: Size(cols: 80, rows: 24)))
        let attachment = try await client.attach(session: newer.id, size: Size(cols: 80, rows: 24))
        XCTAssertEqual(attachment.snapshot.cursor.shape, .bar)
        let next = Capture(attachment.snapshot)
        readers.append(Task {
            for await event in attachment.events {
                next.add(event)
                if case .frame(let frame) = event { try? client.ack(channel: attachment.channel, seq: frame.seq) }
            }
        })
        try query(newer.id, name: "new")
        try await wait("new session color query", next) { $0.hasLine("new_DONE") }
        let newReplies = try String(contentsOf: root.appendingPathComponent("new"), encoding: .utf8).lowercased()
        for color in expected { XCTAssertTrue(newReplies.contains(color), newReplies.debugDescription) }
        var reset = colors
        reset.palette = [:]
        reset.cursorStyle = nil
        reset.cursorBlink = nil
        try await client.setTerminalColors(reset)
        try await wait("cursor defaults reset", capture) { $0.grid.cursor.shape == .block && $0.metadata.contains(.cursorBlinking(true)) }
        try await client.endSession(newer.id)
        try await client.endSession(session.id)
    }

    func testClearScreenSendsFormFeedAtSemanticPromptThroughBothRequests() async throws {
        let client = try await start()
        try write("home/.zshrc", "PROMPT='PARITY> '\nfunction parity-clear() { print -rn -- redraw >> '\(root.path)/redraw'; zle clear-screen }\nzle -N parity-clear\nbindkey '^L' parity-clear\n")
        let (session, attachment, capture) = try await shell(client, zsh: true)
        for request in [true, false] {
            try emit(session.id, "\r\nOLD_OUTPUT\r\n")
            try await wait("semantic prompt after output", capture) { state in
                let row = Int(state.grid.cursor.row)
                return state.text.contains("OLD_OUTPUT") && state.grid.prompts.contains(state.grid.history.count + row)
                    && state.grid.rowText(row).contains("PARITY>")
            }
            if request { try await client.clearScreen(channel: attachment.channel) }
            else { try client.clear(channel: attachment.channel) }
            let count = request ? 1 : 2
            try await wait("form feed redraw", capture) { state in
                let redraw = (try? String(contentsOf: self.root.appendingPathComponent("redraw"), encoding: .utf8)) ?? ""
                return redraw == String(repeating: "redraw", count: count)
                    && !state.text.contains("OLD_OUTPUT") && state.text.contains("PARITY>") && state.grid.historyTotal == 0
            }
            let history = try await client.historyPage(channel: attachment.channel, before: nil, maxRows: 10)
            XCTAssertTrue(history.rows.isEmpty)
        }
        try emit(session.id, "\u{1b}[?1049hALT_SCREEN", suffix: "; sleep 2")
        try await wait("alternate screen", capture) { $0.text.contains("ALT_SCREEN") }
        try await client.clearScreen(channel: attachment.channel)
        let observer = try await LocalServer(dirs: TabDirs(root: profile)).connect(kind: .cli, start: false)
        defer { observer.close() }
        let unchanged = try await observer.attachWithoutResize(session: session.id)
        XCTAssertTrue(RunGrid(snapshot: unchanged.snapshot).screenText(lines: 24).contains("ALT_SCREEN"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("redraw"), encoding: .utf8), "redrawredraw")
        try emit(session.id, "\u{1b}[?1049l")
        try await wait("primary screen restored", capture) { $0.text.contains("PARITY>") && !$0.text.contains("ALT_SCREEN") }
        try await client.endSession(session.id)
    }

    func testKittyPlacementsArriveInFramesAndSnapshotsAndAreRemoved() async throws {
        let client = try await start()
        let (session, attachment, capture) = try await shell(client)
        try client.sendCellSize(channel: attachment.channel, CellSize(width: 10, height: 20))
        try emit(session.id, "\u{1b}_Ga=T,f=24,s=1,v=1,i=7,p=9,q=2,c=1,r=1;/wAA\u{1b}\\")
        try await wait("Kitty placement frame", capture) { $0.grid.graphics?.placements.first?.image == 7 }
        let graphics = try XCTUnwrap(capture.state.grid.graphics)
        XCTAssertEqual(graphics.cell, CellSize(width: 10, height: 20))
        XCTAssertEqual(graphics.images.first?.rgba, Data([255, 0, 0, 255]))
        XCTAssertEqual(graphics.placements.first?.id, 9)
        XCTAssertEqual(graphics.placements.first?.size.cols, 1)
        XCTAssertEqual(graphics.placements.first?.size.rows, 1)
        let second = try await LocalServer(dirs: TabDirs(root: profile)).connect(kind: .desktop, start: false)
        defer { second.close() }
        let snapshot = try await second.attachWithoutResize(session: session.id)
        XCTAssertEqual(snapshot.snapshot.graphics, graphics)
        try emit(session.id, "\u{1b}_Ga=d,d=A,q=2\u{1b}\\")
        try await wait("Kitty removal frame", capture) { $0.frames.contains { $0.graphics?.placements.isEmpty == true } && $0.grid.graphics?.placements.isEmpty == true }
        try await client.endSession(session.id)
    }

    func testBellClipboardModesBlinkAndProgressFromPrintfReachClient() async throws {
        let client = try await start()
        let (session, _, capture) = try await shell(client)
        let directory = root.appendingPathComponent("metadata-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try emit(session.id, "\u{1b}]7;file://localhost\(directory.path)\u{07}\u{07}\u{1b}]52;c;56ys5LiA6KGMCnNlY29uZCBsaW5l\u{1b}\\"
                 + "\u{1b}[?1000h\u{1b}[?1004h\u{1b}[?1007h\u{1b}[?1h\u{1b}[?2004h\u{1b}[5 q"
                 + "\u{1b}]9;4;1;42\u{07}\u{1b}]2;Parity title\u{07}", suffix: "; cd '\(directory.path)'; sleep 2")
        try await wait("metadata", capture) { state in
            state.metadata.contains(.bell) && state.metadata.contains(.clipboardWrite("第一行\nsecond line"))
                && state.metadata.contains(.title("Parity title")) && state.metadata.contains(.cursorBlinking(true))
                && state.metadata.contains(.directory(ServerPath(directory.path)))
                && state.metadata.contains { if case .foregroundProcess(let process) = $0 { return process.name == "sleep" && !process.isShell }; return false }
                && state.metadata.contains { if case .inputModes(let modes) = $0 { return modes.mouseTracking && modes.focusEvents && !modes.alternateScroll }; return false }
                && state.frames.contains { $0.modes.applicationCursorKeys && $0.modes.bracketedPaste }
                && state.progress.contains { $0.progress?.state == .running && $0.progress?.percent == 42 }
        }
        try emit(session.id, "\u{1b}[?1049h", suffix: "; sleep 2")
        try await wait("alternate scroll on alternate screen", capture) { state in
            state.metadata.contains { if case .inputModes(let modes) = $0 { return modes.mouseTracking && modes.focusEvents && modes.alternateScroll }; return false }
        }
        for (code, state) in [(2, ProgressState.error), (3, .indeterminate), (4, .paused)] {
            try emit(session.id, "\u{1b}]9;4;\(code)\u{07}")
            try await wait("progress state \(code)", capture) { value in
                value.progress.contains { $0.progress?.state == state && $0.progress?.percent == 42 }
            }
        }
        try emit(session.id, "\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1004l\u{1b}[?1007l\u{1b}[?1l\u{1b}[?2004l\u{1b}[6 q"
                 + "\u{1b}]9;4;0\u{07}", suffix: "; sleep 2")
        try await wait("mode reset and progress completion", capture) { state in
            state.metadata.contains(.inputModes(InputModes())) && state.metadata.contains(.cursorBlinking(false))
                && state.frames.contains { !$0.modes.applicationCursorKeys && !$0.modes.bracketedPaste }
                && state.progress.contains { $0.progress == nil && $0.completed == 1 }
        }
        try await client.endSession(session.id)
    }

    private final class Capture: @unchecked Sendable {
        struct State {
            var grid: RunGrid
            var metadata: [MetadataEvent] = []
            var frames: [ScreenFrame] = []
            var progress: [SessionProgress] = []
            var text: String { grid.screenText(lines: Int(grid.size.rows)) }
            func hasLine(_ line: String) -> Bool {
                text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == line }
            }
        }
        private let lock = NSLock()
        private var value: State
        init(_ snapshot: AttachSnapshot) { value = State(grid: RunGrid(snapshot: snapshot)) }
        var state: State { lock.withLock { value } }
        func add(_ progress: SessionProgress) { lock.withLock { value.progress.append(progress) } }
        func add(_ event: ChannelEvent) {
            lock.withLock {
                switch event {
                case .frame(let frame):
                    value.frames.append(frame)
                    value.grid.apply(frame)
                case .metadata(let metadata):
                    value.metadata.append(metadata)
                    if case .screenPrompts(let seq, let rows) = metadata { value.grid.screenPrompts(seq: seq, rows: rows) }
                default: break
                }
            }
        }
    }

    private enum Failure: Error { case message(String) }
}
