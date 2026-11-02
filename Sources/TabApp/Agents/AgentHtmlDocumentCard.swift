import AppKit
import TabProtocol

/// A tool result that carries a provider-supplied HTML document as a message-owned
/// attachment: an `html_render` output or an MCP app. Only the strict ownership checks of
/// `AgentConversationMcpAsset` decide whether an item has one.
struct AgentHtmlDocumentReference: Equatable {
    var itemID: String
    var attachmentID: String
    var byteCount: Int
    var toolName: String
    /// Set for MCP apps, which name their server and tool.
    var server: String?
    var tool: String?

    var isMcpApp: Bool { server != nil }
    /// The tool name, which is `server.tool` for an MCP app.
    var fallbackTitle: String { toolName }

    /// The document of a tool item, if it owns a matching HTML attachment.
    @MainActor
    static func find(in item: AgentChatItem) -> AgentHtmlDocumentReference? {
        guard item.kind == .tool else { return nil }
        for attachment in item.attachments ?? [] where attachment.mimeType.lowercased().hasPrefix("text/html") {
            if let match = AgentConversationMcpAsset.match(attachmentID: attachment.id, items: [item]) {
                return AgentHtmlDocumentReference(itemID: item.id, attachmentID: attachment.id, byteCount: attachment.byteCount,
                    toolName: match.ownership.toolName, server: match.reference["server"] as? String, tool: match.reference["tool"] as? String)
            }
            if let match = AgentConversationMcpAsset.htmlRenderCandidates(attachmentID: attachment.id, items: [item]).first {
                return AgentHtmlDocumentReference(itemID: item.id, attachmentID: attachment.id, byteCount: attachment.byteCount,
                    toolName: match.ownership.toolName)
            }
        }
        return nil
    }

    /// The document `<title>` read from at most the first 64 KiB, collapsed and trimmed.
    static func title(in data: Data) -> String? {
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        guard let open = text.range(of: "<title", options: [.caseInsensitive]),
              let close = text.range(of: ">", range: open.upperBound..<text.endIndex),
              let end = text.range(of: "</title", options: [.caseInsensitive], range: close.upperBound..<text.endIndex) else { return nil }
        let decoded = text[close.upperBound..<end.lowerBound]
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        let collapsed = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(120))
    }
}

/// The "HTML document" card of a tool row: title, size, and Open preview, Download and Copy source.
@MainActor
final class AgentHtmlDocumentCard: ThemedView {
    enum Action: Equatable { case preview, download, copySource }
    static let height: CGFloat = 56

    let preview = PillButton("Open preview", style: .primary)
    let download = PillButton("Download", style: .plain)
    let copy = PillButton("Copy source", style: .plain)
    private let icon = NSImageView()
    private let title = makeLabel("", font: AppFont.system(14, weight: .medium))
    private let detail = makeLabel("", font: AppFont.system(12))
    private(set) var reference: AgentHtmlDocumentReference?
    private(set) var isAvailable = false
    var onAction: ((Action) -> Void)?
    var titleText: String { title.stringValue }
    var detailText: String { detail.stringValue }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        icon.setAccessibilityElement(false)
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        for child in [icon, title, detail, preview, download, copy] { child.translatesAutoresizingMaskIntoConstraints = true; addSubview(child) }
        preview.onPress = { [weak self] in self?.onAction?(.preview) }
        download.onPress = { [weak self] in self?.onAction?(.download) }
        copy.onPress = { [weak self] in self?.onAction?(.copySource) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `documentTitle` is the parsed `<title>`; `available` is false while the tool is running
    /// or when the attachment is not retained.
    func update(_ reference: AgentHtmlDocumentReference, documentTitle: String?, available: Bool, theme: AppTheme) {
        self.reference = reference; isAvailable = available; self.theme = theme
        title.stringValue = documentTitle ?? reference.fallbackTitle
        var parts = ["HTML document", AgentFileAttachmentCard.formatBytes(reference.byteCount)]
        if let server = reference.server, let tool = reference.tool { parts.append("\(server) · \(tool)") }
        if !available { parts.append("Unavailable") }
        detail.stringValue = parts.joined(separator: " · ")
        for button in [preview, download, copy] { button.isEnabled = available }
        preview.setAccessibilityLabel("Open preview of " + title.stringValue)
        download.setAccessibilityLabel("Download " + title.stringValue)
        copy.setAccessibilityLabel("Copy source of " + title.stringValue)
        themeDidChange(); needsLayout = true
    }

    override func themeDidChange() {
        layer?.backgroundColor = theme.fg.withAlphaComponent(isAvailable ? 0.055 : 0.03).cgColor
        icon.image = FileIcon.image(for: "document.html", theme: theme, size: 18)
        icon.alphaValue = isAvailable ? 1 : 0.5
        title.textColor = isAvailable ? theme.fg : theme.fgMuted
        detail.textColor = isAvailable ? theme.fgMuted : theme.fgDim
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 14, y: (bounds.height - 20) / 2, width: 20, height: 20)
        let buttonY = (bounds.height - 24) / 2
        var right = bounds.width - 10
        for button in [copy, download, preview] {
            let width = max(60, ceil(button.fittingSize.width))
            right -= width
            button.frame = NSRect(x: right, y: buttonY, width: width, height: 24)
            right -= 4
        }
        let textX: CGFloat = 46
        let textWidth = max(1, right - textX)
        title.frame = NSRect(x: textX, y: 9, width: textWidth, height: 20)
        detail.frame = NSRect(x: textX, y: 30, width: textWidth, height: 16)
    }
}
