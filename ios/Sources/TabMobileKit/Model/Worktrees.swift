import Foundation
import TabProtocol

/// A worktree made, or found, to open a new tab in.
public struct QuickWorktree: Sendable {
    public var project: ProjectId
    /// Approved setup commands, as one line for the new terminal to type.
    public var setup: String?
}

/// Creating worktrees the way the desktop's New Terminal and New Agent in
/// Project pages do, in the server's default worktree folder.
extension ServerModel {
    /// A Git request about `project`.
    public func git(_ project: ProjectId, _ action: GitAction) async throws -> GitReply {
        guard let client else { throw ConnectError.failed("Not connected to \(server.name).") }
        return try await client.git(GitRequest(project: project, action: action))
    }

    /// Makes a worktree of `repository` in one step: branch `name` from
    /// `base` (the default branch when nil), fetched from its remote first when
    /// `fromRemote`. `#482` checks out that pull request instead. An existing
    /// branch is checked out, or its worktree reused when one already has it;
    /// an empty name gets a short random one. Setup commands run in the new
    /// terminal once `approve` allows them.
    public func quickWorktree(repository: ProjectId, name typed: String, base chosen: String?, fromRemote: Bool,
                              approve: ([WorktreeHook]) async -> Bool) async throws -> QuickWorktree {
        guard let root = project(repository) else { throw ConnectError.failed("That project is gone.") }
        let action: WorktreeAction
        let options: WorktreeOptions?
        let branch: String
        if let number = Self.pullRequestNumber(typed) {
            branch = "pr-\(number)"
            action = .checkoutPullRequest(project: ProjectId(), directory: try worktreeDirectory(root, name: branch), number: number)
            options = nil
        } else {
            guard case .branches(let branches) = try await git(repository, .branches) else {
                throw ConnectError.failed("The Mac gave an unexpected reply.")
            }
            let name = Self.quickBranchName(typed)
            branch = Self.worktreeName(name, taken: Set(branches.map(\.name)))
            let existing = branches.first { $0.name == branch }
            if existing?.checkedOut == true {
                return QuickWorktree(project: try await worktree(of: repository, branch: branch), setup: nil)
            }
            let base = existing == nil ? chosen ?? Self.defaultBase(branches) : nil
            action = .create(project: ProjectId(), directory: try worktreeDirectory(root, name: branch), branch: branch, base: base)
            options = WorktreeOptions(name: branch, fetchBase: base != nil && fromRemote ? true : nil)
        }
        let hooks = try await setupHooks(repository, approve: approve)
        let reply = try await git(repository, .worktree(WorktreeIntent(action: action, options: options)))
        guard case .project(let created) = reply else { throw ConnectError.failed("The Mac gave an unexpected reply.") }
        try await readCatalog()
        guard project(created.id) != nil else {
            throw ConnectError.failed("“\(created.name)” was created, but the Mac hasn't listed it yet.")
        }
        let setup = hooks.map { Self.setupCommand($0, worktree: created, repository: root.directory, branch: branch) }
        return QuickWorktree(project: created.id, setup: setup)
    }

    /// The setup commands a new worktree runs, once approved; nil for none.
    private func setupHooks(_ repository: ProjectId, approve: ([WorktreeHook]) async -> Bool) async throws -> [WorktreeHook]? {
        guard case .worktreeHooks(let hooks) = try await git(repository, .worktreeHooks(teardown: false)), !hooks.isEmpty else {
            return nil
        }
        return await approve(hooks) ? hooks : nil
    }

    /// The worktree that has `branch` checked out, listed as a project first
    /// when Tab doesn't show it yet.
    private func worktree(of repository: ProjectId, branch: String) async throws -> ProjectId {
        guard case .worktrees(let worktrees) = try await git(repository, .worktrees),
              let found = worktrees.first(where: { $0.branch == branch }) else {
            throw ConnectError.failed("Branch “\(branch)” is checked out somewhere Tab can't find.")
        }
        if found.primary { return repository }
        if let registered = found.registered, project(registered) != nil { return registered }
        let intent = WorktreeIntent(action: .register(project: ProjectId(), directory: found.directory))
        guard case .project(let added) = try await git(repository, .worktree(intent)) else {
            throw ConnectError.failed("The Mac gave an unexpected reply.")
        }
        try await readCatalog()
        return added.id
    }

