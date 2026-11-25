import Foundation
import TabProtocol

/// The hand-edited `settings.json` in `~/.config/tab`, the user's for every
/// project, and in a project's `.config/tab`, committed with it. Not the
/// app's own `settings.json` in its profile folder.
///
/// Every checkout Tab opens is a branch: the project's folder is its default
/// branch, and each worktree is another branch. Every key is optional:
///
/// ```json
/// {
///   "defaultBranch": {
///     "name": "main",
///     "open": ["npm ci"],
///     "close": [{ "name": "Stop services", "command": "docker compose down" }]
///   },
///   "worktrees": {
///     "location": "../{base-dir}.{branch}",
///     "open": ["npm ci", "cp \"$TAB_PROJECT_PATH/.env\" ."],
///     "close": ["docker compose down"]
///   }
/// }
/// ```
///
/// The project's `name` and `location` win over the user's. Commands add
/// up: `open` runs the user's first, `close` the project's first. They run
/// on their own, without asking.
public struct TabConfig: Equatable, Sendable {
    /// Where a project keeps its file, relative to its folder.
    public static let projectFile = ".config/tab/settings.json"
    /// Where new worktrees go unless a `location` says otherwise.
    public static let defaultWorktreeLocation = "~/.tab/worktrees/{project-name}/{branch}"
    public static let maxBytes = 1024 * 1024
    public static let maxCommands = 128

    /// One kind of branch: its own folder, or worktrees.
    public struct Section: Equatable, Sendable {
        /// The default branch's name; only `defaultBranch` has it.
        public var name: String?
        /// Where new worktrees go; only `worktrees` has it.
        public var location: String?
        public var commands = BranchCommands()

        public init(name: String? = nil, location: String? = nil, commands: BranchCommands = BranchCommands()) {
            self.name = name
            self.location = location
            self.commands = commands
        }
    }

    public var defaultBranch = Section()
    public var worktrees = Section()

    public init(defaultBranch: Section = Section(), worktrees: Section = Section()) {
        self.defaultBranch = defaultBranch
        self.worktrees = worktrees
    }

