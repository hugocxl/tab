import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class UploadTests: XCTestCase {
    func testCompletedPathsResolveTemporaryDirectoryAliases() throws {
        let root = try makeShortTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let uploads = Uploads(directory: alias.appendingPathComponent("uploads"))
        let session = SessionId()
        let path = try XCTUnwrap(try uploads.receive(UploadChunk(session: session, upload: OperationId(),
            name: "file", offset: 0, bytes: Data([1]), last: true)))
        XCTAssertEqual(path.rawValue, root.appendingPathComponent("uploads/\(session)/file").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path.rawValue)), Data([1]))
    }

    func testOutOfOrderChunksCleanUpAndSizeLimitsRefuseBeforeWriting() throws {
        let root = try makeShortTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("uploads")
        let uploads = Uploads(directory: directory)
        let session = SessionId()
        let upload = OperationId()
        func chunk(_ offset: UInt64, _ bytes: Data) -> UploadChunk {
            UploadChunk(session: session, upload: upload, name: "file", offset: offset, bytes: bytes, last: false)
        }
        for invalid in [chunk(Limits.maxUploadBytes, Data([1])),
                        chunk(0, Data(repeating: 1, count: Limits.maxUploadChunk + 1))] {
            XCTAssertThrowsError(try uploads.receive(invalid)) {
                XCTAssertEqual(($0 as? ServiceError)?.code, .badRequest)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        XCTAssertNil(try uploads.receive(chunk(0, Data([1, 2]))))
        let folder = directory.appendingPathComponent(session.description)
        let partial = folder.appendingPathComponent("\(upload).part")
        XCTAssertThrowsError(try uploads.receive(chunk(0, Data([3]))))
        XCTAssertEqual(try Data(contentsOf: partial), Data([1, 2]))
        XCTAssertThrowsError(try uploads.receive(chunk(5, Data([3]))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertThrowsError(try uploads.receive(chunk(2, Data([3]))))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func testChunksReassembleIntoAFileThatNeverReplacesAnother() throws {
        let root = try makeShortTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = Uploads(directory: root.appendingPathComponent("uploads"))
        let session = SessionId()
        let bytes = Data((0..<3000).map { UInt8($0 % 251) })

        func send(_ name: String) throws -> ServerPath? {
            let upload = OperationId()
            var path: ServerPath?
            for offset in stride(from: 0, to: bytes.count, by: 1024) {
                let end = min(offset + 1024, bytes.count)
                path = try uploads.receive(UploadChunk(session: session, upload: upload, name: name,
                                                       offset: UInt64(offset), bytes: bytes.subdata(in: offset..<end),
                                                       last: end == bytes.count))
            }
            return path
        }

        let first = try XCTUnwrap(try send("../shot.png"))
        XCTAssertEqual(first.lastComponent, "shot.png", "only the name's last component is kept")
        XCTAssertEqual(try Data(contentsOf: first.url), bytes)
        let second = try XCTUnwrap(try send("shot.png"))
        XCTAssertEqual(second.lastComponent, "shot-2.png")

        let upload = OperationId()
        XCTAssertThrowsError(try uploads.receive(UploadChunk(session: session, upload: upload, name: "x",
                                                             offset: 5, bytes: Data([1]), last: false)),
                             "a file can't start in the middle")

        let folder = URL(fileURLWithPath: first.rawValue).deletingLastPathComponent()
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["shot.png", "shot-2.png"])
    }

    func testDiscardLeavesUploadsForSystemTemporaryDirectoryCleanup() throws {
        let host = try CoreTestServer(start: false)
        let server = host.server
        let session = try server.createSession(CreateSession(project: server.homeProject,
            directory: ServerPath(host.root.path), size: Size(cols: 80, rows: 24), command: "sleep 30"), requester: nil)
        defer { server.endAllSessions() }
        let complete = try XCTUnwrap(try server.uploads.receive(UploadChunk(session: session.id, upload: OperationId(),
            name: "file", offset: 0, bytes: Data([1]), last: true)))
        let partial = OperationId()
        XCTAssertNil(try server.uploads.receive(UploadChunk(session: session.id, upload: partial,
            name: "unfinished", offset: 0, bytes: Data([2]), last: false)))
        try server.discard(session.id)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: complete.rawValue)), Data([1]))
        let folder = URL(fileURLWithPath: complete.rawValue).deletingLastPathComponent()
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("\(partial).part")), Data([2]))
    }
}
