import AppKit

/// Lightweight interaction state survives eviction of a row's expensive native views.
struct AgentTimelineRowState {
    var expanded = false
    var toolExpandedIDs: Set<String> = []
    var wrappedCodeSections: Set<Int> = []
    var children: [String: AgentTimelineRowState] = [:]
    var scrollOffset: NSPoint = .zero
}
