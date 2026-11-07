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
