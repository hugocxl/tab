import Foundation
import TabCore
import TabProtocol

/// Setup and teardown commands for worktrees, from the project's
/// `.tab/worktree.json` and the user's `$XDG_CONFIG_HOME/tab/worktree.json`:
///
/// ```json
/// { "setup": ["npm ci", { "name": "Start services", "command": "docker compose up -d" }],
///   "teardown": ["docker compose down"] }
/// ```
///
/// Setup runs the user's commands first, then the project's; teardown runs
/// the project's first. Commands run only when approved as an exact preview.
struct WorktreeHooks: Sendable {
    static let projectFile = ".tab/worktree.json"
    static let limit: TimeInterval = 300
    static let maxConfigBytes = 1024 * 1024
    static let maxHooks = 128

    /// The user's configuration file.
    let userConfig: URL

    init(userConfig: URL = TabDirs.configHome().appendingPathComponent("worktree.json")) {
        self.userConfig = userConfig
    }

    /// The hooks configured for worktrees of the project at `repository`, in run order.
    func resolve(repository: String, teardown: Bool) throws -> [WorktreeHook] {
        let user = try Self.load(userConfig.path, teardown: teardown, project: false)
        let project = try Self.load((repository as NSString).appendingPathComponent(Self.projectFile),
                                    teardown: teardown, project: true)
        let hooks = teardown ? project + user : user + project
        if hooks.count > Self.maxHooks { throw gitError("Too many worktree hooks") }
        return hooks
    }

    /// Refuses hooks that changed since the user approved `approved`.
    func verify(repository: String, teardown: Bool, approved: [WorktreeHook]) throws {
        if try resolve(repository: repository, teardown: teardown) != approved {
            throw gitError("Worktree hooks changed after approval. Review them and try again.")
        }
    }

    /// Runs `hooks` in order inside the worktree, all within one five-minute
    /// limit. Stops at the first failure with its output.
    func run(_ hooks: [WorktreeHook], repository: String, worktree: ProjectDescriptor, branch: String,
             limit: TimeInterval = WorktreeHooks.limit) throws {
        let deadline = Date().addingTimeInterval(limit)
        let shell = Self.shell()
        var environment = GitCommand.environment()
        environment.removeValue(forKey: "LC_ALL")
        environment.removeValue(forKey: "GIT_EDITOR")
        environment.removeValue(forKey: "GIT_MERGE_AUTOEDIT")
        environment.removeValue(forKey: "GIT_OPTIONAL_LOCKS")
        if let path = LoginPath.value { environment["PATH"] = path }
        environment["TAB_PROJECT_PATH"] = repository
        environment["TAB_WORKTREE_ID"] = worktree.id.description
        environment["TAB_WORKTREE_PATH"] = worktree.directory.rawValue
        environment["TAB_WORKTREE_NAME"] = worktree.name
        environment["TAB_WORKTREE_BRANCH"] = branch
        for hook in hooks {
            let label = hook.name ?? hook.command
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw gitError("Worktree hooks timed out") }
            let output: ProcessOutput
            do {
                output = try ProcessRunner.run(shell, ["-c", hook.command], directory: worktree.directory.rawValue,
                                               environment: environment, timeout: remaining)
            } catch let failure as ProcessFailure {
                if case .timedOut = failure { throw gitError("Worktree hook failed (\(label)): it timed out") }
                throw gitError("Worktree hook failed (\(label)): \(failure)")
            }
            guard output.succeeded else {
                throw gitError("Worktree hook failed (\(label)): \(GitCommand.failure(output).message)")
            }
        }
    }

    /// The user's shell when it is an absolute path to a file, else `/bin/sh`.
    static func shell() -> String {
        guard let shell = ProcessInfo.processInfo.environment["SHELL"], shell.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: shell) else { return "/bin/sh" }
        return shell
    }

    private struct Config: Decodable {
        var setup: [Hook]?
        var teardown: [Hook]?
    }

    private enum Hook: Decodable {
        case command(String)
        case named(command: String, name: String?)

        private enum Keys: String, CodingKey { case command, name }

        init(from decoder: Decoder) throws {
            if let command = try? decoder.singleValueContainer().decode(String.self) {
                self = .command(command)
                return
            }
            let container = try decoder.container(keyedBy: Keys.self)
            self = .named(command: try container.decode(String.self, forKey: .command),
                          name: try container.decodeIfPresent(String.self, forKey: .name))
        }
    }

    static func load(_ path: String, teardown: Bool, project: Bool) throws -> [WorktreeHook] {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            if FileManager.default.fileExists(atPath: path) { throw gitError("Could not read \(path)") }
            return []
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxConfigBytes + 1)) ?? Data()
        if data.count > maxConfigBytes { throw gitError("Worktree hook configuration is too large") }
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw gitError("Invalid \(path): \(error.localizedDescription)")
        }
        let hooks = ((teardown ? config.teardown : config.setup) ?? []).compactMap { hook -> WorktreeHook? in
            let (command, name): (String, String?)
            switch hook {
            case .command(let value): (command, name) = (value, nil)
            case .named(let value, let label): (command, name) = (value, label)
            }
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : WorktreeHook(command: trimmed, name: name, project: project)
        }
        let invalid = hooks.count > maxHooks || hooks.contains { hook in
            hook.command.utf8.count > 16 * 1024 || hook.command.utf8.contains(0) || (hook.name?.utf8.count ?? 0) > 1024
        }
        if invalid { throw gitError("Worktree hook configuration exceeds the command limits") }
        return hooks
    }
}

/// The `PATH` a login shell sets up, so hooks find tools installed by the
/// user's shell profile even when the server started from the app.
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