    /// `~/.tab/worktrees/<project>/<name>` in the server's home folder, as the
    /// desktop and `tab` place worktrees by default.
    func worktreeDirectory(_ repository: ProjectDescriptor, name: String) throws -> ServerPath {
        guard let folder = home.flatMap(project)?.directory.rawValue else {
            throw ConnectError.failed("Not connected to \(server.name) yet.")
        }
        return ServerPath([folder, ".tab/worktrees", Self.folderName(repository.name, fallback: "project"),
                           Self.folderName(name, fallback: "name")].joined(separator: "/"))
    }

    // MARK: Names

    /// What a typed name becomes as a branch: trimmed, with spaces as `-`.
    /// Slashes stay, so `feat/login` names that branch.
    public static func quickBranchName(_ typed: String) -> String {
        typed.split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// `#482` as a pull request number.
    public static func pullRequestNumber(_ typed: String) -> UInt64? {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#"), let number = UInt64(trimmed.dropFirst()), number > 0 else { return nil }
        return number
    }

    /// The branch new worktrees start from unless one is chosen.
    public static func defaultBase(_ branches: [GitBranch]) -> String? {
        branches.first(where: \.isDefault)?.name ?? branches.first(where: \.current)?.name
    }

    /// `name`, or for an empty one a short random name no branch has.
    static func worktreeName(_ name: String, taken: Set<String>) -> String {
        guard name.isEmpty else { return name }
        var random: String
        repeat { random = "wt-" + UUID().uuidString.prefix(4).lowercased() } while taken.contains(random)
        return random
    }

    /// A name made safe as one folder, as Tab names worktree folders.
    static func folderName(_ value: String, fallback: String) -> String {
        let replaced = String(value.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
        let joined = replaced.split(separator: "-").joined(separator: "-")
        return ["", ".", ".."].contains(joined) ? fallback : joined
    }

    /// One line, typed into whatever shell the terminal runs, that runs
    /// `hooks` in order as the server would: each in the user's shell with the
    /// variables server hooks get, stopping at the first failure. The script
    /// travels as base64 for `/bin/sh` to decode, so neither the login shell's
    /// quoting nor its line editor touches it. The desktop types the same.
    static func setupCommand(_ hooks: [WorktreeHook], worktree: ProjectDescriptor, repository: ServerPath, branch: String) -> String {
        let variables = [
            "TAB_PROJECT_PATH=\(repository.rawValue)", "TAB_WORKTREE_ID=\(worktree.id.description)",
            "TAB_WORKTREE_PATH=\(worktree.directory.rawValue)", "TAB_WORKTREE_NAME=\(worktree.name)",
            "TAB_WORKTREE_BRANCH=\(branch)",
        ]
        let script = hooks.map { "\"${SHELL:-/bin/sh}\" -c " + shellQuoted($0.command) }.joined(separator: " && ")
        let decode = #"eval "$(printf %s "$1" | base64 -D)""#
        let words = ["env"] + variables + ["/bin/sh", "-c", decode, "tab-setup", Data(script.utf8).base64EncodedString()]
        return words.map(shellQuoted).joined(separator: " ")
    }

    /// `word` as one POSIX shell word: bare when it is plain, else single-quoted.
    static func shellQuoted(_ word: String) -> String {
        let plain = !word.isEmpty && word.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "@%+=:,./_-".unicodeScalars.contains($0)
        }
        return plain ? word : "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// What closing a worktree's last panes would remove, for the user to decide
/// whether its folder goes too. The inspection binds the removal to the folder
/// as it is now, so the server refuses it if the worktree changed meanwhile.
public struct WorktreeClosing: Sendable {
    public var project: ProjectDescriptor
    public var removal: WorktreeRemoval
    /// Teardown commands removing it runs; nil for none.
    public var teardown: [WorktreeHook]?
    /// Why the teardown commands couldn't be listed; removing then runs none.
    public var teardownFailure: String?

    /// What removing the worktree loses, as the desktop says it when closing one.
    public var message: String {
        let name = project.name
        let kept = removal.branch.map { " Its branch “\($0)” is kept." } ?? ""
        var message = removal.dirty
            ? "“\(name)” has uncommitted changes. Removing the worktree discards them and deletes its files.\(kept)"
            : "Removing “\(name)” deletes the worktree and its files.\(kept)"
        let lost = (removal.ignoredPaths ?? []).filter { !Self.isRebuildable($0) }
        if !lost.isEmpty {
            message += "\n\nFiles Git ignores are deleted too: " + lost.prefix(5).joined(separator: ", ")
                + (lost.count > 5 ? " and more." : ".")
        } else if removal.ignoredPaths == nil {
            message += "\n\nFiles Git ignores, if any, are deleted too."
        }
        if removal.branch == nil { message += "\n\nIt isn't on a branch, so commits made in it may be lost." }
        if let teardown, !teardown.isEmpty {
            message += "\n\nTeardown commands that will run:\n" + teardown.map { "• " + $0.command }.joined(separator: "\n")
        } else if let teardownFailure {
            message += "\n\nTeardown commands could not be loaded, so none will run: \(teardownFailure)"
        }
        return message
    }

    /// Folders that dependency managers and builds fill again, which the
    /// message leaves out, as the desktop does.
    static let rebuildableFolders: Set<String> = [
        "node_modules", ".build", "dist", "target", ".next", ".nuxt", ".turbo", ".cache",
        ".parcel-cache", "DerivedData", ".gradle", "Pods", ".venv", "venv", "__pycache__",
        ".pytest_cache", ".mypy_cache", ".swiftpm", ".dart_tool",
    ]

    /// An ignored path as `git status` lists it: a whole folder ends in `/`.
    static func isRebuildable(_ path: String) -> Bool {
        guard path.hasSuffix("/") else { return false }
        return rebuildableFolders.contains(String(path.dropLast().split(separator: "/").last ?? ""))
    }
}

/// Closing a worktree's last panes, as the desktop does: it asks whether the
/// worktree and its files go too, and never removes them without asking.
extension ServerModel {
    /// The worktree that closing `panes` leaves with no pane open; nil when
    /// they aren't in a worktree, or other panes of it stay open.
    public func worktreeClosed(by panes: Set<PaneId>) -> ProjectDescriptor? {
        guard let board, !panes.isEmpty,
              let entry = board.projects.first(where: { $0.tabs.contains { $0.panes.contains { panes.contains($0.id) } } }),
              let project = project(entry.project) else { return nil }
        return Self.closesWorktree(project, tabs: entry.tabs, closing: panes) ? project : nil
    }

    /// The worktree that closing `tab` leaves with no pane open.
    public func worktreeClosed(byClosing tab: TabId) -> ProjectDescriptor? {
        guard let found = self.tab(tab) else { return nil }
        return worktreeClosed(by: Set(found.tab.panes.map(\.id)))
    }

    static func closesWorktree(_ project: ProjectDescriptor, tabs: [Tab], closing: Set<PaneId>) -> Bool {
        guard !project.home, project.kind == .worktree else { return false }
        let open = tabs.flatMap(\.panes).map(\.id)
        return !open.isEmpty && open.allSatisfy(closing.contains)
    }

    /// Asks the server what removing `project`'s worktree would lose.
    public func inspectWorktreeClosing(_ project: ProjectDescriptor) async throws -> WorktreeClosing {
        guard case .removal(let removal) = try await git(project.id, .inspectRemoval) else {
            throw ConnectError.failed("The Mac gave an unexpected reply.")
        }
        var closing = WorktreeClosing(project: project, removal: removal)
        do {
            if case .worktreeHooks(let hooks) = try await git(project.id, .worktreeHooks(teardown: true)), !hooks.isEmpty {
                closing.teardown = hooks
            }
        } catch {
            closing.teardownFailure = error.localizedDescription
        }
        return closing
    }

    /// Removes the inspected worktree and its files, running the teardown
    /// commands the user saw; its branch stays. The server ends its
    /// terminals and closes its tabs.
    public func removeWorktree(_ closing: WorktreeClosing) async throws {
        let intent = WorktreeIntent(action: .remove(expected: closing.removal), options: WorktreeOptions(hooks: closing.teardown))
        _ = try await git(closing.project.id, .worktree(intent))
        try? await readCatalog()
    }
}
