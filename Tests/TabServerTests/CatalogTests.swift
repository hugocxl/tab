import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class CatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeShortTemporaryFolder()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func open() throws -> Catalog {
        try Catalog(directory: root, homeDirectory: root.path, hasSavedScreen: { _ in false })
    }

    private func folder(_ name: String) throws -> ServerPath {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ServerPath(url.path)
    }

    func testProjectsAndHomeSurviveReopening() throws {
        let catalog = try open()
        let home = catalog.homeId
        let project = ProjectDescriptor.new(directory: try folder("app"))
        _ = try catalog.mutate(ProjectIntent(mutation: .create(project)))
        _ = try catalog.mutate(ProjectIntent(mutation: .rename(project: project.id, name: "App")))

        let reopened = try open()
        XCTAssertEqual(reopened.homeId, home)
        XCTAssertEqual(reopened.serverId, catalog.serverId, "the server keeps its identity")
        XCTAssertEqual(try reopened.project(project.id).name, "App")
        XCTAssertTrue(try reopened.project(home).home)
    }

    func testHomeCantBeRemovedAndHasNoWorktrees() throws {
        let catalog = try open()
        XCTAssertThrowsError(try catalog.mutate(ProjectIntent(mutation: .delete(catalog.homeId))))
        var worktree = ProjectDescriptor.new(directory: try folder("wt"))
        worktree.kind = .worktree
        worktree.parentId = catalog.homeId
        XCTAssertThrowsError(try catalog.addWorktree(worktree))
        XCTAssertNoThrow(try catalog.project(catalog.homeId))
    }

    func testARetriedMutationIsAppliedOnce() throws {
        let catalog = try open()
        let intent = ProjectIntent(mutation: .create(ProjectDescriptor.new(directory: try folder("once"))))
        let revision = try catalog.mutate(intent)
        XCTAssertEqual(try catalog.mutate(intent), revision)
        XCTAssertEqual(catalog.projects().count, 2)
    }

    func testAProjectNeedsAnExistingFolder() throws {
        let catalog = try open()
        let missing = ProjectDescriptor.new(directory: ServerPath(root.appendingPathComponent("missing").path))
        XCTAssertThrowsError(try catalog.mutate(ProjectIntent(mutation: .create(missing))))
    }

    func testAGoneWorktreeIsPrunedOnlyWithoutSessions() throws {
        let catalog = try open()
        let parent = ProjectDescriptor.new(directory: try folder("repo"))
        _ = try catalog.mutate(ProjectIntent(mutation: .create(parent)))
        func worktree(_ name: String) throws -> ProjectDescriptor {
            var project = ProjectDescriptor.new(directory: try folder(name))
            project.kind = .worktree
            project.parentId = parent.id
            try catalog.addWorktree(project)
            return project
        }
        let empty = try worktree("empty")
        let used = try worktree("used")
        try catalog.reserve(OperationId(), SessionInfo(project: used.id, id: SessionId(), directory: used.directory))
        try FileManager.default.removeItem(atPath: empty.directory.rawValue)
        try FileManager.default.removeItem(atPath: used.directory.rawValue)

        XCTAssertEqual(catalog.prunableWorktrees(of: parent.id), [empty.id])
        _ = try catalog.mutate(ProjectIntent(mutation: .pruneWorktree(empty.id)))
        _ = try catalog.mutate(ProjectIntent(mutation: .pruneWorktree(used.id)))
        XCTAssertThrowsError(try catalog.project(empty.id))
        XCTAssertNoThrow(try catalog.project(used.id), "a worktree with history stays")
    }

    func testAnInaccessibleWorktreeIsNotMistakenForADeletedOne() throws {
        let catalog = try open()
        let parent = ProjectDescriptor.new(directory: try folder("repo"))
        _ = try catalog.mutate(ProjectIntent(mutation: .create(parent)))
        let directory = try folder("restricted/tree")
        let project = ProjectDescriptor(directory: directory, name: "tree", kind: .worktree, parentId: parent.id)
        try catalog.addWorktree(project)
        let restricted = root.appendingPathComponent("restricted").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted) }
        XCTAssertTrue(catalog.prunableWorktrees(of: parent.id).isEmpty)
        _ = try catalog.mutate(ProjectIntent(mutation: .pruneWorktree(project.id)))
        XCTAssertNoThrow(try catalog.project(project.id))
    }

    func testPagesFollowTheRevision() throws {
        let catalog = try open()
        for index in 0..<(Limits.catalogPageSize + 2) {
            _ = try catalog.mutate(ProjectIntent(mutation: .create(.new(directory: try folder("p\(index)")))))
        }
        let first = try catalog.page(after: nil, revision: nil)
        XCTAssertEqual(first.projects.count, Limits.catalogPageSize)
        let next = try XCTUnwrap(first.next)
        let second = try catalog.page(after: next, revision: first.revision)
        XCTAssertEqual(first.projects.count + second.projects.count, Limits.catalogPageSize + 3)
        _ = try catalog.mutate(ProjectIntent(mutation: .rename(project: catalog.homeId, name: "Home")))
        XCTAssertThrowsError(try catalog.page(after: next, revision: first.revision)) { error in
            XCTAssertEqual((error as? ServiceError)?.code, .catalogChanged)
        }
    }

    func testSessionsThatWereLiveBecomeEndedOrUnavailableAfterACrash() throws {
        let catalog = try open()
        let saved = SessionInfo(project: catalog.homeId, id: SessionId(), directory: ServerPath(root.path))
        let lost = SessionInfo(project: catalog.homeId, id: SessionId(), directory: ServerPath(root.path))
        try catalog.reserve(OperationId(), saved)
        try catalog.reserve(OperationId(), lost)
        try catalog.setLive(saved.id)

        let reopened = try Catalog(directory: root, homeDirectory: root.path, hasSavedScreen: { $0 == saved.id })
        XCTAssertEqual(reopened.record(saved.id)?.status, .ended)
        XCTAssertEqual(reopened.record(lost.id)?.status, .unavailable)
    }
}
