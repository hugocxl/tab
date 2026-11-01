import Foundation
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationPullRequestPreviewTests: XCTestCase {
    func testPullRequestLinkRequestsOnlyThatPreview() async throws {
        let project = ProjectId()
        let url = try XCTUnwrap(URL(string: "https://github.com/example/repo/pull/42/files"))
        let target = try XCTUnwrap(AgentConversationPullRequestPreview.target(from: url))
        XCTAssertEqual(target, .init(host: "github.com", repository: "example/repo", number: 42))
        let value = GitPullRequestPreview(repository: "example/repo", number: 42, title: "Existing PR", url: "https://github.com/example/repo/pull/42",
                                          author: .init(login: "author", name: nil, avatarURL: nil), state: .open, isDraft: true, createdAt: "2026-10-31T10:00:00Z")
        var requests: [GitRequest] = []
        let result = try await AgentConversationPullRequestPreview.perform(target, project: project, request: { requests.append($0); return .pullRequestPreview(value) })
        XCTAssertEqual(requests, [.init(project: project, action: .pullRequest(.preview(host: "github.com", repository: "example/repo", number: 42)))])
        XCTAssertEqual(result, value)
    }

    func testOtherLinksAndUnrelatedServerRepliesCannotPopulateAPreview() async throws {
        for link in ["https://github.com/example/repo/issues/42", "https://github.com/example/repo/pull/0", "http://github.com/example/repo/pull/42",
                     "https://github.com/example/../pull/42", "https://github.com/example/repo/pull/1.5", "https://github.com/example"] {
            XCTAssertNil(AgentConversationPullRequestPreview.target(from: try XCTUnwrap(URL(string: link))), link)
        }
        let project = ProjectId()
        do {
            _ = try await AgentConversationPullRequestPreview.perform(.init(host: "github.com", repository: "../repo", number: 42), project: project,
                request: { _ in XCTFail("Invalid targets cannot reach GitHub"); return .done })
            XCTFail("Expected target rejection")
        } catch {}
        do {
            let unrelated = GitPullRequestPreview(repository: "other/repo", number: 42, title: "Wrong", url: "https://github.com/other/repo/pull/42", author: nil, state: .open, isDraft: false, createdAt: "2026-10-31T10:00:00Z")
            _ = try await AgentConversationPullRequestPreview.perform(.init(host: "github.com", repository: "example/repo", number: 42), project: project,
                request: { _ in .pullRequestPreview(unrelated) })
            XCTFail("Expected unrelated result rejection")
        } catch {}
    }
}
