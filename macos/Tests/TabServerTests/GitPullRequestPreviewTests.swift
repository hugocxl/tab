import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class GitPullRequestPreviewTests: XCTestCase {
    private func configure(_ repo: GitTestRepo, response: [String: Any]) throws {
        let executable = repo.path + "/.git/preview-gh"
        try makeExecutable(executable, #"""
        #!/bin/sh
        printf '%s\n' "$@" >> .git/preview-calls
        case "$1 $2" in
          'repo view') printf '%s\n' '{"url":"https://github.com/example/repository"}';;
          'api --method') cat .git/preview-response;;
          *) exit 2;;
        esac
        """#)
        try JSONSerialization.data(withJSONObject: response).write(to: URL(fileURLWithPath: repo.path + "/.git/preview-response"))
        repo.service.github.executable = executable
    }
    private var response: [String: Any] {
        ["number": 42, "html_url": "https://github.com/example/repository/pull/42", "title": "Source card metadata",
         "state": "closed", "draft": false, "created_at": "2026-10-31T10:00:00Z", "merged_at": "2026-10-31T12:00:00Z",
         "user": ["login": "author", "name": NSNull(), "avatar_url": "https://avatars.githubusercontent.com/u/123"]]
    }

    func testReadsExactSourceCardFieldsWithStructuredReadOnlyGitHubArguments() throws {
        let repo = try GitTestRepo(commit: true)
        try configure(repo, response: response)
        let action = GitPullRequestAction.preview(host: "github.com", repository: "example/repository", number: 42)
        guard case .pullRequestPreview(let preview) = try repo.git(.pullRequest(action)) else { return XCTFail("Expected card metadata") }
        XCTAssertEqual(preview.number, 42)
        XCTAssertEqual(preview.state, .merged)
        XCTAssertEqual(preview.createdAt, "2026-10-31T10:00:00Z")
        XCTAssertEqual(preview.author?.login, "author")
        XCTAssertNil(preview.author?.name)
        XCTAssertEqual(preview.author?.avatarURL, "https://avatars.githubusercontent.com/u/123")
        let calls = try repo.read(".git/preview-calls")
        XCTAssertTrue(calls.hasPrefix("api\n--method\nGET\n--hostname\ngithub.com\nrepos/example/repository/pulls/42\n--jq\n"))
        XCTAssertFalse(calls.contains("repo\nview"))
        XCTAssertTrue(GitService.isRead(.pullRequest(action)))
        XCTAssertEqual(try JSONDecoder().decode(GitPullRequestAction.self, from: JSONEncoder().encode(action)), action)
        let reply = GitReply.pullRequestPreview(preview)
        XCTAssertEqual(try JSONDecoder().decode(GitReply.self, from: JSONEncoder().encode(reply)), reply)
    }

    func testWrongTargetMalformedMetadataAndUnconfiguredHostAreRejected() throws {
        let repo = try GitTestRepo(commit: true)
        for (key, value) in [("number", 99 as Any), ("html_url", "https://github.com/other/repo/pull/42"), ("created_at", "unknown")] {
            var malformed = response; malformed[key] = value
            try configure(repo, response: malformed)
            XCTAssertThrowsError(try repo.git(.pullRequest(.preview(host: "github.com", repository: "example/repository", number: 42))))
        }
        try configure(repo, response: response)
        XCTAssertThrowsError(try repo.git(.pullRequest(.preview(host: "unconfigured.example", repository: "example/repository", number: 42))))
        for repository in ["../secret", "example/repo/extra", "--option/repo", "example/repo\n--method POST"] {
            XCTAssertThrowsError(try GitPullRequestPreview.validateTarget(host: "github.com", repository: repository, number: 42))
        }
        for host in ["https://github.com", "github.com/path", "github.com:443", "github.com\n--method"] {
            XCTAssertThrowsError(try GitPullRequestPreview.validateTarget(host: host, repository: "example/repository", number: 42))
        }
    }
    func testRepositoryMatchingMetadataStripsCredentialsWithoutChangingIdentity() throws {
        XCTAssertEqual(GitRepository.sanitizedOriginURL("https://token-user:secret@github.com/example/repository.git?access_token=secret#fragment"), "https://github.com/example/repository.git")
        XCTAssertEqual(GitRepository.sanitizedOriginURL("git@github.com:example/repository.git"), "ssh://github.com/example/repository.git")
        XCTAssertEqual(GitRepository.sanitizedOriginURL("ssh://git@github.com/example/repository.git"), "ssh://github.com/example/repository.git")
        XCTAssertNil(GitRepository.sanitizedOriginURL("/private/local/repository"))
        XCTAssertNil(GitRepository.sanitizedOriginURL("https://github.com/example/repository\nsecret"))
    }

}
