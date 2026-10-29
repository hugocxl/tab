import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class UploadTests: XCTestCase {
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

        try uploads.remove(session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.rawValue))
    }
}
