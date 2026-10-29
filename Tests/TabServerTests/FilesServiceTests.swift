import Foundation
import XCTest
@testable import TabServer
import TabProtocol

final class FilesTestProjects: ProjectLocator, @unchecked Sendable {
    let homeProject = ProjectId()
    var paths: [ProjectId: String] = [:]

    func projectPath(_ id: ProjectId) throws -> String {
        guard let path = paths[id] else { throw ErrorCode.unknownProject }
        return path
    }
}

final class FilesTestEvents: ServiceEvents, @unchecked Sendable {
    private let lock = NSLock()
    private var sentEvents: [(EventBody, ClientId)] = []
    var onSend: ((EventBody, ClientId) -> Void)?

    func broadcast(_ event: EventBody) {}

    func send(_ event: EventBody, to client: ClientId) {
        lock.lock()
        sentEvents.append((event, client))
        let callback = onSend
        lock.unlock()
        callback?(event, client)
    }

    var sent: [(EventBody, ClientId)] {
        lock.lock()
        defer { lock.unlock() }
        return sentEvents
    }
}

/// A temporary project folder served by a `FilesService`.
final class FilesWorkspace {
    let path: String
    let project = ProjectId()
    let client = ClientId()
    let projects = FilesTestProjects()
    let events = FilesTestEvents()
    let service: FilesService

    init(lookup: ExecutableLookup = .system) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tab-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        path = base.resolvingSymlinksInPath().path
        projects.paths[project] = path
        service = FilesService(projects: projects, events: events, lookup: lookup)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func files(_ action: FilesAction) async throws -> FilesReply {
        try await service.handle(FilesRequest(project: project, action: action), client: client)
    }

    @discardableResult
    func write(_ name: String, _ content: String) async throws -> FilesReply {
        try await files(.write(path: ServerPath(name), content: content))
    }

    func url(_ name: String) -> URL { URL(fileURLWithPath: path).appendingPathComponent(name) }

    func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)")
    }
}

func assertFilesThrows(_ body: @autoclosure () async throws -> some Any, _ message: String = "",
                          file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await body()
        XCTFail("Expected an error. \(message)", file: file, line: line)
    } catch {}
}

