import AppKit
import TabProtocol

extension NSAttributedString.Key {
    static let agentAssistantCitationIdentity = NSAttributedString.Key("TabAssistantCitationIdentity")
    static let agentAssistantCitation = NSAttributedString.Key("TabAssistantCitation")
}

@MainActor
enum AgentComposerCitation {
    /// Visible labels stay short; the transmitted prompt retains the complete v1 selector.
    static func prompt(from text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            if let href = attributes[.agentAssistantCitation] as? String, let citation = AgentAssistantCitation.parse(href) {
                // Font/color changes can split one citation into multiple attributed runs.
                if let identity = attributes[.agentAssistantCitationIdentity] as? String, range.location > 0, text.attribute(.agentAssistantCitationIdentity, at: range.location - 1, effectiveRange: nil) as? String == identity { return }
                result += citation.markdown
            } else { result += (text.string as NSString).substring(with: range) }
        }
        return result
    }

    static func label(for citation: AgentAssistantCitation) -> String {
        let value = AgentConversationSelectionSelector.normalize(citation.comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? citation.comment ?? citation.text : citation.text)
        let preview = value.utf16.count > 64 ? String((value as NSString).substring(to: 64)) + "…" : value
        return "❝ " + preview + " ❞"
    }

    /// Once a citation label is edited it becomes ordinary user text, rather than
    /// silently sending an unchanged hidden quotation after the user's edit.
    static func prepareEdit(in text: NSTextStorage?, range: NSRange) {
        guard let text, text.length > 0 else { return }
        var affected: [NSRange] = []
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttributes(in: whole) { attributes, found, _ in
            guard attributes[.agentAssistantCitation] != nil else { return }
            var full = NSRange()
            let key: NSAttributedString.Key = text.attribute(.agentAssistantCitationIdentity, at: found.location, effectiveRange: nil) == nil
                ? .agentAssistantCitation : .agentAssistantCitationIdentity
            _ = text.attribute(key, at: found.location, longestEffectiveRange: &full, in: whole)
            let interiorInsertion = range.length == 0 && range.location > full.location && range.location < NSMaxRange(full)
            if interiorInsertion || NSIntersectionRange(full, range).length > 0 { affected.append(full) }
        }
        for range in affected {
            text.removeAttribute(.agentAssistantCitation, range: range)
            text.removeAttribute(.agentAssistantCitationIdentity, range: range)
        }
    }
}

extension AgentPaneView {
    @discardableResult
    func insertCitation(_ citation: AgentAssistantCitation) -> Bool {
        guard citation.isValid, citation.environmentId == citationEnvironmentId, citation.threadId == citationThreadId,
              composer.isEditable, let storage = composer.textStorage else { return false }
        let range = composer.selectedRange()
        guard composer.shouldChangeText(in: range, replacementString: AgentComposerCitation.label(for: citation)) else { return false }
        let label = AgentComposerCitation.label(for: citation)
        let content = NSAttributedString(string: label, attributes: [
            .agentAssistantCitation: citation.href, .agentAssistantCitationIdentity: UUID().uuidString,
            .font: AppFont.system(14), .foregroundColor: theme.accent,
            .backgroundColor: theme.accent.withAlphaComponent(0.10),
        ])
        storage.replaceCharacters(in: range, with: content)
        composer.setSelectedRange(NSRange(location: range.location + content.length, length: 0))
        composer.typingAttributes.removeValue(forKey: .agentAssistantCitation)
        composer.typingAttributes.removeValue(forKey: .agentAssistantCitationIdentity)
        composer.didChangeText()
        window?.makeFirstResponder(composer)
        return true
    }
}
