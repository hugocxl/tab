import Foundation

/// Source list identity is independent of its painted marker (notably for tasks).
/// IDs are source line offsets within one parser invocation and remain stable while streaming.
struct AgentListItemStructure: Equatable {
    let id: Int
    let parentID: Int?
    let delimiter: Character
    let start: Int?
    let number: Int?
    var lastNumber: Int? = nil
    var ancestors: [Bool] = []
    var isLoose: Bool = false
}

extension AgentMarkdown.Block {
    var listStructure: AgentListItemStructure? {
        switch self {
        case .list(_, _, _, let structure), .listBlock(_, _, _, let structure): return structure
        case .nested(.list(_, _, _, let structure), _): return structure
        default: return nil
        }
    }
}