final class FilesServiceTests: XCTestCase {
    func testAtomicWritesKeepPermissionsAndEnforceLimits() async throws {
        let workspace = try FilesWorkspace()
        let written = try await workspace.write("note", "Grüße\n")
        XCTAssertEqual(written, .path("note"))
        let read = try await workspace.files(.read("note"))
        XCTAssertEqual(read, .content(FileContent(path: "note", content: "Grüße\n", size: 8)))

        chmod(workspace.url("note").path, 0o751)
        try await workspace.write("note", "new")
        let attributes = try FileManager.default.attributesOfItem(atPath: workspace.url("note").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o751)

        let large = String(repeating: "a", count: Limits.maxFileBytes)
        try await workspace.write("large", large)
        guard case .content(let file) = try await workspace.files(.read("large")) else { return XCTFail() }
        XCTAssertEqual(file.content.count, large.count)
        await assertFilesThrows(try await workspace.write("large", large + "b"))
        XCTAssertNoThrow(try Data(count: Limits.maxFileBytes + 1).write(to: workspace.url("huge")))
        do {
            _ = try await workspace.files(.read("huge"))
            XCTFail("read a file over the limit")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("5 MiB"), error.message)
        }
        await assertFilesThrows(try await workspace.write("missing/child", "x"))
        let names = try FileManager.default.contentsOfDirectory(atPath: workspace.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".tab-write-") })
    }

    func testBinaryAndInvalidTextAreRefusedButReadableAsBytes() async throws {
        let workspace = try FilesWorkspace()
        try Data([0x50, 0x4e, 0x47, 0x00, 0x01]).write(to: workspace.url("image.png"))
        try Data([0xff, 0xfe]).write(to: workspace.url("latin"))
        do {
            _ = try await workspace.files(.read("image.png"))
            XCTFail("read a binary file as text")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("binary"), error.message)
        }
        await assertFilesThrows(try await workspace.files(.read("latin")))
        let bytes = try await workspace.files(.readBytes("image.png"))
        XCTAssertEqual(bytes, .bytes(FileBytes(path: "image.png", bytes: Data([0x50, 0x4e, 0x47, 0x00, 0x01]))))
        let written = try await workspace.files(.writeBytes(path: "copy.bin", bytes: Data([0, 1, 2])))
        XCTAssertEqual(written, .path("copy.bin"))
        XCTAssertEqual(try Data(contentsOf: workspace.url("copy.bin")), Data([0, 1, 2]))
    }

    func testListingSortsFoldersFirstAndFlagsIgnoredEntries() async throws {
        let workspace = try FilesWorkspace()
        try workspace.git("init", "-q")
        try await workspace.write(".gitignore", "*.log\nignored/\n")
        try await workspace.write("a.log", "x")
        try await workspace.write("-dash", "x")
        try await workspace.write("Zeta", "x")
        try await workspace.write("line\nbreak", "x")
        _ = try await workspace.files(.mkdir("ignored"))
        _ = try await workspace.files(.mkdir("beta"))
        guard case .entries(let entries) = try await workspace.files(.list("")) else { return XCTFail() }
        XCTAssertEqual(entries.map(\.name.rawValue), ["beta", "ignored", "-dash", ".gitignore", "a.log",
                                                      "line\nbreak", "Zeta"])
        XCTAssertTrue(entries[1].isDirectory && entries[1].isIgnored)
        XCTAssertFalse(entries[0].isIgnored)
        XCTAssertTrue(entries.contains { $0.name == "a.log" && $0.isIgnored })
        XCTAssertTrue(entries.contains { $0.name == "-dash" && !$0.isIgnored })
        XCTAssertFalse(entries.contains { $0.name == ".git" })
        await assertFilesThrows(try await workspace.files(.list("a.log")))
        await assertFilesThrows(try await workspace.files(.list("missing")))

        guard case .info(let info) = try await workspace.files(.stat("a.log")) else { return XCTFail() }
        XCTAssertEqual(info, FileInfo(name: "a.log", path: "a.log", isDirectory: false, size: 1))
    }

    func testMkdirRenameAndMoveNeverOverwrite() async throws {
        let workspace = try FilesWorkspace()
        for name in ["first", "second", "archive"] { _ = try await workspace.files(.mkdir(ServerPath(name))) }
        let numbered = try await workspace.files(.mkdir("first"))
        XCTAssertEqual(numbered, .path("first 2"))
        try await workspace.write("first/report.txt", "first")
        try await workspace.write("second/report.txt", "second")
        try await workspace.write("archive/report.txt", "existing")
        let moved = try await workspace.files(.move(paths: ["first/report.txt", "second/report.txt"], into: "archive"))
        XCTAssertEqual(moved, .paths(["archive/report 2.txt", "archive/report 3.txt"]))
        XCTAssertEqual(try String(contentsOf: workspace.url("archive/report.txt"), encoding: .utf8), "existing")
        await assertFilesThrows(try await workspace.files(.rename(path: "archive/report 2.txt", name: "report.txt")))
        let renamed = try await workspace.files(.rename(path: "archive/report 2.txt", name: "renamed"))
        XCTAssertEqual(renamed, .path("archive/renamed"))
        await assertFilesThrows(try await workspace.files(.rename(path: "missing", name: "missing")))
        await assertFilesThrows(try await workspace.files(.move(paths: ["archive"], into: "archive")))
        let unchanged = try await workspace.files(.move(paths: ["archive/renamed"], into: "archive"))
        XCTAssertEqual(unchanged, .paths(["archive/renamed"]))
        let toRoot = try await workspace.files(.move(paths: ["archive/renamed"], into: ""))
        XCTAssertEqual(toRoot, .paths(["renamed"]))
    }

    func testDeleteIsRecursiveAndValidatesTheWholeBatchFirst() async throws {
        let workspace = try FilesWorkspace()
        try await workspace.write("keep", "original")
        _ = try await workspace.files(.mkdir("folder"))
        try await workspace.write("folder/file", "x")
        _ = try await workspace.files(.mkdir("folder/nested"))
        try await workspace.write("folder/nested/deep", "x")
        for paths: [ServerPath] in [["keep", "../escape"], ["keep", "missing"], ["keep", "keep"],
                                    ["folder", "folder/file"]] {
            await assertFilesThrows(try await workspace.files(.move(paths: paths, into: "folder")))
            await assertFilesThrows(try await workspace.files(.delete(paths)))
        }
        XCTAssertEqual(try String(contentsOf: workspace.url("keep"), encoding: .utf8), "original")
        let deleted = try await workspace.files(.delete(["folder", "keep"]))
        XCTAssertEqual(deleted, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url("folder").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url("keep").path))
    }

    func testDeletingALinkRemovesTheLinkNotItsTarget() async throws {
        let workspace = try FilesWorkspace()
        _ = try await workspace.files(.mkdir("real"))
        try await workspace.write("real/file", "x")
        try FileManager.default.createSymbolicLink(atPath: workspace.url("alias").path, withDestinationPath: "real")
        _ = try await workspace.files(.delete(["alias"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.url("real/file").path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: workspace.url("alias").path))
    }

    func testTheProjectFolderAndItsAliasesCannotBeChanged() async throws {
        let workspace = try FilesWorkspace()
        try FileManager.default.createDirectory(at: workspace.url("nested"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: workspace.url("root-link").path, withDestinationPath: ".")
        for root in ["", ".", "nested/..", "root-link"] {
            let path = ServerPath(root)
            guard case .info(let info) = try await workspace.files(.stat(path)) else { return XCTFail(root) }
            XCTAssertTrue(info.isDirectory)
            XCTAssertEqual(info.path, "")
            await assertFilesThrows(try await workspace.write(root, "x"), root)
            await assertFilesThrows(try await workspace.files(.mkdir(path)), root)
            await assertFilesThrows(try await workspace.files(.rename(path: path, name: "new")), root)
            await assertFilesThrows(try await workspace.files(.move(paths: [path], into: "nested")), root)
            await assertFilesThrows(try await workspace.files(.delete([path])), root)
        }
        for escape in ["../file", "nested/../../file", "/tmp/file"] {
            await assertFilesThrows(try await workspace.write(escape, "x"), escape)
            await assertFilesThrows(try await workspace.files(.read(ServerPath(escape))), escape)
        }
    }

    func testLinksFollowInternalTargetsAndRejectExternalDanglingAndCyclicOnes() async throws {
        let workspace = try FilesWorkspace()
        let outside = try FilesWorkspace()
        try "SECRET".write(to: outside.url("secret"), atomically: true, encoding: .utf8)
        _ = try await workspace.files(.mkdir("real"))
        try FileManager.default.createSymbolicLink(atPath: workspace.url("alias").path,
                                                   withDestinationPath: workspace.url("real").path)
        let written = try await workspace.write("alias/../alias/note", "text")
        XCTAssertEqual(written, .path("real/note"))
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: workspace.url("external").path, withDestinationPath: outside.path)
        try fm.createSymbolicLink(atPath: workspace.url("hop").path, withDestinationPath: "external")
        try fm.createSymbolicLink(atPath: workspace.url("dangling").path, withDestinationPath: outside.url("missing").path)
        try fm.createSymbolicLink(atPath: workspace.url("cycle").path, withDestinationPath: "cycle")
        try fm.createSymbolicLink(atPath: workspace.url("up").path, withDestinationPath: "../")
        for path in ["external/file", "hop/file", "dangling", "cycle", "up/x"] {
            await assertFilesThrows(try await workspace.write(path, "no"), path)
            await assertFilesThrows(try await workspace.files(.stat(ServerPath(path))), path)
            await assertFilesThrows(try await workspace.files(.delete([ServerPath(path)])), path)
        }
        await assertFilesThrows(try await workspace.files(.read("external/secret")))
        await assertFilesThrows(try await workspace.files(.list("external")))
        XCTAssertFalse(fm.fileExists(atPath: outside.url("file").path))
        XCTAssertFalse(fm.fileExists(atPath: outside.url("missing").path))
    }

    func testDirectoryWritesAndFifoReadsFailWithoutBlocking() async throws {
        let workspace = try FilesWorkspace()
        _ = try await workspace.files(.mkdir("folder"))
        await assertFilesThrows(try await workspace.write("folder", "no"))
        XCTAssertEqual(mkfifo(workspace.url("fifo").path, 0o600), 0)
        await assertFilesThrows(try await workspace.files(.read("fifo")))
    }

    func testConcurrentSymlinkSwapsNeverExposeExternalContent() async throws {
        let workspace = try FilesWorkspace()
        let outside = try FilesWorkspace()
        _ = try await workspace.files(.mkdir("folder"))
        try await workspace.write("folder/file", "inside")
        try "SECRET".write(to: outside.url("file"), atomically: true, encoding: .utf8)
        let stop = ManagedFlag()
        let directory = workspace.path
        let external = outside.path
        let swapper = Thread {
            while !stop.isSet {
                rename(directory + "/folder", directory + "/saved")
                symlink(external, directory + "/folder")
                unlink(directory + "/folder")
                rename(directory + "/saved", directory + "/folder")
            }
            stop.finish()
        }
        swapper.start()
        for _ in 0 ..< 300 {
            if case .content(let file)? = try? await workspace.files(.read("folder/file")) {
                XCTAssertEqual(file.content, "inside")
            }
        }
        stop.set()
        stop.waitFinished()
    }

    func testRequestsForUnknownProjectsFail() async throws {
        let workspace = try FilesWorkspace()
        do {
            _ = try await workspace.service.handle(FilesRequest(project: ProjectId(), action: .list("")),
                                                   client: workspace.client)
            XCTFail("listed an unknown project")
        } catch let error as ErrorCode {
            XCTAssertEqual(error, .unknownProject)
        }
    }
}

final class ManagedFlag: @unchecked Sendable {
    private let lock = NSCondition()
    private var flag = false
    private var finished = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        lock.broadcast()
        lock.unlock()
    }

    func waitFinished() {
        lock.lock()
        while !finished { lock.wait() }
        lock.unlock()
    }
}
