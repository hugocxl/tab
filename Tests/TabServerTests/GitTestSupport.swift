import Foundation
import XCTest
@testable import TabServer
import TabProtocol

/// A catalog in memory for Git service tests.
final class GitTestCatalog: WorktreeCatalog, @unchecked Sendable {
    private let lock = NSLock()
    private var projects: [ProjectId: ProjectDescriptor] = [:]
    private(set) var endedSessions: [(ProjectId, String)] = []
    let homeProject = ProjectId()

    func add(_ project: ProjectDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        projects[project.id] = project
    }

    func projectPath(_ id: ProjectId) throws -> String {
        try project(id).directory.rawValue
    }

    func project(_ id: ProjectId) throws -> ProjectDescriptor {
        lock.lock()
        defer { lock.unlock() }
        guard let project = projects[id] else { throw ErrorCode.unknownProject }
        return project
    }

    func contains(_ id: ProjectId) -> Bool {
        (try? project(id)) != nil
    }

    func children(of parent: ProjectId) -> [ProjectDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return projects.values.filter { $0.parentId == parent }
    }

    func addWorktreeProject(_ project: ProjectDescriptor) throws {
        lock.lock()
        defer { lock.unlock() }
        if let existing = projects[project.id], existing != project {
            throw ServiceError(.badRequest, "Worktree identity already exists")
        }
        projects[project.id] = project
    }

    func endSessions(project: ProjectId, directory: String) throws {
        lock.lock()
        defer { lock.unlock() }
        endedSessions.append((project, directory))
    }

    func removeWorktreeProject(_ project: ProjectId) throws {
        lock.lock()
        defer { lock.unlock() }
        projects.removeValue(forKey: project)
    }
}

/// Records events sent by services.
final class GitTestEvents: ServiceEvents, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [(EventBody, ClientId)] = []
    var onSend: ((EventBody, ClientId) -> Void)?

    func broadcast(_ event: EventBody) {}

    func send(_ event: EventBody, to client: ClientId) {
        lock.lock()
        sent.append((event, client))
        let callback = onSend
        lock.unlock()
        callback?(event, client)
    }
}

enum GitTestError: Error { case failed(String) }

/// A temporary repository registered as a project of a Git service.
final class GitTestRepo {
    let path: String
    let catalog: GitTestCatalog
    let events = GitTestEvents()
    let service: GitService
    let project: ProjectId
    let client = ClientId()

    init(commit: Bool, catalog: GitTestCatalog = GitTestCatalog(), lookup: ExecutableLookup = .system) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tab-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        path = canonical(base.path)
        self.catalog = catalog
        service = GitService(projects: catalog, events: events, lookup: lookup,
                             hooks: WorktreeHooks(userConfig: URL(fileURLWithPath: path + "/machine-worktree.json")))
        project = ProjectId()
        catalog.add(ProjectDescriptor(id: project, directory: ServerPath(path), name: "Test"))
        try Self.initialize(path)
        if commit { try run("commit", "--allow-empty", "-m", "initial") }
    }

    static func initialize(_ path: String) throws {
        try git(path, "init", "-b", "main")
        try git(path, "config", "user.name", "Test")
        try git(path, "config", "user.email", "test@example.invalid")
        try git(path, "config", "commit.gpgsign", "false")
        try git(path, "config", "tag.gpgsign", "false")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Runs `git` in `directory` for test setup, returning standard output.
    @discardableResult
    static func git(_ directory: String, _ arguments: String...) throws -> String {
        try gitArguments(directory, arguments)
    }

    @discardableResult
    static func gitArguments(_ directory: String, _ arguments: [String]) throws -> String {
        let output = try ProcessRunner.run(GitCommand().git, arguments, directory: directory,
                                           environment: GitCommand.environment(), timeout: 30)
        guard output.succeeded else { throw GitTestError.failed(output.stderrText) }
        return output.stdoutText
    }

    @discardableResult
    func run(_ arguments: String...) throws -> String {
        try Self.gitArguments(path, arguments)
    }

    func git(_ action: GitAction, project: ProjectId? = nil) throws -> GitReply {
        let request = GitRequest(project: project ?? self.project, action: action)
        try request.validate()
        return try service.perform(request, client: client)
    }

    func summary() throws -> GitSummary {
        guard case .summary(let summary?) = try git(.summary) else { throw GitTestError.failed("no summary") }
        return summary
    }

    @discardableResult
    func commit(_ message: String) throws -> String {
        guard case .commit(let hash) = try git(.commit(message: message, stageAll: true, amend: false)) else {
            throw GitTestError.failed("no commit")
        }
        return hash
    }

    func write(_ relative: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ relative: String) throws -> String {
        try String(contentsOfFile: (path as NSString).appendingPathComponent(relative), encoding: .utf8)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(relative))
    }

    /// A bare repository inside `.git` added as `origin`.
    @discardableResult
    func addRemote() throws -> String {
        let remote = path + "/.git/test-remote.git"
        try FileManager.default.createDirectory(atPath: remote, withIntermediateDirectories: true)
        try Self.git(remote, "init", "--bare", "-b", "main")
        try run("remote", "add", "origin", remote)
        return remote
    }

    func porcelain() throws -> String {
        try run("status", "--porcelain=v1", "-z", "--untracked-files=all")
    }

    func errorMessage(_ body: () throws -> Any) -> String {
        do {
            _ = try body()
            return ""
        } catch let error as ServiceError {
            return error.message
        } catch {
            return "\(error)"
        }
    }
}

func makeExecutable(_ path: String, _ script: String) throws {
    try Data(script.utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, 0o755)
}