    /// The user's file: `$XDG_CONFIG_HOME/tab/settings.json`, else
    /// `~/.config/tab/settings.json`.
    public static func userFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        TabDirs.configHome(environment: environment).appendingPathComponent("settings.json", isDirectory: false)
    }

    /// The file inside the project folder `directory`.
    public static func projectFile(in directory: String) -> String {
        (directory as NSString).appendingPathComponent(projectFile)
    }

    // MARK: Reading

    /// The project at `directory`'s settings over the user's file.
    public static func branchSettings(projectDirectory directory: String, userFile: URL = userFile()) throws -> BranchSettings {
        merge(user: try load(userFile.path, project: false), project: try load(projectFile(in: directory), project: true))
    }

    /// The file at `path`; empty when it is missing. `project` marks its
    /// commands as the project's.
    public static func load(_ path: String, project: Bool) throws -> TabConfig {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            if FileManager.default.fileExists(atPath: path) { throw SettingsError(path, "could not be read") }
            return TabConfig()
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        if data.count > maxBytes { throw SettingsError(path, "is larger than 1 MB") }
        return try parse(data, path: path, project: project)
    }

    /// Settings from JSON; an empty document has none. Unknown keys are
    /// ignored, so files written for newer builds still load.
    public static func parse(_ data: Data, path: String = "settings.json", project: Bool) throws -> TabConfig {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return TabConfig() }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw SettingsError(path, SettingsJSON.describe(error))
        }
        var config = TabConfig()
        if let section = file.defaultBranch {
            if let name = section.name {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard isBranchName(trimmed) else { throw SettingsError(path, "defaultBranch.name is not a branch name") }
                config.defaultBranch.name = trimmed
            }
            config.defaultBranch.commands = try commands(section.open, section.close, project: project,
                                                         path: path, key: "defaultBranch")
        }
        if let section = file.worktrees {
            if let location = section.location {
                let trimmed = location.trimmingCharacters(in: .whitespaces)
                do {
                    try validateLocation(trimmed)
                } catch let error as SettingsError {
                    throw SettingsError(path, "worktrees.location: " + error.message)
                }
                config.worktrees.location = trimmed.isEmpty ? nil : trimmed
            }
            config.worktrees.commands = try commands(section.open, section.close, project: project,
                                                     path: path, key: "worktrees")
        }
        return config
    }

    /// `project` over `user`: values from the project, commands from both.
    public static func merge(user: TabConfig, project: TabConfig) -> BranchSettings {
        func combine(_ user: BranchCommands, _ project: BranchCommands) -> BranchCommands {
            BranchCommands(open: user.open + project.open, close: project.close + user.close)
        }
        return BranchSettings(
            defaultBranch: project.defaultBranch.name ?? user.defaultBranch.name,
            defaultBranchCommands: combine(user.defaultBranch.commands, project.defaultBranch.commands),
            worktreeLocation: project.worktrees.location ?? user.worktrees.location,
            worktreeCommands: combine(user.worktrees.commands, project.worktrees.commands)
        )
    }

    // MARK: Worktree location

    /// A location must keep `{branch}` in the folder it resolves to, so two
    /// branches never share a folder. Empty means the default.
    public static func validateLocation(_ template: String) throws {
        let template = template.trimmingCharacters(in: .whitespaces)
        guard !template.isEmpty else { return }
        guard template.contains("{branch}") else { throw SettingsError("worktrees.location", "must include {branch}") }
        func resolve(_ branch: String) -> String {
            normalize("/tab/project/" + template.replacingOccurrences(of: "{branch}", with: branch))
        }
        if resolve("tab-validation-a") == resolve("tab-validation-b") {
            throw SettingsError("worktrees.location", "must keep {branch} in the resolved path")
        }
    }

    /// Where a new worktree on `branch` goes for `location`, nil for the
    /// default. Relative paths start in the project folder; `~` is `home`,
    /// the Home of the project's computer, or this computer's when nil.
    public static func worktreeDirectory(location: String?, projectName: String, projectDirectory: String,
                                         branch: String, home: String? = nil) throws -> String {
        let trimmed = location?.trimmingCharacters(in: .whitespaces) ?? ""
        let template = trimmed.isEmpty ? defaultWorktreeLocation : trimmed
        try validateLocation(template)
        let base = (projectDirectory as NSString).lastPathComponent
        let path = template
            .replacingOccurrences(of: "{project-name}", with: sanitizedComponent(projectName, fallback: "project"))
            .replacingOccurrences(of: "{base-dir}", with: sanitizedComponent(base, fallback: "project"))
            .replacingOccurrences(of: "{branch}", with: sanitizedComponent(branch, fallback: "branch"))
        return resolve(projectDirectory, path, home: home)
    }

    /// The `worktrees.location` in the user's file at `url`, nil when unset.
    public static func worktreeLocation(in url: URL) throws -> String? {
        try load(url.path, project: false).worktrees.location
    }

    /// Sets `worktrees.location` in the user's file at `url`, or removes it
    /// for nil or empty, keeping everything else in the file.
    public static func setWorktreeLocation(_ location: String?, in url: URL) throws {
        let value = location?.trimmingCharacters(in: .whitespaces) ?? ""
        try validateLocation(value)
        var document = try SettingsDocument.read(url)
        if document.root["worktrees"] != nil && !(document.root["worktrees"] is [String: Any]) {
            throw SettingsError(url.path, "worktrees must be an object")
        }
        var section = document.root["worktrees"] as? [String: Any] ?? [:]
        section["location"] = value.isEmpty ? nil : value
        document.root["worktrees"] = section.isEmpty ? nil : section
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw SettingsError(url.path, error.localizedDescription)
        }
        try document.write(to: url)
    }

    // MARK: Parsing

    private struct File: Decodable {
        var defaultBranch: SectionFile?
        var worktrees: SectionFile?
    }

    private struct SectionFile: Decodable {
        var name: String?
        var location: String?
        var open: [CommandFile]?
        var close: [CommandFile]?
    }

    /// A command as a string, or as `{ "name": …, "command": … }`.
    private struct CommandFile: Decodable {
        var command: String
        var name: String?

        private enum Keys: String, CodingKey { case command, name }

        init(from decoder: Decoder) throws {
            if let command = try? decoder.singleValueContainer().decode(String.self) {
                self.command = command
                return
            }
            let container = try decoder.container(keyedBy: Keys.self)
            command = try container.decode(String.self, forKey: .command)
            name = try container.decodeIfPresent(String.self, forKey: .name)
        }
    }

    private static func commands(_ open: [CommandFile]?, _ close: [CommandFile]?, project: Bool,
                                 path: String, key: String) throws -> BranchCommands {
        func list(_ entries: [CommandFile]?, _ event: String) throws -> [BranchCommand] {
            let commands = (entries ?? []).compactMap { entry -> BranchCommand? in
                let command = entry.command.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = entry.name?.trimmingCharacters(in: .whitespaces)
                return command.isEmpty ? nil : BranchCommand(command: command, name: name?.isEmpty == false ? name : nil,
                                                             project: project)
            }
            let invalid = commands.count > maxCommands || commands.contains { command in
                command.command.utf8.count > 16 * 1024 || command.command.utf8.contains(0)
                    || (command.name?.utf8.count ?? 0) > 1024
            }
            if invalid { throw SettingsError(path, "\(key).\(event) exceeds the command limits") }
            return commands
        }
        return BranchCommands(open: try list(open, "open"), close: try list(close, "close"))
    }

    /// Plain enough to pass to Git as a branch without being read as an option.
    private static func isBranchName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && name.utf8.count <= 256
            && !name.contains { $0.isWhitespace || $0.isNewline || $0 == "\0" }
    }

    /// `value` as an absolute path: relative to the folder `project`, `~`
    /// meaning `home` (this computer's Home when nil), `.` and `..` resolved.
    public static func resolve(_ project: String, _ value: String, home: String?) -> String {
        let path: String
        if value == "~" || value.hasPrefix("~/") {
            let home = home ?? ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            path = home + "/" + value.dropFirst(value == "~" ? 1 : 2)
        } else if value.hasPrefix("/") {
            path = value
        } else {
            path = project + "/" + value
        }
        return normalize(path)
    }

    /// Resolves `.` and `..` without touching the disk.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// `value` as one safe path component: anything but letters, digits, `.`, `_`
/// and `-` becomes `-`, runs of `-` collapse, and an empty, `.` or `..`
/// result becomes `fallback`.
public func sanitizedComponent(_ value: String, fallback: String) -> String {
    let replaced = String(value.map { character -> Character in
        character.isLetter || character.isNumber || "._-".contains(character) ? character : "-"
    })
    let joined = replaced.split(separator: "-").joined(separator: "-")
    return ["", ".", ".."].contains(joined) ? fallback : joined
}
