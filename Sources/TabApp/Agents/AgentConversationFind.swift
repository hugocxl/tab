import AppKit
import TabCore

extension AgentPaneController {
    /// Application menu/keymap actions use the same find state as the source bar.
    @MainActor
    func performConversationShortcut(_ id: ShortcutId) -> Bool {
        let action: String
        switch id {
        case .find: action = "open"
        case .findNext: action = "next"
        case .findPrevious: action = "previous"
        default: return false
        }
        let host = surface.conversationWebView
        guard surface.usesWebConversation, host.isReady, !surface.isConversationModal else { return false }
        surface.window?.makeFirstResponder(host.webView)
        Task { [weak host] in
            guard let host else { return }
            do {
                let handled = try await host.evaluate("return window.TabConversation.find?.(action) ?? false", arguments: ["action": action])
                if handled as? Bool != true {
                    host.onActionFailure?(ModelError("Conversation search is unavailable."))
                }
            } catch {
                host.onActionFailure?(error)
            }
        }
        return true
    }
}
