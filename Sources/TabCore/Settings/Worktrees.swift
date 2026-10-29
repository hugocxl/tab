import Foundation

/// Where new worktrees go: a path template, a parent folder, or neither for
/// the default location.
public struct WorktreeLocation: Codable, Equatable, Sendable {
    /// A path relative to the project folder (or `~`), with `{branch}` and
    /// optionally `{base-dir}` and `{project-name}`.
    public var pathTemplate: String
    /// A folder new worktrees go in, relative to the project folder or `~`.
    public var parentPath: String

    public static let suggestedTemplate = "../{base-dir}.{branch}"

    public init(pathTemplate: String = "", parentPath: String = "") {
        self.pathTemplate = pathTemplate
        self.parentPath = parentPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pathTemplate = try container.value(.pathTemplate, "")
        parentPath = try container.value(.parentPath, "")
    }

    /// A template must keep `{branch}` in the folder it resolves to, so two
    /// branches never share a folder.
    public func validate() throws {
        let template = pathTemplate.trimmingCharacters(in: .whitespaces)
        guard !template.isEmpty else { return }
        guard template.contains("{branch}") else {
            throw SettingsError("worktrees", "Path template must include {branch}.")
        }
        func resolve(_ branch: String) -> String {
            WorktreeSettings.normalize("/tab/project/" + template.replacingOccurrences(of: "{branch}", with: branch))
        }
        if resolve("tab-validation-a") == resolve("tab-validation-b") {
            throw SettingsError("worktrees", "Path template must keep {branch} in the resolved path.")
        }
    }

    /// Whether this choice defers to the default location.
    public var isDefault: Bool {
        pathTemplate.trimmingCharacters(in: .whitespaces).isEmpty
            && parentPath.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

public struct WorktreeSettings: Codable, Equatable, Sendable {
    public var defaultLocation: WorktreeLocation
    /// The location each project last chose, remembered per project.
    public var projects: [ProjectId: WorktreeLocation]

    public init(defaultLocation: WorktreeLocation = WorktreeLocation(), projects: [ProjectId: WorktreeLocation] = [:]) {
        self.defaultLocation = defaultLocation
        self.projects = projects
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultLocation = try container.value(.defaultLocation, WorktreeLocation())
        projects = try container.value(.projects, [:])
    }

    /// Where a new worktree named `name` on `branch` goes. `~` means `home`,
    /// the Home of the project's computer; `nil` is this computer's.
    public func directory(
        projectName: String,
        projectDirectory: String,
        location: WorktreeLocation,
        name: String,
        branch: String,
        home: String? = nil
    ) throws -> String {
        let inherited = location.isDefault
        let location = inherited ? defaultLocation : location
        try location.validate()
        let template = location.pathTemplate.trimmingCharacters(in: .whitespaces)
        if !template.isEmpty {
            let base = (projectDirectory as NSString).lastPathComponent
            let path = template
                .replacingOccurrences(of: "{project-name}", with: sanitizedComponent(projectName, fallback: "project"))
                .replacingOccurrences(of: "{base-dir}", with: sanitizedComponent(base, fallback: "project"))
                .replacingOccurrences(of: "{branch}", with: sanitizedComponent(branch, fallback: "branch"))
            return try Self.resolve(projectDirectory, path, home: home)
        }
        let trimmed = location.parentPath.trimmingCharacters(in: .whitespaces)
        var parent = try Self.resolve(projectDirectory, trimmed.isEmpty ? TabDirs.defaultWorktreeFolder : trimmed, home: home)
        if inherited {
            parent = (parent as NSString).appendingPathComponent(sanitizedComponent(projectName, fallback: "project"))
        }
        return (parent as NSString).appendingPathComponent(sanitizedComponent(name, fallback: "name"))
    }

    static func resolve(_ project: String, _ value: String, home: String?) throws -> String {
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
