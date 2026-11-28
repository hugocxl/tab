import Foundation
import TabProtocol

/// Normalizes provider question schemas without guessing answers or selecting defaults.
enum AgentQuestionParser {
    static func parse(_ input: [String: Any], claude: Bool) throws -> AgentQuestionnaire {
        guard let questions = input["questions"] as? [[String: Any]] else {
            throw AgentRuntimeError("The provider sent a question form without questions.")
        }
        let form = AgentQuestionnaire(questions: try questions.enumerated().map { index, raw in
            guard let title = raw["question"] as? String else { throw AgentRuntimeError("A provider question has no title.") }
            let id = claude ? title : raw["id"] as? String ?? String(index)
            let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentQuestionnaire.Option? in
                guard let label = option["label"] as? String else { return nil }
                return .init(label: label, description: option["description"] as? String)
            }
            return .init(id: id, title: title, options: options, multiple: raw["multiSelect"] as? Bool ?? false,
                         secret: raw["isSecret"] as? Bool ?? false, required: raw["required"] as? Bool ?? true,
                         header: header(raw["header"]))
        })
        try form.validate()
        return form
    }

    /// A header is decoration: one the form can't show is dropped rather than failing the form.
    private static func header(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.utf8.count <= 256, !text.contains("\0") else { return nil }
        return text
    }
}
