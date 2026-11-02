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
            // Font/color changes can split one citation or mention into multiple attributed runs.
            let continues = (attributes[.agentAssistantCitationIdentity] as? String).map { identity in
                range.location > 0 && text.attribute(.agentAssistantCitationIdentity, at: range.location - 1, effectiveRange: nil) as? String == identity
            } ?? false
            if let href = attributes[.agentAssistantCitation] as? String, let citation = AgentAssistantCitation.parse(href) {
                if !continues { result += citation.markdown }
            } else if let href = attributes[.agentThreadMention] as? String, let link = AgentThreadLink(href) {
                guard !continues else { return }
                var full = range
                if let identity = attributes[.agentAssistantCitationIdentity] as? String {
                    var end = NSMaxRange(range)
                    while end < text.length, text.attribute(.agentAssistantCitationIdentity, at: end, effectiveRange: nil) as? String == identity { end += 1 }
                    full.length = end - range.location
                }
                let label = (text.string as NSString).substring(with: full)
                result += link.markdown(title: label.hasPrefix("@") ? String(label.dropFirst()) : label)
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
            let marker: NSAttributedString.Key = attributes[.agentAssistantCitation] != nil ? .agentAssistantCitation : .agentThreadMention
            guard attributes[marker] != nil else { return }
            var full = NSRange()
            let key: NSAttributedString.Key = text.attribute(.agentAssistantCitationIdentity, at: found.location, effectiveRange: nil) == nil
                ? marker : .agentAssistantCitationIdentity
            _ = text.attribute(key, at: found.location, longestEffectiveRange: &full, in: whole)
            let interiorInsertion = range.length == 0 && range.location > full.location && range.location < NSMaxRange(full)
            if interiorInsertion || NSIntersectionRange(full, range).length > 0 { affected.append(full) }
        }
        for range in affected {
            text.removeAttribute(.agentAssistantCitation, range: range)
            text.removeAttribute(.agentThreadMention, range: range)
            text.removeAttribute(.agentAssistantCitationIdentity, range: range)
        }
    }
}

extension AgentPaneView {
    /// Replaces `range` with an `@Title` mention of another conversation, followed by a
    /// space; the draft sends it as a `tab-thread://` Markdown link.
    @discardableResult
    func insertThreadMention(_ link: AgentThreadLink, title: String, replacing range: NSRange) -> Bool {
        let label = "@" + AgentThreadLink.normalizedTitle(title)
        guard composer.isEditable, let storage = composer.textStorage, NSMaxRange(range) <= storage.length else { return false }
        let next = NSMaxRange(range) < storage.length ? (storage.string as NSString).substring(with: NSRange(location: NSMaxRange(range), length: 1)) : ""
        let addsSpace = next.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        guard composer.shouldChangeText(in: range, replacementString: label + (addsSpace ? " " : "")) else { return false }
        let content = NSMutableAttributedString(string: label, attributes: [
            .agentThreadMention: link.href, .agentAssistantCitationIdentity: UUID().uuidString,
            .font: AppFont.system(14, weight: .light), .foregroundColor: theme.accent,
            .backgroundColor: theme.accent.withAlphaComponent(0.10),
        ])
        if addsSpace {
            content.append(NSAttributedString(string: " ", attributes: [.font: AppFont.system(14, weight: .light), .foregroundColor: composer.textColor ?? theme.fg]))
        }
        storage.replaceCharacters(in: range, with: content)
        composer.setSelectedRange(NSRange(location: range.location + content.length + (addsSpace ? 0 : 1), length: 0))
        for key in [NSAttributedString.Key.agentThreadMention, .agentAssistantCitationIdentity, .backgroundColor] {
            composer.typingAttributes.removeValue(forKey: key)
        }
        composer.didChangeText()
        return true
    }

    @discardableResult
    func insertCitation(_ citation: AgentAssistantCitation) -> Bool {
        guard citation.isValid, citation.environmentId == citationEnvironmentId, citation.threadId == citationThreadId,
              composer.isEditable, let storage = composer.textStorage else { return false }
        let range = composer.selectedRange()
        guard composer.shouldChangeText(in: range, replacementString: AgentComposerCitation.label(for: citation)) else { return false }
        let label = AgentComposerCitation.label(for: citation)
        let content = NSAttributedString(string: label, attributes: [
            .agentAssistantCitation: citation.href, .agentAssistantCitationIdentity: UUID().uuidString,
            .font: AppFont.system(14, weight: .light), .foregroundColor: theme.accent,
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
