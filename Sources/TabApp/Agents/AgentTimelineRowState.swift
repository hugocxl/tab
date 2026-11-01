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
    /// A diagram section shows its Mermaid source instead of the drawing.
    var showsSource: Bool? = nil
    var children: [Int: AgentResponseState] = [:]
}
