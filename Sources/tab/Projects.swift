import Foundation
import TabClient
import TabCore
import TabProtocol

/// `project` and `worktree`.
enum Projects {
    static func run(_ command: CLIProject, client: ServerClient, target: Target, json: Bool) async throws {
        switch command {
        case .list:
            let projects = ordered(try await client.catalog().projects)
            Output.list(projects.map(record), columns: ["id", "name", "directory"], json: json)
        case .add(let directory, let name, let create, let reuse):
            var directory = try target.directory(directory)
            if create { try await makeDirectory(directory, client: client, target: target) }
            if !target.isRemote {
                guard Paths.isDirectory(directory), let canonical = Paths.canonical(directory) else {
                    throw CLIError("project directory must exist")
                }
                directory = canonical
            }
            let projects = try await client.catalog().projects
            if reuse, let existing = existing(projects, directory: directory, local: !target.isRemote) {
                return Output.record(record(existing), columns: ["id", "name"], json: json)
            }
            var project = ProjectDescriptor.new(directory: ServerPath(directory))
            if let name { project.name = name.trimmingCharacters(in: .whitespaces) }
            try await mutate(.create(project), client: client)
            Output.record(record(project), columns: ["id", "name"], json: json)
        case .rename(let selector, let name):
            let project = try await resolve(selector, client: client, target: target)
            try await mutate(.rename(project: project.id, name: name), client: client)
            Output.ok(json: json)
        case .delete(let selector):
            let project = try await resolve(selector, client: client, target: target)
            try await mutate(.delete(project.id), client: client)
            Output.ok(json: json)
        }
    }

    /// Home first, then each project followed by its worktrees.
    static func ordered(_ projects: [ProjectDescriptor]) -> [ProjectDescriptor] {
        let tops = Set(projects.filter { $0.parentId == nil }.map(\.id))
        var roots: [ProjectDescriptor] = []
        var children: [ProjectId: [ProjectDescriptor]] = [:]
        for project in projects {
            if let parent = project.parentId, tops.contains(parent) {
                children[parent, default: []].append(project)
            } else {
                roots.append(project)
            }
        }
        let homeFirst = roots.filter(\.home) + roots.filter { !$0.home }
        return homeFirst.flatMap { [$0] + (children[$0.id] ?? []) }
    }

    /// A project by ID, unique name (ignoring case) or directory.
    static func resolve(_ selector: String, client: ServerClient, target: Target) async throws -> ProjectDescriptor {
        try select(try await client.catalog().projects, selector, local: !target.isRemote)
    }

    static func select(_ projects: [ProjectDescriptor], _ selector: String, local: Bool) throws -> ProjectDescriptor {
        if let id = ProjectId(string: selector) {
            guard let project = projects.first(where: { $0.id == id }) else {
                throw CLIError("project not found: \(selector)")
            }
            return project
        }
        let path = local ? Paths.absolute(selector) : selector
        let canonical = local ? Paths.canonical(path) : nil
        let matches = projects.filter { project in
            project.name.caseInsensitiveCompare(selector) == .orderedSame
                || project.directory.rawValue == path
                || (canonical != nil && Paths.canonical(project.directory.rawValue) == canonical)
        }
        guard let found = matches.first else { throw CLIError("project not found: \(selector)") }
        guard matches.count == 1 else { throw CLIError("ambiguous project: \(selector); use its ID") }
        return found
    }

    /// The project already in `directory`, preferring one that isn't a worktree.
    static func existing(_ projects: [ProjectDescriptor], directory: String, local: Bool) -> ProjectDescriptor? {
        let matches = projects.filter { project in
            project.directory.rawValue == directory
                || (local && Paths.canonical(project.directory.rawValue) == directory)
        }
        return matches.first { $0.parentId == nil } ?? matches.first
    }

