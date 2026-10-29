import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class UploadTests: XCTestCase {
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
