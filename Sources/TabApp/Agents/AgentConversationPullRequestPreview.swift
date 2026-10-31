import Foundation
import CoreFoundation
import TabProtocol

/// Translates the existing source card's scoped input and result, without exposing
/// generic API requests, credentials, PR mutations or other project operations.
@MainActor
enum AgentConversationPullRequestPreview {
    static func perform(_ payload: [String: Any], project: ProjectId,
                        request: (GitRequest) async throws -> GitReply) async throws -> [String: Any] {
        let input = payload["input"] as? [String: Any] ?? payload
        guard payload["environmentId"] as? String == project.description,
              input["projectId"] as? String == project.description,
              let repository = input["repository"] as? String,
              let value = input["number"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
              value.doubleValue >= 1, value.doubleValue <= 9_007_199_254_740_991,
              value.doubleValue.rounded(.towardZero) == value.doubleValue else {
            throw ModelError("This pull-request preview does not belong to the conversation’s project.")
        }
        guard input["expectedAccountId"] == nil else {
            throw ModelError("Tab uses the project server’s GitHub CLI account for this preview.")
        }
        let host = input["host"] as? String ?? "github.com", number = value.uint64Value
        try GitPullRequestPreview.validateTarget(host: host, repository: repository, number: number)
        let reply = try await request(.init(project: project, action: .pullRequest(.preview(host: host, repository: repository, number: number))))
        try Task.checkCancellation()
        guard case .pullRequestPreview(let preview) = reply, preview.number == number,
              preview.repository.lowercased() == repository.lowercased() else {
            throw ModelError("The project server returned an unrelated pull-request preview.")
        }
        var author: Any = NSNull()
        if let value = preview.author { author = ["login": value.login, "name": value.name as Any? ?? NSNull(), "avatarUrl": value.avatarURL as Any? ?? NSNull()] }
        return ["projectId": project.description, "repository": preview.repository, "number": preview.number,
                "title": preview.title, "url": preview.url, "author": author,
                "state": preview.state.rawValue, "isDraft": preview.isDraft, "createdAt": preview.createdAt]
    }
}
