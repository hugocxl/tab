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
        let reply = try await AgentConversationFileActions.perform("filesystemMetadata", payload: ["input": ["paths": ["/workspace/Sources/main.swift", "/workspace/missing"]]], scope: scope,
            read: { request in
                XCTAssertEqual(request.project, self.scope.project)
                guard case .stat(let path) = request.action else { throw ModelError("Unexpected read") }
                paths.append(path.rawValue)
                if path.rawValue == "missing" { throw ClientError.server(ErrorReply(code: .badPath, message: "Not found")) }
                return .info(FileInfo(name: ServerPath("main.swift"), path: path, isDirectory: false, size: 12))
            }, register: { _, _, _ in throw ModelError("Metadata must not mint assets") })
        XCTAssertEqual(paths, ["Sources/main.swift", "missing"])
        let values = try XCTUnwrap((reply as? [String: Any])?["entries"] as? [Any])
        XCTAssertEqual((values[0] as? [String: Any])?["kind"] as? String, "file")
        XCTAssertTrue(values[1] is NSNull)
    }

    func testWorkspaceMediaReturnsScopedURLAndRejectsCrossConversationBeforeRead() async throws {
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII="))
        var registered = false
        let payload: [String: Any] = ["environmentId": scope.project.description, "input": ["resource": ["_tag": "media-file", "threadId": scope.session.description, "path": "/workspace/pixel.png"]]]
        let reply = try await AgentConversationFileActions.perform("createAssetUrl", payload: payload, scope: scope,
            read: { request in
                switch request.action {
                case .stat(let path): return .info(FileInfo(name: ServerPath("pixel.png"), path: path, isDirectory: false, size: UInt64(image.count)))
                case .readBytes(let path): XCTAssertEqual(path.rawValue, "pixel.png"); return .bytes(FileBytes(path: path, bytes: image))
                default: throw ModelError("Unexpected read")
                }
            }, register: { bytes, mime, path in
                XCTAssertEqual(path, "pixel.png")
                XCTAssertEqual(bytes, image); XCTAssertEqual(mime, "image/png"); registered = true
                return try XCTUnwrap(URL(string: "tab-conversation://resource/scoped"))
            })
        XCTAssertTrue(registered)
        let value = try XCTUnwrap(reply as? [String: Any])
        XCTAssertEqual(value["relativeUrl"] as? String, "tab-conversation://resource/scoped")
        XCTAssertEqual(value["sourcePath"] as? String, "/workspace/pixel.png")
        XCTAssertNotNil(value["fileRevision"])
        XCTAssertFalse(value.values.contains { $0 is Data })
        do {
            _ = try await AgentConversationFileActions.perform("createAssetUrl", payload: ["input": ["resource": ["_tag": "media-file", "threadId": SessionId().description, "path": "pixel.png"]]], scope: scope,
                read: { _ in XCTFail("A foreign conversation cannot read project bytes"); throw ModelError("Unexpected read") },
                register: { _, _, _ in throw ModelError("Unexpected mint") })
            XCTFail("Expected scope rejection")
        } catch {}
    }

    func testLargeMediaIsRejectedBeforeFetchingBytes() async throws {
        var reads = 0
        do {
            _ = try await AgentConversationFileActions.perform("createAssetUrl", payload: ["input": ["resource": ["_tag": "media-file", "path": "large.mp4"]]], scope: scope,
                read: { request in
                    reads += 1
                    guard case .stat(let path) = request.action else { XCTFail("Oversized media must not fetch bytes"); throw ModelError("Unexpected read") }
                    return .info(FileInfo(name: ServerPath("large.mp4"), path: path, isDirectory: false, size: UInt64(AgentConversationFileActions.maximumAssetBytes + 1)))
                }, register: { _, _, _ in throw ModelError("Unexpected mint") })
            XCTFail("Expected size rejection")
        } catch {}
        XCTAssertEqual(reads, 1)
        XCTAssertThrowsError(try AgentConversationFileActions.resolve("../private", scope: scope))
        XCTAssertThrowsError(try AgentConversationFileActions.resolve("/workspace-other/private", scope: scope))
    }

    func testLargeMediaUsesBoundedRevisionMetadataAndNeverReadsWholeFile() async throws {
        let size: UInt64 = 250 * 1024 * 1024
        var requests = 0, registered = false
        let reply = try await AgentConversationFileActions.perform("createAssetUrl", payload: ["input": ["resource": ["_tag": "media-file", "path": "large.mp4"]]], scope: scope,
            read: { request in
                requests += 1
                switch request.action {
                case .stat(let path): return .info(FileInfo(name: "large.mp4", path: path, isDirectory: false, size: size))
                case .readRange(let path, let offset, let length, let revision):
                    XCTAssertEqual(offset, 0); XCTAssertEqual(length, UInt32(FileByteRange.maximumChunkBytes)); XCTAssertNil(revision)
                    return .byteRange(FileByteRange(path: path, offset: 0, totalSize: size, revision: "observed-revision", bytes: Data(repeating: 0, count: Int(length))))
                default: XCTFail("Media streaming must not fetch the whole file"); throw ModelError("Unexpected read")
                }
            }, register: { _, _, _ in XCTFail("Media streaming must not register the whole file"); throw ModelError("Unexpected register") },
            registerRange: { range, mime, path in
                XCTAssertEqual(range.totalSize, size); XCTAssertEqual(range.revision, "observed-revision")
                XCTAssertEqual(mime, "video/mp4"); XCTAssertEqual(path, "large.mp4"); registered = true
                return URL(string: "tab-conversation://resource/ranged")!
            })
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(registered)
        XCTAssertEqual((reply as? [String: Any])?["fileRevision"] as? String, "observed-revision")
    }

    func testProposedPlanSaveUsesExistingScopedWriteAndReturnsSourceRelativePath() async throws {
        let markdown = "# Proposed plan\n\n- Preserve 🐈 exactly.\n"
        var writes = 0
        let result = try await AgentConversationFileActions.perform("writeProjectFile", payload: ["environmentId": scope.project.description, "input": ["cwd": scope.directory, "relativePath": "plan.md", "contents": markdown]], scope: scope,
            read: { request in
                XCTAssertEqual(request.project, self.scope.project)
                guard case .write(let path, let contents, let createParents) = request.action else { throw ModelError("Unexpected plan request") }
                writes += 1; XCTAssertEqual(path.rawValue, "plan.md"); XCTAssertEqual(contents, markdown); XCTAssertTrue(createParents)
                return .path(path)
            }, register: { _, _, _ in throw ModelError("Plan saves must not register media") }, createWriteParents: true)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual((result as? [String: String])?["relativePath"], "plan.md")
        for path in ["../outside.md", "/workspace/absolute.md"] {
            do {
                _ = try await AgentConversationFileActions.perform("writeProjectFile", payload: ["environmentId": scope.project.description, "input": ["cwd": scope.directory, "relativePath": path, "contents": markdown]], scope: scope,
                    read: { _ in XCTFail("Unsafe plan paths cannot reach the project server"); throw ModelError("Unexpected write") }, register: { _, _, _ in throw ModelError("Unexpected media") })
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
