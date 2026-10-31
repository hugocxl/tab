import Foundation

/// Read-only metadata used by an existing in-message pull-request preview card.
public struct GitPullRequestPreview: Hashable, Codable, Sendable {
    public struct Author: Hashable, Codable, Sendable {
        public var login: String
        public var name: String?
        public var avatarURL: String?
        public init(login: String, name: String?, avatarURL: String?) { self.login = login; self.name = name; self.avatarURL = avatarURL }
    }
    public enum State: String, Hashable, Codable, Sendable { case open, closed, merged }
    public var repository: String
    public var number: UInt64
    public var title: String
    public var url: String
    public var author: Author?
    public var state: State
    public var isDraft: Bool
    public var createdAt: String

    public init(repository: String, number: UInt64, title: String, url: String, author: Author?, state: State, isDraft: Bool, createdAt: String) {
        self.repository = repository; self.number = number; self.title = title; self.url = url
        self.author = author; self.state = state; self.isDraft = isDraft; self.createdAt = createdAt
    }

    public static func validateTarget(host: String, repository: String, number: UInt64) throws(ErrorCode) {
        let hostname = host.utf8
        guard !hostname.isEmpty, hostname.count <= 253, host == host.lowercased(),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }), number > 0, number <= 9_007_199_254_740_991 else { throw .badRequest }
        let components = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components.allSatisfy({ part in
            !part.isEmpty && part.utf8.count <= 100 && part != "." && part != ".." && !part.hasPrefix("-") &&
            part.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
        }) else { throw .badRequest }
    }
}
