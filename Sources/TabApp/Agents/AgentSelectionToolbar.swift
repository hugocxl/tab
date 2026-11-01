import AppKit
import QuartzCore
import TabProtocol

/// A small floating pill with Cite and Copy, shown above a finished selection in an
/// assistant message. Its buttons never take focus, so the selection stays active.
@MainActor
final class AgentSelectionToolbar: ThemedView {
    let cite = PillButton("Cite", style: .plain)
    let copy = PillButton("Copy", style: .plain)
    private let divider = NSView()
    var onCite: (() -> Void)?
    var onCopy: (() -> Void)?
    /// The text view whose selection placed the toolbar.
    weak var source: AgentRichTextView?
    static let size = NSSize(width: 116, height: 30)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (button, label) in [(cite, "Cite selection in the message"), (copy, "Copy selection")] {
            button.translatesAutoresizingMaskIntoConstraints = true
            button.font = AppFont.small
            button.refusesFirstResponder = true
            button.toolTip = label
            button.setAccessibilityLabel(label)
            addSubview(button)
        }
        cite.image = NSImage(systemSymbolName: "quote.opening", accessibilityDescription: nil)
        cite.imagePosition = .imageLeading
        cite.onPress = { [weak self] in self?.onCite?() }
        copy.onPress = { [weak self] in self?.onCopy?() }
        divider.wantsLayer = true
        addSubview(divider)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Selection actions")
        layer?.cornerRadius = Self.size.height / 2
        layer?.borderWidth = Metrics.border
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        themeDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let half = floor(bounds.width / 2)
        cite.frame = NSRect(x: 4, y: 3, width: half - 4, height: bounds.height - 6)
        divider.frame = NSRect(x: half, y: 8, width: 1, height: max(0, bounds.height - 16))
        copy.frame = NSRect(x: half + 1, y: 3, width: bounds.width - half - 5, height: bounds.height - 6)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.floating.cgColor
        layer?.borderColor = theme.fg.withAlphaComponent(0.12).cgColor
    }

    override func themeDidChange() {
        cite.setTitleColor(theme.fg)
        copy.setTitleColor(theme.fg)
        cite.contentTintColor = theme.accent
        divider.layer?.backgroundColor = theme.fg.withAlphaComponent(0.14).cgColor
        needsDisplay = true
    }
}

// MARK: - Selection actions

extension AgentPaneView: AgentTextSelectionHost {
    /// How long a followed citation stays highlighted before it fades.
    static let citationHighlightDuration: TimeInterval = 1.5

    func textSelectionWillBegin(in view: AgentRichTextView, extending: Bool) {
        hideSelectionToolbar()
        guard !extending else { return }
        // One selection at a time unless Shift or Command adds another section to it.
        for text in AgentTranscriptSelection.textViews(in: transcript) where text !== view && text.selectedRange().length > 0 {
            text.setSelectedRange(NSRange(location: text.selectedRange().location, length: 0))
        }
    }

    func textSelectionDidEnd(in view: AgentRichTextView) {
        showSelectionToolbar(for: view)
    }

    func textSelectionDidCollapse(in view: AgentRichTextView) {
        guard selectionToolbar.source === view else { return }
        hideSelectionToolbar()
    }