    /// The project for this computer's `folder`: one already there, or a new one.
    static func folderProject(_ folder: String, client: ServerClient) async throws -> ProjectDescriptor {
        let projects = try await client.catalog().projects
        if let project = existing(projects, directory: folder, local: true) { return project }
        let project = ProjectDescriptor.new(directory: ServerPath(folder))
        try await mutate(.create(project), client: client)
        return project
    }

    static func record(_ project: ProjectDescriptor) -> JSONValue {
        .object([
            "id": .string(project.id.description),
            "name": .string(project.name),
            "directory": .string(project.directory.rawValue),
            "home": .bool(project.home),
            "parentId": project.parentId.map { .string($0.description) } ?? .null,
            "kind": project.kind.map { .string($0.rawValue) } ?? .null,
        ])
    }

    static func mutate(_ mutation: ProjectMutation, client: ServerClient) async throws {
        do {
            try mutation.validate()
        } catch {
            throw CLIError("invalid project: \(error.rawValue)")
        }
        _ = try await client.mutateProject(ProjectIntent(mutation: mutation))
    }

    /// Creates `directory` and its parents; another computer's by running
    /// mkdir in its Home.
    static func makeDirectory(_ directory: String, client: ServerClient, target: Target) async throws {
        guard target.isRemote else {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            return
        }
        let home = try await client.catalogPage().home
        let result = try await client.exec(ExecRequest(job: 1, project: home, argv: ["mkdir", "-p", "--", directory],
                                                       timeoutMs: 30000))
        guard result.exitCode == 0, !result.timedOut, !result.cancelled else {
            throw CLIError("could not create \(directory): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: Worktrees

    static func worktree(_ command: CLIWorktree, client: ServerClient, target: Target, json: Bool) async throws {
        switch command {
        case .list(let selector):
            let root = try await root(selector, client: client, target: target)
            guard case .worktrees(let worktrees) = try await client.git(GitRequest(project: root.id, action: .worktrees))
            else { throw CLIError("unexpected worktree list reply") }
            Output.list(worktrees.map(worktreeRecord), columns: ["projectId", "branch", "directory"], json: json)
        case .create(let project, let name, let branch, let base, let directory, let hooks):
            let root = try await root(project, client: client, target: target)
            let folder = try await worktreeDirectory(directory, root: root, name: name, client: client, target: target)
            try await create(.create(project: ProjectId(), directory: ServerPath(folder), branch: branch, base: base),
                             root: root, name: name, hooks: hooks, client: client, json: json)
        case .checkoutPullRequest(let project, let number, let name, let directory, let hooks):
            let root = try await root(project, client: client, target: target)
            let fallback = name ?? "pr-\(number)"
            let folder = try await worktreeDirectory(directory, root: root, name: fallback, client: client,
                                                     target: target)
            try await create(.checkoutPullRequest(project: ProjectId(), directory: ServerPath(folder), number: number),
                             root: root, name: name, hooks: hooks, client: client, json: json)
        case .register(let project, let directory):
            let root = try await root(project, client: client, target: target)
            let action = WorktreeAction.register(project: ProjectId(), directory: ServerPath(try target.directory(directory)))
            guard case .project(let registered) = try await client.git(
                GitRequest(project: root.id, action: .worktree(WorktreeIntent(action: action))))
            else { throw CLIError("unexpected worktree registration reply") }
            Output.record(record(registered), columns: ["id", "name", "directory"], json: json)
        case .remove(let selector, let force, let hooks):
            let project = try await resolve(selector, client: client, target: target)
            guard project.parentId != nil else { throw CLIError("project is not a worktree") }
            guard case .removal(let expected) = try await client.git(GitRequest(project: project.id,
                                                                               action: .inspectRemoval))
            else { throw CLIError("unexpected worktree inspection reply") }
            if expected.dirty && !force {
                throw CLIError("worktree has uncommitted changes; use --force to discard them")
            }
            let options = WorktreeOptions(hooks: hooks ? try await approve(project.id, teardown: true, client: client) : nil)
            _ = try await client.git(GitRequest(project: project.id, action: .worktree(
                WorktreeIntent(action: .remove(expected: expected), options: options))))
            Output.ok(json: json)
        }
    }

    /// The project a worktree belongs to: `selector`'s parent if it is a worktree.
    static func root(_ selector: String, client: ServerClient, target: Target) async throws -> ProjectDescriptor {
        let projects = try await client.catalog().projects
        let project = try select(projects, selector, local: !target.isRemote)
        guard let parent = project.parentId else { return project }
        guard let root = projects.first(where: { $0.id == parent }) else {
            throw CLIError("the parent of \(selector) no longer exists")
        }
        return root
    }

    static func worktreeDirectory(_ directory: String?, root: ProjectDescriptor, name: String, client: ServerClient,
                                  target: Target) async throws -> String {
        if let directory { return try target.directory(directory) }
        return try await defaultDirectory(root: root, name: name, client: client, target: target)
    }

    /// `~/.tab/worktrees/<project>/<name>` in the server's home folder.
    static func defaultDirectory(root: ProjectDescriptor, name: String, client: ServerClient,
                                 target: Target) async throws -> String {
        let home: String
        if target.isRemote {
            let projects = try await client.catalog().projects
            guard let serverHome = projects.first(where: \.home)?.directory.rawValue else {
                throw CLIError("the server has no Home project; pass --directory")
            }
            home = serverHome
        } else {
            home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        }
        let base = TabDirs.expandHome(TabDirs.defaultWorktreeFolder, home: home)
        let folder = name.replacingOccurrences(of: "/", with: "-")
        return ((base as NSString).appendingPathComponent(root.name) as NSString).appendingPathComponent(folder)
    }

    static func create(_ action: WorktreeAction, root: ProjectDescriptor, name: String?, hooks: Bool,
                       client: ServerClient, json: Bool) async throws {
        // A pull request's worktree starts under the branch name the server
        // prepares, since the server checks out that name; it is renamed once
        // it exists.
        let requested: String? = if case .checkoutPullRequest = action { nil } else { name }
        let options = WorktreeOptions(name: requested,
                                      hooks: hooks ? try await approve(root.id, teardown: false, client: client) : nil)
        var project: ProjectDescriptor
        var failure: String?
        switch try await client.git(GitRequest(project: root.id, action: .worktree(WorktreeIntent(action: action,
                                                                                                  options: options)))) {
        case .project(let created): project = created
        case .worktreeSetupFailed(let created, let message):
            project = created
            failure = message
        default: throw CLIError("unexpected worktree creation reply")
        }
        if requested == nil, let name, name != project.name {
            try await mutate(.rename(project: project.id, name: name), client: client)
            project.name = name
        }
        Output.record(record(project), columns: ["id", "name", "directory"], json: json)
        if let failure { throw CLIError("worktree created, but setup failed: \(failure)") }
    }

    /// The setup or teardown commands configured for `project`, printed as
    /// they are approved.
    static func approve(_ project: ProjectId, teardown: Bool, client: ServerClient) async throws -> [WorktreeHook] {
        guard case .worktreeHooks(let hooks) = try await client.git(GitRequest(project: project,
                                                                              action: .worktreeHooks(teardown: teardown)))
        else { throw CLIError("unexpected worktree hooks reply") }
        for hook in hooks { Output.error("\(teardown ? "teardown" : "setup"): \(hook.command)") }
        return hooks
    }

    static func worktreeRecord(_ worktree: GitWorktree) -> JSONValue {
        .object([
            "projectId": worktree.registered.map { .string($0.description) } ?? .null,
            "branch": worktree.branch.map(JSONValue.string) ?? .null,
            "directory": .string(worktree.directory.rawValue),
            "head": worktree.head.map(JSONValue.string) ?? .null,
            "primary": .bool(worktree.primary),
            "locked": .bool(worktree.locked),
            "detached": .bool(worktree.detached),
            "prunable": .bool(worktree.prunable),
        ])
    }
}
