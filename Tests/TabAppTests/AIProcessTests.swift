import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

final class AIProcessTests: XCTestCase {
    private func shell(_ script: String, timeout: TimeInterval = 20, limit: Int = AIProvider.outputLimit,
                       cancellation: AICancellation = AICancellation()) throws -> BoundedProcess.Output {
        try BoundedProcess.run(program: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
                               directory: NSTemporaryDirectory(), timeout: timeout, limit: limit, cancellation: cancellation)
    }

    func testAlreadyCancelledAndNullByteInvocationsNeverLaunch() throws {
        let cancellation = AICancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try shell("exit 0", cancellation: cancellation)) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .cancelled)
        }
        XCTAssertThrowsError(try shell("printf 'hidden'\0ignored")) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .io("Process arguments contain a null byte"))
        }
    }

    func testAllProvidersCarryTheCodeshPromptArgumentsAndParseTheirAnswers() throws {
        let folder = URL(fileURLWithPath: "/tmp/tab-ai-test").appendingPathComponent(UUID().uuidString)
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "\(bin.path):/usr/bin:/bin", 1)
        defer {
            if let original { setenv("PATH", original, 1) } else { unsetenv("PATH") }
        }
        let script = #"""
        #!/bin/sh
        log="$0.args"
        printf '%s\0' "$@" > "$log"
        printf '%s' "${OPENCODE_PERMISSION-unset}" > "$0.env"
        pwd -P > "$0.cwd"
        for last; do :; done
        case "$last" in
          'Generate a Git commit message'*) printf 'Here is the result:\n```json\n{"message":"Fix fixture"}\n```';;
          *) printf '{"title":"Fixture PR","summary":"Summary","newBranchName":"fixture-fix","targetBranchName":"main"}';;
        esac
        """#
        for provider in AIProvider.all {
            let tool = bin.appendingPathComponent(provider.executable)
            try script.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        XCTAssertEqual(AIProvider.installed(search: [bin]).count, 12)
        let physical = try XCTUnwrap(realpath(folder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let preview = GitChangesPreview(branch: "feature", head: "abc", tree: "tree",
                                        diff: GitRawDiff(diff: "+fixture"), files: [], destination: nil)
        for action in RepositoryAction.allCases {
            let plan = RepositoryActions.Plan(project: ProjectId(), action: action, mode: action == .commit ? .commit : .newBranch,
                                              choices: CommitChoices(), branch: "feature", defaultBranch: "main",
                                              preview: preview, subjects: ["Prior subject"], localBranches: ["main"], remoteBranches: ["main"])
            let prompt = RepositoryActions.prompt(plan, instructions: "Fixture instructions")
            for provider in AIProvider.all {
                let output = try provider.generate(prompt: prompt, in: folder)
                let arguments = try Data(contentsOf: bin.appendingPathComponent(provider.executable + ".args"))
                    .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                XCTAssertEqual(arguments, provider.arguments + [prompt], provider.name)
                let environment = try String(contentsOf: bin.appendingPathComponent(provider.executable + ".env"), encoding: .utf8)
                if provider.id == "opencode" { XCTAssertEqual(environment, #"{"*":"deny"}"#) }
                let cwd = try String(contentsOf: bin.appendingPathComponent(provider.executable + ".cwd"), encoding: .utf8)
                XCTAssertEqual(cwd.trimmingCharacters(in: .whitespacesAndNewlines), physical)
                let draft = try RepositoryActions.parseDraft(plan, output: output)
                let expected: RepositoryActions.Draft = action == .commit
                    ? .commit(message: "Fix fixture")
                    : .pullRequest(title: "Fixture PR", summary: "Summary", branch: "fixture-fix", target: "main")
                XCTAssertEqual(draft, expected, provider.name)
            }
        }
    }

    func testAFinishedToolIsNotHeldOpenByItsHelpers() throws {
        let started = Date()
        let output = try shell("sleep 30 & echo answer")
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "answer\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCancellationStopsARunningToolAndItsHelpers() throws {
        let cancellation = AICancellation()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("tab-ai-\(UUID().uuidString)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellation.cancel() }
        let started = Date()
        XCTAssertThrowsError(try shell("(sleep 1; touch '\(marker.path)') & sleep 30", cancellation: cancellation)) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the helper outlived its tool")
    }

    func testOverrunningTimeAndOutputAreRefused() {
        XCTAssertThrowsError(try shell("sleep 30", timeout: 0.3)) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .timedOut)
        }
        XCTAssertThrowsError(try shell("yes", limit: 64 * 1024)) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .tooLarge)
        }
    }

    func testAFailingToolReportsItsErrorOutput() {
        XCTAssertThrowsError(try shell("echo 'not logged in' >&2; exit 3")) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .exited("not logged in"))
        }
        XCTAssertThrowsError(try shell("exit 4")) { error in
            XCTAssertEqual(error as? BoundedProcess.Failure, .exited("exit status: 4"))
        }
    }

    func testProvidersRunInTheProjectWithThePromptAsTheirLastArgument() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-ai-\(UUID().uuidString)")
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nfor last; do :; done\nprintf '%s|%s' \"$(pwd -P)\" \"$last\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let provider = try XCTUnwrap(AIProvider.provider(id: "claude"))
        XCTAssertEqual(AIProvider.installed(search: [bin]), [provider])
        let original = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", "\(bin.path):\(original)", 1)
        defer { setenv("PATH", original, 1) }
        let output = try provider.generate(prompt: "-starts with a dash", in: folder)
        let physical = try XCTUnwrap(realpath(folder.path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) })
        XCTAssertEqual(output, "\(physical)| -starts with a dash")
        XCTAssertThrowsError(try provider.generate(prompt: "x", in: folder.appendingPathComponent("missing"))) { error in
            XCTAssertEqual((error as? AIActionError)?.message, "The project directory isn't available on this Mac")
        }
    }
}