    func textSelectionMenuItems(for view: AgentRichTextView) -> [NSMenuItem] {
        guard isAssistantText(view), view.selectedRange().length > 0 else { return [] }
        let selection = AgentTranscriptSelection.collect(in: transcript)
        guard !selection.isEmpty else { return [] }
        let cite = NSMenuItem(title: "Cite", action: #selector(citeSelectionAction), keyEquivalent: "")
        cite.target = self
        cite.isEnabled = canCite(selection)
        let copy = NSMenuItem(title: "Copy", action: #selector(copySelectionAction), keyEquivalent: "")
        copy.target = self
        let markdown = NSMenuItem(title: "Copy as Markdown", action: #selector(copySelectionAsMarkdownAction), keyEquivalent: "")
        markdown.target = self
        return [cite, copy, markdown]
    }

    func copyTextSelection(from view: AgentRichTextView) -> Bool {
        guard isAssistantText(view), view.selectedRange().length > 0 else { return false }
        return copySelection()
    }

    func transcriptDidPressEscape() -> Bool {
        if !selectionToolbar.isHidden {
            hideSelectionToolbar()
            return true
        }
        return performFind(.close)
    }

    /// Shows Cite and Copy above `view`'s selection when it lies in an assistant message.
    func showSelectionToolbar(for view: AgentRichTextView) {
        let selection = AgentTranscriptSelection.collect(in: transcript)
        guard isAssistantText(view), !selection.isEmpty, let rect = selectionRect(in: view) else {
            hideSelectionToolbar()
            return
        }
        let anchor = convert(rect, from: view)
        let visible = transcriptScroll.frame
        let size = AgentSelectionToolbar.size
        let x = min(max(visible.minX + 8, anchor.midX - size.width / 2), max(visible.minX + 8, visible.maxX - size.width - 8))
        var y = anchor.minY - size.height - 6
        if y < visible.minY + 4 { y = anchor.maxY + 6 }
        y = min(max(visible.minY + 4, y), max(visible.minY + 4, visible.maxY - size.height - 4))
        selectionToolbar.frame = NSRect(origin: NSPoint(x: floor(x), y: floor(y)), size: size)
        selectionToolbar.cite.isEnabled = canCite(selection)
        selectionToolbar.source = view
        selectionToolbar.isHidden = false
    }

    func hideSelectionToolbar() {
        guard !selectionToolbar.isHidden else { return }
        selectionToolbar.isHidden = true
        selectionToolbar.source = nil
    }

    /// Inserts the selection, when it lies within one assistant message, as a composer quotation.
    @discardableResult
    func citeSelection() -> Bool {
        let selection = AgentTranscriptSelection.collect(in: transcript)
        guard let citation = citation(for: selection) else { return false }
        hideSelectionToolbar()
        return actions.cite(citation)
    }

    /// Copies plain text, HTML and, within one message, a context fragment.
    @discardableResult
    func copySelection() -> Bool {
        let selection = AgentTranscriptSelection.collect(in: transcript)
        guard !selection.isEmpty else { return false }
        var flavors: [String: String] = [:]
        if let message = selection.citable, let environment = citationEnvironmentId, let thread = citationThreadId,
           let json = AgentContextFragment(environmentId: environment, threadId: thread, messageId: message.item.id, text: selection.plainText).json {
            flavors[AgentContextFragment.mime] = json
        }
        hideSelectionToolbar()
        do { try actions.copy(text: selection.plainText, html: selection.html, flavors: flavors) } catch {
            onActionError?(error.localizedDescription)
            return false
        }
        return true
    }

    /// Copies the original Markdown of the selected range of each message.
    @discardableResult
    func copySelectionAsMarkdown() -> Bool {
        let selection = AgentTranscriptSelection.collect(in: transcript)
        guard !selection.isEmpty else { return false }
        let markdown = selection.markdown
        hideSelectionToolbar()
        do { try actions.copy(text: markdown, flavors: ["web text/markdown": markdown]) } catch {
            onActionError?(error.localizedDescription)
            return false
        }
        return true
    }

    @objc private func citeSelectionAction() { citeSelection() }
    @objc private func copySelectionAction() { copySelection() }
    @objc private func copySelectionAsMarkdownAction() { copySelectionAsMarkdown() }

    func citation(for selection: AgentTranscriptSelection) -> AgentAssistantCitation? {
        guard let message = selection.citable, let environment = citationEnvironmentId, let thread = citationThreadId,
              let citation = AgentConversationSelectionSelector.citation(in: message.map.plainText, range: message.span,
                  environmentId: environment, threadId: thread, messageId: message.item.id),
              citation.isValid else { return nil }
        return citation
    }

    private func canCite(_ selection: AgentTranscriptSelection) -> Bool {
        composer.isEditable && citation(for: selection) != nil
    }

    private func isAssistantText(_ view: AgentRichTextView) -> Bool {
        var ancestor = view.superview
        while let current = ancestor, current !== self {
            if let row = current as? AgentMessageRow { return row.assistantItem != nil }
            ancestor = current.superview
        }
        return false
    }

    private func selectionRect(in view: AgentRichTextView) -> NSRect? {
        guard let range = view.selectedRanges.map(\.rangeValue).first(where: { $0.length > 0 }),
              let layoutManager = view.layoutManager, let container = view.textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += view.textContainerOrigin.x
        rect.origin.y += view.textContainerOrigin.y
        return rect.intersection(view.visibleRect).isEmpty ? nil : rect
    }

    // MARK: Citations

    /// Follows a quotation: in this conversation it scrolls to and highlights the quote;
    /// otherwise it opens the cited conversation, which reports an unavailable message.
    func openCitation(_ citation: AgentAssistantCitation) {
        if citation.threadId == citationThreadId, citation.environmentId == citationEnvironmentId,
           snapshot?.items.contains(where: { $0.id == citation.messageId && $0.kind == .assistant }) == true {
            if !revealCitation(citation) { onActionError?("The quoted text could not be located in this conversation.") }
            return
        }
        Task { [weak self] in
            do { try await self?.actions.navigateCitation(citation) } catch {
                self?.onActionError?(error.localizedDescription)
            }
        }
    }

    /// Scrolls to the cited assistant message and briefly highlights the quotation. When the
    /// quote is no longer found the message is still shown, without a highlight, and this
    /// returns false; a message that is not retained returns false without scrolling.
    @discardableResult
    func revealCitation(_ citation: AgentAssistantCitation) -> Bool {
        guard citation.isValid, let snapshot, citation.threadId == snapshot.session.description,
              let message = snapshot.items.first(where: { $0.id == citation.messageId && $0.kind == .assistant }) else { return false }
        clearCitationHighlight()
        guard reveal(.item(message.id)) else { return false }
        guard let row = transcript.messageRow(for: message.id) else {
            return AgentConversationSelectionSelector.find(citation, in: message.text) != nil
        }
        let map = row.textMap
        guard let range = AgentConversationSelectionSelector.findInSource(citation, in: map.plainText) else {
            return AgentConversationSelectionSelector.find(citation, in: message.text) != nil
        }
        let parts = map.viewRanges(for: range)
        // Bring the quote itself into view when it starts below the first half of the viewport.
        if let first = parts.first, let rect = Self.rect(of: first.range, in: first.view) {
            let top = row.convert(rect, from: first.view).minY
            if top > transcriptScroll.contentSize.height / 2 { reveal(.item(message.id), offset: max(0, top - 48)) }
        }
        highlightCitation(parts)
        return true
    }

    /// Applies an accent background to the quotation, removed with a fade after a moment.
    func highlightCitation(_ parts: [(view: AgentRichTextView, range: NSRange)]) {
        clearCitationHighlight()
        let color = theme.accent.withAlphaComponent(0.28)
        for part in parts {
            part.view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: part.range)
        }
        citationHighlight = parts
        let generation = citationHighlightGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.citationHighlightDuration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.citationHighlightGeneration == generation else { return }
                self.clearCitationHighlight(animated: true)
            }
        }
    }

