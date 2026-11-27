import Foundation
import Observation
import TabProtocol

/// The New Tab sheet's choices, as the desktop's New Terminal and New Agent
/// in Project pages make them: what opens, on which Mac, in which project or
/// worktree, and for a Git project whether in its checkout or a new worktree.
@MainActor
@Observable
public final class NewTabForm {
    /// Where in a repository the tab opens.
    public enum Checkout: String, Sendable {
        /// The chosen project's own folder.
        case current
        /// A new worktree of its repository.
        case worktree
    }

    /// The chosen location's repository, read once per sheet.
    public enum Repository: Equatable, Sendable {
        case loading
        /// Home, or a folder without Git.
        case none
        /// `remote` is the one its checkout tracks, for naming the start point.
        case loaded(root: ProjectId, branches: [GitBranch], remote: String?)
        case failed(String)
    }

    public private(set) var server: ServerModel
    public var kind: MobilePaneKind
    public private(set) var location: ProjectId
    public var checkout: Checkout
    /// The new worktree's branch as typed; `#482` checks out that pull request.
    public var name = ""
    /// The branch a new worktree starts from; nil for the default branch.
    public var base: String?
    /// Start a new worktree from the base's remote copy, fetched first.
    public var fromRemote = true
    public private(set) var repository: Repository = .none
    public private(set) var isCreating = false
    public private(set) var failure: String?
    @ObservationIgnored private var repositories: [ProjectId: Repository] = [:]

    /// A form for `server`'s tab of `kind` in `location`, Home when nil or
    /// gone; nil while the server hasn't reported its projects.
    public init?(server: ServerModel, kind: MobilePaneKind, location: ProjectId?, checkout: Checkout) {
        guard let home = server.home else { return nil }
        self.server = server
        self.kind = kind
        self.location = location.flatMap(server.project)?.id ?? home
        self.checkout = checkout
        loadRepository()
    }

    // MARK: Choosing

    public func choose(server next: ServerModel) {
        guard next !== server, let home = next.home else { return }
        server = next
        if case .simulator = kind, !next.sharesSimulators { kind = .terminal }
        choose(location: home)
    }

    public func choose(location next: ProjectId) {
        guard next != location else { return }
        location = next
        base = nil
        failure = nil
        loadRepository()
    }

    /// Projects and their worktrees, each repository followed by its own,
    /// then Home: the desktop's New in Project order.
    public var locations: [ProjectDescriptor] {
        let projects = server.projects
        var ordered: [ProjectDescriptor] = []
        for parent in projects where !parent.home && parent.parentId == nil {
            ordered.append(parent)
            ordered += projects.filter { $0.parentId == parent.id }
        }
        // Worktrees whose repository the catalog doesn't list.
        ordered += projects.filter { project in
            !project.home && project.parentId.map { parent in !projects.contains { $0.id == parent } } == true
        }
        return ordered + projects.filter(\.home)
    }

    public var locationProject: ProjectDescriptor? { server.project(location) }

    // MARK: Reading the form

    /// A new worktree is made: the location is in a repository and the user chose one.
    public var makesWorktree: Bool {
        guard checkout == .worktree, case .loaded = repository else { return false }
        return true
    }

    public var pullRequest: UInt64? { ServerModel.pullRequestNumber(name) }

    public var branches: [GitBranch] {
        guard case .loaded(_, let branches, _) = repository else { return [] }
        return branches
    }

    /// The branch the new worktree starts from, before the remote.
    public var effectiveBase: String? { base ?? ServerModel.defaultBase(branches) }

    /// What a new worktree starts from, as the desktop names it: the base,
    /// on its remote unless the user chose the local branch.
    public var startLabel: String? {
        guard let base = effectiveBase else { return nil }
        guard fromRemote, case .loaded(_, _, let remote?) = repository else { return base }
        return "\(remote)/\(base)"
    }

    /// The typed branch, which exists already and is checked out as is.
    public var existingBranch: GitBranch? {
        let name = ServerModel.quickBranchName(name)
        return name.isEmpty ? nil : branches.first { $0.name == name }
    }

    /// Whether the base and remote choices apply to what's typed.
    public var choosesBase: Bool { makesWorktree && pullRequest == nil && existingBranch == nil }

    public var canCreate: Bool {
        guard !isCreating, locationProject != nil else { return false }
        guard checkout == .worktree else { return true }
        switch repository {
        case .loading: return false
        case .failed: return false
        case .none, .loaded: return true
        }
    }

    /// One sentence saying what Create does.
    public var summary: String {
        let what = switch kind {
        case .terminal: "a terminal"
        case .agent(let provider): provider.name
        case .simulator: "a simulator"
        }
        guard makesWorktree else {
            let place = locationProject.map { $0.home ? "Home" : ServerModel.abbreviate($0.directory) } ?? "Home"
            return "Opens \(what) in \(place)."
        }
        if let pullRequest { return "Checks out pull request #\(pullRequest) in a new worktree and opens \(what) there." }
        if let existingBranch {
            return existingBranch.checkedOut
                ? "Opens \(what) in the worktree that has “\(existingBranch.name)” checked out."
                : "Checks out the existing branch “\(existingBranch.name)” in a new worktree and opens \(what) there."
        }
        let name = ServerModel.quickBranchName(name)
        let branch = name.isEmpty ? "a new branch with a short random name" : "the new branch “\(name)”"
        let start = startLabel.map { " from \($0)" } ?? ""
        return "Creates a worktree on \(branch)\(start), in ~/.tab/worktrees, and opens \(what) there."
    }

    // MARK: Creating

    /// Opens the tab, making its worktree first when chosen. `approve` asks
    /// before setup commands run. Nil, with `failure` set, when it fails.
    public func create(size: Size, approve: @escaping ([WorktreeHook]) async -> Bool) async -> TabId? {
        guard canCreate else { return nil }
        isCreating = true
        failure = nil
        defer { isCreating = false }
        do {
            guard makesWorktree, case .loaded(let root, _, _) = repository else {
                return try server.newTab(kind, in: location, size: size)
            }
            let made = try await server.quickWorktree(repository: root, name: name, base: base, fromRemote: fromRemote,
                                                      approve: approve)
            return try server.newTab(kind, in: made.project, setup: made.setup, size: size)
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    // MARK: Repository

    private func loadRepository() {
        guard let project = locationProject, !project.home else {
            repository = .none
            return
        }
        let root = project.parentId ?? project.id
        if let known = repositories[root] {
            repository = known
            return
        }
        repository = .loading
        let server = server
        let location = location
        Task {
            let read = await Self.readRepository(root, on: server)
            if case .failed = read {} else { repositories[root] = read }
            guard self.server === server, self.location == location else { return }
            repository = read
        }
    }

    private static func readRepository(_ root: ProjectId, on server: ServerModel) async -> Repository {
        do {
            guard case .summary(let summary?) = try await server.git(root, .summary) else { return .none }
            guard case .branches(let branches) = try await server.git(root, .branches) else { return .none }
            let remote = summary.upstream.flatMap { upstream in upstream.firstIndex(of: "/").map { String(upstream[..<$0]) } }
            return .loaded(root: root, branches: branches, remote: remote)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
