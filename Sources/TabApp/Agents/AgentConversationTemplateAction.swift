import AppKit

/// Only the body card's source-generated prompt is appended; existing attributed
/// draft content is retained and no provider request is sent by this action.
@MainActor
enum AgentConversationTemplateAction {
    static func perform(_ payload: [String: Any], surface: AgentPaneView) throws -> Any {
        guard surface.composer.isEditable else { throw ModelError("The composer is busy; try again once it is ready.") }
        let current = AgentComposerCitation.prompt(from: surface.composer.attributedString())
        if payload["phase"] as? String == "read" { return ["prompt": current] }
        guard payload["phase"] as? String == "append", let expected = payload["expectedPrompt"] as? String,
              let appended = payload["append"] as? String, expected == current else {
            throw ModelError("The composer draft changed; try adding the template again.")
        }
        if !appended.isEmpty {
            let range = NSRange(location: (surface.composer.string as NSString).length, length: 0)
            guard surface.composer.shouldChangeText(in: range, replacementString: appended), let storage = surface.composer.textStorage else {
                throw ModelError("The composer is busy; try again once it is ready.")
            }
            var attributes = surface.composer.typingAttributes
            attributes.removeValue(forKey: .agentAssistantCitation)
            attributes.removeValue(forKey: .agentAssistantCitationIdentity)
            attributes.removeValue(forKey: .backgroundColor)
            attributes[.foregroundColor] = surface.composer.textColor ?? surface.theme.fg
            storage.append(NSAttributedString(string: appended, attributes: attributes))
            surface.composer.typingAttributes = attributes
            surface.composer.setSelectedRange(NSRange(location: storage.length, length: 0))
            surface.composer.didChangeText()
            surface.refreshComposer()
        }
        surface.window?.makeFirstResponder(surface.composer)
        return true
    }
}
