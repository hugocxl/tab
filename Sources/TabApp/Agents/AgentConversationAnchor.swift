import Foundation

/// A source row identity, not a shared pixel coordinate system. The fallback
/// resolves this against its current retained rows after materializing data.
struct AgentConversationAnchor {
    var messageID: String?
    var itemID: String?
    var runID: String?
    var offset: CGFloat

    init?(_ payload: [String: Any]) {
        func identity(_ name: String) -> String? {
            guard let value = payload[name] as? String, !value.isEmpty, value.utf8.count <= 4096,
                  !value.contains("\0") else { return nil }
            return value
        }
        messageID = identity("messageId"); itemID = identity("itemId"); runID = identity("runId")
        guard messageID != nil || itemID != nil || runID != nil else { return nil }
        let value = (payload["offset"] as? NSNumber)?.doubleValue ?? 0
        offset = value.isFinite ? max(0, min(1_000_000, value)) : 0
    }
}
