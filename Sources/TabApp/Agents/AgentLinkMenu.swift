import AppKit

extension AgentConversationFileTarget {
    /// The file target of a rendered `tab-agent-file` link, with its line and column.
    init?(linkURL url: URL) {
        guard url.scheme == "tab-agent-file", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = parts.queryItems?.first(where: { $0.name == "path" })?.value, !path.isEmpty else { return nil }
        func positive(_ name: String) -> Int? {
            parts.queryItems?.first(where: { $0.name == name })?.value.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        }
        let line = positive("line")
        self.init(path: path, line: line, column: line == nil ? nil : positive("column"))
    }

    /// `path:line:column`, the form `openEditor` accepts.
    var editorTarget: String {
        guard let line else { return path }
        return path + ":" + String(line) + (column.map { ":" + String($0) } ?? "")
    }

    var isHTML: Bool { ["html", "htm"].contains((path as NSString).pathExtension.lowercased()) }
}

/// The right-click actions of links in assistant Markdown: project files get editor,
/// preview, Finder and copy actions; web pages can open in Tab's browser.
@MainActor
enum AgentLinkMenu {
    enum Target: Equatable {
        case file(AgentConversationFileTarget)
        case web(URL)

        /// The menu target of a rendered link attribute, or nil for links without one.
        init?(link: Any?) {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return nil }
            if let file = AgentConversationFileTarget(linkURL: url) { self = .file(file); return }
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            self = .web(url)
        }
    }

    enum Item: Equatable {
        case openInEditor
        case openAtPosition(line: Int, column: Int?)
        case preview
        case revealInFinder
        case copyPath
        case copyRelativePath
        case openInBrowser
        case copyLink

        var title: String {
            switch self {
            case .openInEditor: return "Open in Editor"
            case .openAtPosition(let line, let column): return "Open at Line \(line)" + (column.map { ", Column \($0)" } ?? "")
            case .preview: return "Preview"
            case .revealInFinder: return "Reveal in Finder"
            case .copyPath: return "Copy Path"
            case .copyRelativePath: return "Copy Relative Path"
            case .openInBrowser: return "Open in Browser"
            case .copyLink: return "Copy Link"
            }
        }
    }

    /// What `perform` calls; the conversation binds these to its typed actions.
    struct Actions {
        /// Opens `path:line:column` in the Tab editor, or reveals it in Finder.
        var openEditor: (_ target: String, _ reveal: Bool) throws -> Void
        var previewFile: (_ path: String) async throws -> Void
        /// Opens an HTML file of a local project in the default browser.
        var openFileInBrowser: (_ path: String) throws -> Void
        /// Opens a web page in a Tab browser pane.
        var openPreview: (_ url: URL) throws -> Void
        var copy: (_ text: String) throws -> Void
    }

    /// The items for `target`, in menu order; Finder and file browsing need a local project.
    static func items(for target: Target, isLocal: Bool) -> [Item] {
        switch target {
        case .web: return [.openInBrowser, .copyLink]
        case .file(let file):
            var items: [Item] = [.openInEditor]
            if let line = file.line { items.append(.openAtPosition(line: line, column: file.column)) }
            items.append(.preview)
            if isLocal { items.append(.revealInFinder) }
            items += [.copyPath, .copyRelativePath]
            if isLocal && file.isHTML { items.append(.openInBrowser) }
            return items
        }
    }

    /// The path a file link names, against the project folder when relative.
    static func fullPath(_ path: String, root: String?) -> String { AgentFileLinkTooltip.fullPath(path, root: root) }

    /// The path relative to the project folder; paths outside it stay as they are.
    static func relativePath(_ path: String, root: String?) -> String {
        guard let root, !root.isEmpty else { return path.hasPrefix("./") ? String(path.dropFirst(2)) : path }
        let full = fullPath(path, root: root)
        let base = (root as NSString).standardizingPath
        if full == base { return "." }
        let prefix = base == "/" ? "/" : base + "/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
    }

    static func perform(_ item: Item, target: Target, root: String?, actions: Actions) async throws {
        switch (item, target) {
        case (.openInEditor, .file(let file)): try actions.openEditor(file.path, false)
        case (.openAtPosition, .file(let file)): try actions.openEditor(file.editorTarget, false)
        case (.preview, .file(let file)): try await actions.previewFile(file.path)
        case (.revealInFinder, .file(let file)): try actions.openEditor(file.path, true)
        case (.copyPath, .file(let file)): try actions.copy(fullPath(file.path, root: root))
        case (.copyRelativePath, .file(let file)): try actions.copy(relativePath(file.path, root: root))
        case (.openInBrowser, .file(let file)): try actions.openFileInBrowser(file.path)
        case (.openInBrowser, .web(let url)): try actions.openPreview(url)
        case (.copyLink, .web(let url)): try actions.copy(url.absoluteString)
        default: throw ModelError("This action does not apply to this link.")
        }
    }

    /// Menu items that run `perform` through `services`, which reports failures itself.
    static func menuItems(for target: Target, services: AgentConversationLinkServices) -> [NSMenuItem] {
        guard let run = services.performLinkAction else { return [] }
        return items(for: target, isLocal: services.isLocalProject()).map { item in
            ClosureMenuItem(item.title) { run(item, target) }
        }
    }

    /// The link attribute under `point` (in `view` coordinates), only when a glyph is hit.
    static func link(at point: NSPoint, in view: NSTextView) -> Any? {
        guard let manager = view.layoutManager, let container = view.textContainer,
              let storage = view.textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(.link, at: index, effectiveRange: nil)
    }
}
