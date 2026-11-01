import AppKit

/// The tooltip text and missing-file styling of project file links in assistant Markdown.
@MainActor
enum AgentFileLinkTooltip {
    typealias State = AgentLazyRequestCache<AgentConversationLinkServices.FileMetadata>.State

    /// The link's path against the project folder when it is relative.
    static func fullPath(_ path: String, root: String?) -> String {
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        guard let root, !root.isEmpty else { return path }
        return ((root as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    /// The full path, then kind and size, then the modification date once known.
    static func text(path: String, root: String?, state: State?, dateFormatter: DateFormatter? = nil) -> String {
        let full = fullPath(path, root: root)
        switch state {
        case .none, .loading?: return full + "\nLoading…"
        case .failed(let message)?: return full + "\n" + message
        case .loaded(nil)?: return full + "\nNot found"
        case .loaded(let metadata?)?:
            var lines = [full]
            lines.append(metadata.isDirectory ? "Directory" : "File · " + size(metadata.byteLength))
            if let modified = metadata.modified { lines.append("Modified " + (dateFormatter ?? Self.dateFormatter).string(from: modified)) }
            return lines.joined(separator: "\n")
        }
    }

    static func size(_ bytes: UInt64) -> String {
        sizeFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    /// Mutes and strikes through links to paths already known not to exist.
    static func markMissing(_ text: NSMutableAttributedString, color: NSColor, isMissing: (String) -> Bool) {
        for link in AgentFileLinkHover.fileLinks(in: text) where isMissing(link.path) {
            text.addAttributes(missingAttributes(color), range: link.range)
        }
    }

    static func missingAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.foregroundColor: color, .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: color]
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Hover tooltips over the file links of one text view. Each laid-out link rect gets a
/// tracking area, which requests the path's metadata once the pointer enters it, and a
/// tooltip rect whose text AppKit asks for after its standard delay. Rects are rebuilt
/// only when the text or its layout width changed, never while scrolling.
@MainActor
final class AgentFileLinkHover: NSResponder, NSViewToolTipOwner {
    struct Link: Equatable {
        var path: String
        var range: NSRange
        var rects: [NSRect] = []
    }

    weak var services: AgentConversationLinkServices?
    var missingColor: NSColor = .secondaryLabelColor
    private weak var text: NSTextView?
    private(set) var links: [Link] = []
    private(set) var trackingAreas: [NSTrackingArea] = []
    private var toolTipTags: [NSView.ToolTipTag] = []
    private var observations: [String: AgentLazyRequestObservation] = [:]

    init(text: NSTextView) {
        self.text = text
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The file links of `text`, by path and character range, without geometry.
    static func fileLinks(in text: NSAttributedString) -> [Link] {
        var result: [Link] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let url = value as? URL, url.scheme == "tab-agent-file",
                  case .file(let path, _)? = AgentResponseLink.parse(url.absoluteString) else { return }
            if let last = result.last, last.path == path, NSMaxRange(last.range) == range.location {
                result[result.count - 1].range.length += range.length
            } else { result.append(Link(path: path, range: range)) }
        }
        return result
    }

    /// Recomputes link rects from the current layout and replaces the tracking and tooltip rects when they moved.
    func rebuild() {
        guard let text, let storage = text.textStorage, let manager = text.layoutManager, let container = text.textContainer else { return }
        var next = Self.fileLinks(in: storage)
        if !next.isEmpty {
            manager.ensureLayout(for: container)
            let origin = text.textContainerOrigin
            for index in next.indices {
                let glyphs = manager.glyphRange(forCharacterRange: next[index].range, actualCharacterRange: nil)
                manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                    next[index].rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
                }
            }
        }
        guard next != links else { return }
        uninstall()
        links = next
        for (index, link) in links.enumerated() {
            for rect in link.rects where rect.width > 0 && rect.height > 0 {
                let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: ["link": index])
                text.addTrackingArea(area)
                trackingAreas.append(area)
                toolTipTags.append(text.addToolTip(rect, owner: self, userData: nil))
            }
        }
    }

    /// Removes this helper's tracking and tooltip rects.
    func uninstall() {
        if let text {
            for area in trackingAreas { text.removeTrackingArea(area) }
            for tag in toolTipTags { text.removeToolTip(tag) }
        }
        trackingAreas.removeAll()
        toolTipTags.removeAll()
        links.removeAll()
    }

    /// Cancels pending metadata requests; resolved results stay in the conversation cache.
    func cancelRequests() {
        for observation in observations.values { observation.cancel() }
        observations.removeAll()
    }

    func link(at point: NSPoint) -> Link? {
        links.first { $0.rects.contains { $0.contains(point) } }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let index = event.trackingArea?.userInfo?["link"] as? Int, links.indices.contains(index) else { return }
        request(links[index].path)
    }

    override func mouseExited(with event: NSEvent) {}

    /// Starts the metadata request for `path` unless this view already observes it.
    func request(_ path: String) {
        guard observations[path] == nil, let services else { return }
        observations[path] = services.fileMetadata.observe(path) { [weak self] state in
            guard case .loaded(nil) = state else { return }
            self?.markMissing(path)
        }
    }

    private func markMissing(_ path: String) {
        guard let storage = text?.textStorage else { return }
        let attributes = AgentFileLinkTooltip.missingAttributes(missingColor)
        for link in Self.fileLinks(in: storage) where link.path == path {
            storage.addAttributes(attributes, range: link.range)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let link = link(at: point) else { return "" }
        request(link.path)
        return AgentFileLinkTooltip.text(path: link.path, root: services?.workspaceRoot, state: services?.fileMetadata.state(for: link.path))
    }
}
