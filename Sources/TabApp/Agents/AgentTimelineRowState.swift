import AppKit

/// Lightweight interaction state survives eviction of a row's expensive native views.
struct AgentTimelineRowState {
    var expanded = false
    var expandedDirectories: Set<String> = []
    var toolExpandedIDs: Set<String> = []
    var responseState: AgentResponseState? = nil
    var wrappedCodeSections: Set<Int>? = nil
    var children: [String: AgentTimelineRowState] = [:]
    var argumentScrollOffset: NSPoint = .zero
    var scrollOffset: NSPoint = .zero
}

struct AgentResponseState {
    var wrapped: Bool? = nil
    var expanded: Bool? = nil
    var children: [Int: AgentResponseState] = [:]
}