    /// Removes the quotation highlight; a pending fade for an earlier highlight is cancelled.
    func clearCitationHighlight(animated: Bool = false) {
        citationHighlightGeneration &+= 1
        for part in citationHighlight {
            guard let layoutManager = part.view.layoutManager, NSMaxRange(part.range) <= (part.view.textStorage?.length ?? 0) else { continue }
            if animated, let layer = part.view.layer {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.35
                layer.add(fade, forKey: "citationHighlight")
            }
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: part.range)
        }
        citationHighlight = []
    }

    private static func rect(of range: NSRange, in view: AgentRichTextView) -> NSRect? {
        guard let layoutManager = view.layoutManager, let container = view.textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += view.textContainerOrigin.x
        rect.origin.y += view.textContainerOrigin.y
        return rect
    }

    /// Text copied from an assistant message of this conversation pastes as a quotation of it.
    func pasteContextFragment(from pasteboard: NSPasteboard) -> Bool {
        guard let fragment = AgentContextFragment.read(from: pasteboard), fragment.environmentId == citationEnvironmentId,
              fragment.threadId == citationThreadId,
              let item = snapshot?.items.first(where: { $0.id == fragment.messageId && $0.kind == .assistant }) else { return false }
        // Only when the clipboard still holds the copied text, not something written over it.
        if let plain = pasteboard.string(forType: .string), plain != fragment.text { return false }
        let map = transcript.messageRow(for: item.id).map(\.textMap) ?? AgentMessageTextMap.render(item.text, theme: theme)
        let text = map.plainText as NSString
        let found = text.range(of: fragment.text)
        guard found.location != NSNotFound,
              text.range(of: fragment.text, options: [], range: NSRange(location: found.location + 1, length: text.length - found.location - 1)).location == NSNotFound,
              let citation = AgentConversationSelectionSelector.citation(in: map.plainText, range: found, environmentId: fragment.environmentId,
                  threadId: fragment.threadId, messageId: fragment.messageId) else { return false }
        return insertCitation(citation)
    }
}
