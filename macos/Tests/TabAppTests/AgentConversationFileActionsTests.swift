import AppKit
import TabClient
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationFileActionsTests: XCTestCase {
    private let scope = AgentConversationFileActions.Scope(project: ProjectId(), session: SessionId(), directory: "/workspace")

    func testMetadataAnchorsAbsolutePathsAndPreservesMissingEntries() async throws {
        var paths: [String] = []
        let values = try await AgentConversationFileActions.filesystemMetadata(["/workspace/Sources/main.swift", "/workspace/missing"], scope: scope,
            read: { request in
                XCTAssertEqual(request.project, self.scope.project)
                guard case .stat(let path) = request.action else { throw ModelError("Unexpected read") }
                paths.append(path.rawValue)
                if path.rawValue == "missing" { throw ClientError.server(ErrorReply(code: .badPath, message: "Not found")) }
                return .info(FileInfo(name: ServerPath("main.swift"), path: path, isDirectory: false, size: 12))
            })
        XCTAssertEqual(paths, ["Sources/main.swift", "missing"])
        XCTAssertEqual(values, [.init(isDirectory: false, byteLength: 12, mimeType: AgentConversationFileActions.mimeType(path: "main.swift")), nil])
        do {
            _ = try await AgentConversationFileActions.filesystemMetadata(["/elsewhere/secret"], scope: scope,
                read: { _ in XCTFail("Paths outside the project cannot reach the server"); throw ModelError("Unexpected read") })
            XCTFail("Expected scope rejection")
        } catch {}
    }

    func testSearchFiltersProjectEntriesAndReportsTruncation() async throws {
        let read: AgentConversationFileActions.Read = { request in
            guard case .searchFiles = request.action else { throw ModelError("Unexpected read") }
            return .fileList(FileList(paths: ["Sources/App.swift", "Sources/AppModel.swift", "README.md"], truncated: false))
        }
        let found = try await AgentConversationFileActions.searchProjectEntries("app", limit: 1, scope: scope, read: read)
        XCTAssertEqual(found, .init(paths: ["Sources/App.swift"], truncated: true))
        let all = try await AgentConversationFileActions.searchProjectEntries("", limit: 10, scope: scope, read: read)
        XCTAssertEqual(all.paths.count, 3)
        XCTAssertFalse(all.truncated)
    }

    func testWorkspaceMediaIsScopedAndRejectsCrossConversationBeforeRead() async throws {
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII="))
        let media = try await AgentConversationFileActions.media("/workspace/pixel.png", session: scope.session, scope: scope, ranged: false,
            read: { request in
                switch request.action {
                case .stat(let path): return .info(FileInfo(name: ServerPath("pixel.png"), path: path, isDirectory: false, size: UInt64(image.count)))
                case .readBytes(let path): XCTAssertEqual(path.rawValue, "pixel.png"); return .bytes(FileBytes(path: path, bytes: image))
                default: throw ModelError("Unexpected read")
                }
            })
        XCTAssertEqual(media.path, "pixel.png")
        XCTAssertEqual(media.sourcePath, "/workspace/pixel.png")
        XCTAssertEqual(media.mimeType, "image/png")
        XCTAssertEqual(media.pixelSize, CGSize(width: 1, height: 1))
        XCTAssertFalse(media.revision.isEmpty)
        let bytes = try await media.resource.read(0, UInt32(image.count))
        XCTAssertEqual(bytes, image)
        do {
            _ = try await AgentConversationFileActions.media("pixel.png", session: SessionId(), scope: scope, ranged: false,
                read: { _ in XCTFail("A foreign conversation cannot read project bytes"); throw ModelError("Unexpected read") })
            XCTFail("Expected scope rejection")
        } catch {}
    }

    func testLargeMediaIsRejectedBeforeFetchingBytes() async throws {
        var reads = 0
        do {
            _ = try await AgentConversationFileActions.media("large.mp4", scope: scope, ranged: false,
                read: { request in
                    reads += 1
                    guard case .stat(let path) = request.action else { XCTFail("Oversized media must not fetch bytes"); throw ModelError("Unexpected read") }
                    return .info(FileInfo(name: ServerPath("large.mp4"), path: path, isDirectory: false, size: UInt64(AgentConversationFileActions.maximumAssetBytes + 1)))
                })
            XCTFail("Expected size rejection")
        } catch {}
        XCTAssertEqual(reads, 1)
        XCTAssertThrowsError(try AgentConversationFileActions.resolve("../private", scope: scope))
        XCTAssertThrowsError(try AgentConversationFileActions.resolve("/workspace-other/private", scope: scope))
    }

    func testLargeMediaUsesBoundedRevisionPinnedRangesAndNeverReadsWholeFile() async throws {
        let size: UInt64 = 250 * 1024 * 1024
        var requests: [FilesAction] = []
        let media = try await AgentConversationFileActions.media("large.mp4", scope: scope, ranged: true,
            read: { request in
                requests.append(request.action)
                switch request.action {
                case .stat(let path): return .info(FileInfo(name: "large.mp4", path: path, isDirectory: false, size: size))
                case .readRange(let path, let offset, let length, _):
                    return .byteRange(FileByteRange(path: path, offset: offset, totalSize: size, revision: "observed-revision", bytes: Data(repeating: 0, count: Int(length))))
                default: XCTFail("Media streaming must not fetch the whole file"); throw ModelError("Unexpected read")
                }
            })
        XCTAssertEqual(requests.count, 2)
        guard case .readRange(_, 0, let length, nil) = requests[1] else { return XCTFail("The first range carries no revision: \(requests)") }
        XCTAssertEqual(length, UInt32(FileByteRange.maximumChunkBytes))
        XCTAssertEqual(media.revision, "observed-revision")
        XCTAssertEqual(media.mimeType, "video/mp4")
        XCTAssertEqual(media.resource.length, size)
        _ = try await media.resource.read(1024, 16)
        guard case .readRange(_, 1024, 16, "observed-revision") = requests[2] else { return XCTFail("Later ranges are pinned to the revision: \(requests)") }
    }

    func testProposedPlanSaveUsesExistingScopedWriteAndReturnsRelativePath() async throws {
        let markdown = "# Proposed plan\n\n- Preserve 🐈 exactly.\n"
        var writes = 0
        let path = try await AgentConversationFileActions.writeProjectFile("plan.md", contents: markdown, cwd: scope.directory, scope: scope, createParents: true,
            read: { request in
                XCTAssertEqual(request.project, self.scope.project)
                guard case .write(let path, let contents, let createParents) = request.action else { throw ModelError("Unexpected plan request") }
                writes += 1; XCTAssertEqual(path.rawValue, "plan.md"); XCTAssertEqual(contents, markdown); XCTAssertTrue(createParents)
                return .path(path)
            })
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(path, "plan.md")
        for (relative, cwd) in [("../outside.md", scope.directory), ("/workspace/absolute.md", scope.directory), ("plan.md", "/workspace/Sources")] {
            do {
                _ = try await AgentConversationFileActions.writeProjectFile(relative, contents: markdown, cwd: cwd, scope: scope,
                    read: { _ in XCTFail("Unsafe plan paths cannot reach the project server"); throw ModelError("Unexpected write") })
                XCTFail("Expected path rejection")
            } catch {}
        }
    }

    func testEditorTargetPreservesSourceLineColumnAndLiteralColon() {
        XCTAssertEqual(AgentConversationFileTarget.parse("src/main.ts:12:5"), .init(path: "src/main.ts", line: 12, column: 5))
        XCTAssertEqual(AgentConversationFileTarget.parse("src/main.ts#L18C2"), .init(path: "src/main.ts", line: 18, column: 2))
        XCTAssertEqual(AgentConversationFileTarget.parse("src/main.ts:3#L18C2"), .init(path: "src/main.ts", line: 3))
        XCTAssertEqual(AgentConversationFileTarget.parse("src/main.ts:0"), .init(path: "src/main.ts"))
        XCTAssertEqual(AgentConversationFileTarget.parse("/workspace/name:literal.swift"), .init(path: "/workspace/name:literal.swift"))
        XCTAssertEqual(AgentConversationFileTarget.parse("/workspace/actual%20name.swift:2:3"), .init(path: "/workspace/actual%20name.swift", line: 2, column: 3))
        XCTAssertEqual(AgentConversationFileTarget.parse("file:///workspace/name%2520here.swift#L2C3"), .init(path: "/workspace/name%20here.swift", line: 2, column: 3))
    }
}
