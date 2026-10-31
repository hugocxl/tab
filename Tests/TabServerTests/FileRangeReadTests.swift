import Darwin
import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class FileRangeReadTests: XCTestCase {
    func testBoundedReadsBeyondWholeFileLimitAndEmptyEOF() async throws {
        let workspace = try FilesWorkspace()
        let bytes = Data((0 ..< Limits.maxFileBytes + 97).map { UInt8($0 % 251) })
        try bytes.write(to: workspace.url("movie.bin"))
        let start = UInt64(Limits.maxFileBytes + 30)
        guard case .byteRange(let range) = try await workspace.files(.readRange(path: "movie.bin", offset: start, length: 100, expectedRevision: nil)) else { return XCTFail("Expected a bounded byte range") }
        XCTAssertEqual(range.bytes, bytes.suffix(67))
        XCTAssertEqual(range.totalSize, UInt64(bytes.count))
        XCTAssertEqual(range.offset, start)
        XCTAssertEqual(range.revision.count, 64)
        for offset in [UInt64(bytes.count), UInt64(bytes.count + 10)] {
            guard case .byteRange(let eof) = try await workspace.files(.readRange(path: "movie.bin", offset: offset, length: 10, expectedRevision: range.revision)) else { return XCTFail("Expected EOF range") }
            XCTAssertTrue(eof.bytes.isEmpty)
            XCTAssertEqual(eof.totalSize, range.totalSize)
        }
        await assertFilesThrows(try await workspace.files(.readBytes("movie.bin")), "Existing whole-file limit remains unchanged")
        try Data().write(to: workspace.url("empty"))
        guard case .byteRange(let empty) = try await workspace.files(.readRange(path: "empty", offset: 0, length: 1, expectedRevision: nil)) else { return XCTFail("Expected empty range") }
        XCTAssertEqual(empty.totalSize, 0)
        XCTAssertTrue(empty.bytes.isEmpty)
    }

    func testChangedAndReplacedFilesRejectPreviousRevision() async throws {
        let workspace = try FilesWorkspace()
        try Data("first version".utf8).write(to: workspace.url("asset"))
        guard case .byteRange(let first) = try await workspace.files(.readRange(path: "asset", offset: 0, length: 5, expectedRevision: nil)) else { return XCTFail() }
        try Data("other version".utf8).write(to: workspace.url("asset"))
        await assertFilesThrows(try await workspace.files(.readRange(path: "asset", offset: 5, length: 5, expectedRevision: first.revision)))
        try Data("first version".utf8).write(to: workspace.url("replacement"))
        XCTAssertEqual(rename(workspace.url("replacement").path, workspace.url("asset").path), 0)
        await assertFilesThrows(try await workspace.files(.readRange(path: "asset", offset: 0, length: 5, expectedRevision: first.revision)))
    }

    func testMalformedRangesAreRejectedBeforeConversionOrAllocation() async throws {
        let workspace = try FilesWorkspace()
        try Data([1, 2, 3]).write(to: workspace.url("asset"))
        for action in [
            FilesAction.readRange(path: "asset", offset: 0, length: 0, expectedRevision: nil),
            .readRange(path: "asset", offset: 0, length: UInt32.max, expectedRevision: nil),
            .readRange(path: "asset", offset: UInt64.max, length: 1, expectedRevision: nil),
            .readRange(path: "asset", offset: UInt64(Int64.max), length: 1, expectedRevision: nil),
            .readRange(path: "../asset", offset: 0, length: 1, expectedRevision: nil),
            .readRange(path: "asset", offset: 0, length: 1, expectedRevision: "")
        ] { await assertFilesThrows(try await workspace.files(action)) }
        let action = FilesAction.readRange(path: "asset", offset: 1, length: 2, expectedRevision: "revision")
        XCTAssertEqual(try JSONDecoder().decode(FilesAction.self, from: JSONEncoder().encode(action)), action)
        let reply = FilesReply.byteRange(FileByteRange(path: "asset", offset: 1, totalSize: 3, revision: "revision", bytes: Data([2, 3])))
        XCTAssertEqual(try JSONDecoder().decode(FilesReply.self, from: JSONEncoder().encode(reply)), reply)
    }

    func testIntermediateSymlinkSwapsNeverExposeExternalBytes() async throws {
        let workspace = try FilesWorkspace(), outside = try FilesWorkspace()
        try FileManager.default.createDirectory(at: workspace.url("folder"), withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: workspace.url("folder/file"))
        try Data("SECRET".utf8).write(to: outside.url("file"))
        let stop = ManagedFlag(), directory = workspace.path, external = outside.path
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
        defer { stop.set(); stop.waitFinished() }
        for _ in 0 ..< 100 {
            if case .byteRange(let range)? = try? await workspace.files(.readRange(path: "folder/file", offset: 0, length: 6, expectedRevision: nil)) {
                XCTAssertEqual(range.bytes, Data("inside".utf8))
            }
        }
    }
}
