import AppKit

/// Appends a template prompt to the composer draft; existing attributed draft
/// content is retained and no provider request is sent by this action.
@MainActor
enum AgentConversationTemplateAction {
    /// The draft as it would be sent, citations expanded to their links.
    static func prompt(surface: AgentPaneView) throws -> String {
        guard surface.composer.isEditable else { throw ModelError("The composer is busy; try again once it is ready.") }
        return AgentComposerCitation.prompt(from: surface.composer.attributedString())
    }

    /// Appends `text` only when the draft still equals `expectedPrompt`.
    static func append(_ text: String, expectedPrompt: String, surface: AgentPaneView) throws {
        guard try prompt(surface: surface) == expectedPrompt else {
            throw ModelError("The composer draft changed; try adding the template again.")
        }
        if !text.isEmpty {
            let range = NSRange(location: (surface.composer.string as NSString).length, length: 0)
            guard surface.composer.shouldChangeText(in: range, replacementString: text), let storage = surface.composer.textStorage else {
                throw ModelError("The composer is busy; try again once it is ready.")
            }
            var attributes = surface.composer.typingAttributes
            attributes.removeValue(forKey: .agentAssistantCitation)
            attributes.removeValue(forKey: .agentAssistantCitationIdentity)
            attributes.removeValue(forKey: .agentThreadMention)
            attributes.removeValue(forKey: .backgroundColor)
            attributes[.foregroundColor] = surface.composer.textColor ?? surface.theme.fg
            storage.append(NSAttributedString(string: text, attributes: attributes))
            surface.composer.typingAttributes = attributes
            surface.composer.setSelectedRange(NSRange(location: storage.length, length: 0))
            surface.composer.didChangeText()
            surface.refreshComposer()
        }
        surface.window?.makeFirstResponder(surface.composer)
    }
}
