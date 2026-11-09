import Foundation

/// A client-generated identity is retained across retries, including reconnects.
public struct AgentPrompt: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var model: String?
    public var effort: AgentReasoningEffort?
    public var provider: AgentChatProvider
    public var planMode: Bool
    public var attachments: [AgentChatAttachment]
    public init(id: String = UUID().uuidString, text: String, model: String?, effort: AgentReasoningEffort?,
                provider: AgentChatProvider, planMode: Bool, attachments: [AgentChatAttachment] = []) {
        self.id = id; self.text = text; self.model = model; self.effort = effort
        self.provider = provider; self.planMode = planMode; self.attachments = attachments
    }
    public func validate() throws(ErrorCode) {
        guard UUID(uuidString: id) != nil else { throw .badRequest }
        try AgentChatRequest.send(session: SessionId(), text: text, model: model, reasoningEffort: effort,
                                  provider: provider, attachments: attachments).validate()
    }
}

/// Payload-free queue metadata is shared by all clients of the conversation.
public struct AgentQueuedPrompt: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case queued, delivering, uncertain, failed }
    public var id: String
    public var text: String
    public var attachments: [AgentChatAttachmentDescriptor]
    public var state: State
    public var revision: UInt64
    public var error: String?
    public init(prompt: AgentPrompt, state: State = .queued, revision: UInt64 = 0, error: String? = nil) {
        id = prompt.id; text = prompt.text; attachments = prompt.attachments.map(\.descriptor)
        self.state = state; self.revision = revision; self.error = error
    }
}

public struct AgentQuestionnaire: Codable, Hashable, Sendable {
    public struct Option: Codable, Hashable, Sendable {
        public var label: String
        public var description: String?
        public init(label: String, description: String? = nil) { self.label = label; self.description = description }
    }
    public struct Question: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var options: [Option]
        public var multiple: Bool
        public var secret: Bool
        public var required: Bool
        public init(id: String, title: String, options: [Option] = [], multiple: Bool = false,
                    secret: Bool = false, required: Bool = true) {
            self.id = id; self.title = title; self.options = options; self.multiple = multiple
            self.secret = secret; self.required = required
        }
    }
    public var questions: [Question]
    public init(questions: [Question]) { self.questions = questions }
    public func validate() throws(ErrorCode) {
        guard transcriptByteCount <= 64 * 1024, !questions.isEmpty, questions.count <= 12, Set(questions.map(\.id)).count == questions.count else { throw .badRequest }
        for q in questions {
            try Validation.message(q.id, limit: 1024)
            try Validation.message(q.title, limit: 8192)
            guard q.options.count <= 32, Set(q.options.map(\.label)).count == q.options.count else { throw .badRequest }
            for option in q.options {
                try Validation.message(option.label, limit: 4096)
                if let description = option.description { try Validation.message(description, limit: 8192) }
            }
        }
    }
    public func validate(answers: [String: [String]], cancelled: Bool) throws(ErrorCode) {
        guard Set(answers.keys).isSubset(of: Set(questions.map(\.id))) else { throw .badRequest }
        if cancelled { return }
        for question in questions {
            let values = answers[question.id] ?? []
            guard values.count <= (question.multiple ? 32 : 1),
                  !question.required || !values.isEmpty else { throw .badRequest }
            for value in values { try Validation.message(value, limit: 16 * 1024) }
        }
    }
}

extension AgentQuestionnaire {
    public var transcriptByteCount: Int {
        questions.reduce(128) { bytes, question in
            bytes + 128 + question.id.utf8.count + question.title.utf8.count
                + question.options.reduce(0) { $0 + 64 + $1.label.utf8.count + ($1.description?.utf8.count ?? 0) }
        }
    }
}

/// Optional replacement settings when editing a pending prompt; attachments stay server-owned.
public struct AgentQueuedSettings: Codable, Hashable, Sendable {
    public var model: String?
    public var effort: AgentReasoningEffort?
    public var planMode: Bool
    public init(model: String?, effort: AgentReasoningEffort?, planMode: Bool) {
        self.model = model; self.effort = effort; self.planMode = planMode
    }
}
