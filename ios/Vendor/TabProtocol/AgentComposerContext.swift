import Foundation

/// Lists server-local skills for the selected project's composer. No arbitrary path reads.
public struct AgentComposerContextRequest: Hashable, Codable, Sendable {
    public var project: ProjectId
    public var provider: AgentChatProvider

    public init(project: ProjectId, provider: AgentChatProvider) {
        self.project = project
        self.provider = provider
    }
}

public struct AgentComposerSkill: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var path: ServerPath
    /// Full skill text, including frontmatter, bounded to 32 KiB UTF-8.
    public var instructions: String

    public init(id: String, name: String, description: String, path: ServerPath, instructions: String) {
        self.id = id
        self.name = name
        self.description = description
        self.path = path
        self.instructions = instructions
    }
}

public struct AgentComposerContextReply: Hashable, Codable, Sendable {
    public static let maxSkills = 128
    public static let maxInstructionBytes = 32 * 1024
    /// Includes metadata and instructions (before JSON escaping).
    public static let maxCatalogBytes = 128 * 1024
    public var skills: [AgentComposerSkill]
    /// Some entries were omitted because discovery or content limits were reached.
    public var truncated: Bool

    public init(skills: [AgentComposerSkill], truncated: Bool = false) {
        self.skills = skills
        self.truncated = truncated
    }

    public func validate() throws(ErrorCode) {
        guard skills.count <= Self.maxSkills else { throw .badRequest }
        var total = 0
        var ids = Set<String>()
        for skill in skills {
            try skill.path.validateAbsolute()
            guard !skill.id.isEmpty, skill.id.utf8.count <= 4096,
                  !skill.name.isEmpty, skill.name.utf8.count <= 128,
                  skill.name.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.contains($0) || "-_.:".unicodeScalars.contains($0)
                  }), skill.description.utf8.count <= 2048,
                  !skill.instructions.isEmpty, !skill.instructions.utf8.contains(0),
                  skill.instructions.utf8.count <= Self.maxInstructionBytes,
                  ids.insert(skill.id).inserted else { throw .badRequest }
            total += skill.id.utf8.count + skill.name.utf8.count + skill.description.utf8.count
                + skill.path.byteCount + skill.instructions.utf8.count
            if total > Self.maxCatalogBytes { throw .badRequest }
        }
    }
}
