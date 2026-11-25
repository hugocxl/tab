import Foundation
import TabCore
import TabProtocol

/// Reads a project's branch settings, its `.config/tab/settings.json` over
/// the user's `~/.config/tab/settings.json` (see `TabConfig`), and runs their
/// `open` and `close` commands. Commands run without asking: being in a
/// settings file is the user's say-so.
struct BranchCommandRunner: Sendable {
    /// How long one event's commands may take together.
    static let limit: TimeInterval = 300

    /// The user's file.
    let userFile: URL

    init(userFile: URL = TabConfig.userFile()) {
        self.userFile = userFile
    }

    /// The settings of the project whose folder is `directory`.
    func settings(projectDirectory directory: String) throws -> BranchSettings {
        do {
            return try TabConfig.branchSettings(projectDirectory: directory, userFile: userFile)
        } catch let error as SettingsError {
            throw gitError("Invalid \(error.description)")
        }
    }

    /// The variables every command gets. `project` is the project's own
    /// folder; `directory` the branch's folder, where commands run.
    static func variables(project: String, directory: String, branch: String,
                          worktree: ProjectDescriptor? = nil) -> [String: String] {
        var variables = ["TAB_PROJECT_PATH": project, "TAB_BRANCH": branch, "TAB_BRANCH_PATH": directory]
        if let worktree {
            variables["TAB_WORKTREE_ID"] = worktree.id.description
            variables["TAB_WORKTREE_NAME"] = worktree.name
        }
        return variables
    }

    /// Runs `commands` in order in `directory`, all within one five-minute
    /// limit. Stops at the first failure with its output.
    func run(_ commands: [BranchCommand], in directory: String, variables: [String: String],
             limit: TimeInterval = BranchCommandRunner.limit) throws {
        guard !commands.isEmpty else { return }
        let deadline = Date().addingTimeInterval(limit)
        let shell = Self.shell()
        var environment = GitCommand.environment()
        environment.removeValue(forKey: "LC_ALL")
        environment.removeValue(forKey: "GIT_EDITOR")
        environment.removeValue(forKey: "GIT_MERGE_AUTOEDIT")
        environment.removeValue(forKey: "GIT_OPTIONAL_LOCKS")
        if let path = LoginPath.value { environment["PATH"] = path }
        environment.merge(variables) { _, new in new }
        for command in commands {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw gitError("“\(command.label)” didn't start: the commands took over five minutes") }
            let output: ProcessOutput
            do {
                output = try ProcessRunner.run(shell, ["-c", command.command], directory: directory,
                                               environment: environment, timeout: remaining)
            } catch let failure as ProcessFailure {
                if case .timedOut = failure { throw gitError("“\(command.label)” timed out") }
                throw gitError("“\(command.label)” failed: \(failure)")
            }
            guard output.succeeded else {
                throw gitError("“\(command.label)” failed: \(GitCommand.failure(output).message)")
            }
        }
    }

    /// The user's shell when it is an absolute path to a file, else `/bin/sh`.
    static func shell() -> String {
        guard let shell = ProcessInfo.processInfo.environment["SHELL"], shell.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: shell) else { return "/bin/sh" }
        return shell
    }
}

/// The `PATH` a login shell sets up, so commands find tools installed by
/// the user's shell profile even when the server started from the app.
enum LoginPath {
    static let value: String? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        guard let output = try? ProcessRunner.run(shell, ["-lc", "printf '\\0%s\\0' \"$PATH\""], directory: "/",
                                                  timeout: 3),
            output.succeeded else { return nil }
        let parts = output.stdoutText.split(separator: "\0", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }()
}
