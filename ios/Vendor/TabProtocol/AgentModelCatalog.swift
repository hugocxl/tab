import Foundation

public struct AgentModelCatalogRequest: Hashable, Codable, Sendable {
    public var project: ProjectId
    public var provider: AgentChatProvider
    public var forceRefresh: Bool

    public init(project: ProjectId, provider: AgentChatProvider, forceRefresh: Bool = false) {
        self.project = project
        self.provider = provider
        self.forceRefresh = forceRefresh
    }

    private enum CodingKeys: String, CodingKey { case project, provider, forceRefresh }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(ProjectId.self, forKey: .project)
        provider = try container.decode(AgentChatProvider.self, forKey: .provider)
        forceRefresh = try container.decodeIfPresent(Bool.self, forKey: .forceRefresh) ?? false
    }
}

public struct AgentModelDescriptor: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var resolvedModel: String?
    public var isDefault: Bool
    public var reasoningEfforts: [AgentReasoningEffort]
    public var defaultReasoningEffort: AgentReasoningEffort?

    public init(id: String, title: String, reasoningEfforts: [AgentReasoningEffort],
                defaultReasoningEffort: AgentReasoningEffort? = nil, resolvedModel: String? = nil,
                isDefault: Bool = false) {
        self.id = id
        self.title = title
        self.resolvedModel = resolvedModel
        self.isDefault = isDefault
        self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, resolvedModel, isDefault, reasoningEfforts, defaultReasoningEffort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        resolvedModel = try container.decodeIfPresent(String.self, forKey: .resolvedModel)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        reasoningEfforts = try container.decode([AgentReasoningEffort].self, forKey: .reasoningEfforts)
        defaultReasoningEffort = try container.decodeIfPresent(AgentReasoningEffort.self, forKey: .defaultReasoningEffort)
    }
}

public struct AgentModelCatalogReply: Hashable, Codable, Sendable {
    public static let maxModels = 256
    public var models: [AgentModelDescriptor]
    /// Discovery mechanism only; never contains account identity or filesystem paths.
    public var source: String?

    public init(models: [AgentModelDescriptor], source: String? = nil) {
        self.models = models
        self.source = source
    }

    public func validate() throws(ErrorCode) {
        guard models.count <= Self.maxModels, (source?.utf8.count ?? 0) <= 64 else { throw .badRequest }
        var ids = Set<String>()
        for model in models {
            guard !model.id.isEmpty, model.id.utf8.count <= 256, !model.id.utf8.contains(0),
                  !model.title.isEmpty, model.title.utf8.count <= 512, !model.title.utf8.contains(0),
                  (model.resolvedModel?.utf8.count ?? 0) <= 256,
                  model.resolvedModel?.utf8.contains(0) != true,
                  model.reasoningEfforts.count <= 32,
                  Set(model.reasoningEfforts).count == model.reasoningEfforts.count,
                  ids.insert(model.id).inserted else { throw .badRequest }
            for effort in model.reasoningEfforts { try effort.validate() }
            try model.defaultReasoningEffort?.validate()
        }
    }
}
