import Foundation
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationPullRequestPreviewTests: XCTestCase {
    func testNativeMetadataMatchesActualSourceCardContractWithoutInventingAuthorFields() async throws {
        let project = ProjectId()
        let payload: [String: Any] = ["environmentId": project.description, "input": ["projectId": project.description, "host": "github.com", "repository": "example/repo", "number": 42]]
        let value = GitPullRequestPreview(repository: "example/repo", number: 42, title: "Existing PR", url: "https://github.com/example/repo/pull/42",
                                          author: .init(login: "author", name: nil, avatarURL: nil), state: .open, isDraft: true, createdAt: "2026-10-31T10:00:00Z")
        var requests: [GitRequest] = []
        let result = try await AgentConversationPullRequestPreview.perform(payload, project: project, request: { requests.append($0); return .pullRequestPreview(value) })
        XCTAssertEqual(requests, [.init(project: project, action: .pullRequest(.preview(host: "github.com", repository: "example/repo", number: 42)))])
        XCTAssertEqual(result["state"] as? String, "open")
        XCTAssertEqual(result["isDraft"] as? Bool, true)
        XCTAssertEqual(result["createdAt"] as? String, value.createdAt)
        let author = try XCTUnwrap(result["author"] as? [String: Any])
        XCTAssertEqual(author["login"] as? String, "author")
        XCTAssertTrue(author["name"] is NSNull)
        XCTAssertTrue(author["avatarUrl"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result))
    }

    func testForeignScopeAndUnrelatedServerRepliesCannotPopulateInlineCard() async throws {
        let project = ProjectId()
        let base: [String: Any] = ["projectId": project.description, "repository": "example/repo", "number": 42]
        for input in [base.merging(["projectId": ProjectId().description]) { _, value in value }, base.merging(["number": true]) { _, value in value }, base.merging(["number": 1.5]) { _, value in value }] {
            do {
                _ = try await AgentConversationPullRequestPreview.perform(["environmentId": project.description, "input": input], project: project, request: { _ in XCTFail("Invalid card metadata cannot reach GitHub"); return .done })
                XCTFail("Expected source scope/input rejection")
            } catch {}
        }
        do {
            let unrelated = GitPullRequestPreview(repository: "other/repo", number: 42, title: "Wrong", url: "https://github.com/other/repo/pull/42", author: nil, state: .open, isDraft: false, createdAt: "2026-10-31T10:00:00Z")
            _ = try await AgentConversationPullRequestPreview.perform(["environmentId": project.description, "input": base], project: project, request: { _ in .pullRequestPreview(unrelated) })
            XCTFail("Expected unrelated result rejection")
        } catch {}
    }
}
