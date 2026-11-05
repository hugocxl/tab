import Foundation

// Tabs, panes and their contents are protocol types: each server keeps its
// tabs. These are the app's additions.

extension PaneContent {
    /// A project-relative path with `/` separators, refusing paths that
    /// leave the project.
    static func relativePath(_ path: String) throws -> String {
        var path = Substring(path)
        while path.hasPrefix("./") { path = path.dropFirst(2) }
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.isEmpty || path.hasPrefix("/") || path.split(separator: "/").contains("..") {
            throw AppError.invalidState("pane path must be relative to the project")
        }
        return String(path)
    }
}

extension Pane {
    static func terminal(title: String = "Terminal", launch: TerminalLaunch? = nil) -> Pane {
        Pane(title: title, content: .terminal(session: nil), launch: launch)
    }
}

extension Tab {
    /// Keeps titles to what a title bar can show.
    mutating func sanitizeTitles() {
        for index in panes.indices {
            if case .agent = panes[index].content { panes[index].title = "Agent" }
        }
        var terminal = false
        for index in panes.indices where panes[index].content.isTerminal {
            panes[index].title = TerminalTitle.sanitizeOrDefault(panes[index].title)
            terminal = true
        }
        customTitle = customTitle.map {
            terminal ? TerminalTitle.sanitize($0) : $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A tab as `state.json` kept it before servers kept tabs, with this app's
/// titles and zoom. Panes of the retired management type are dropped, and a
/// tab holding only those is `nil`.
struct SavedTab: Decodable {
    let tab: Tab?

    private enum Keys: String, CodingKey {
        case id, customTitle, color, pinned, panes, layout, zoomed, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let saved = try container.decode([SavedPane].self, forKey: .panes)
        if !saved.isEmpty && saved.allSatisfy({ $0.pane == nil }) {
            tab = nil
            return
        }
        var layout = try container.decode(Layout<PaneId>.self, forKey: .layout)
        var zoomed = try container.decodeIfPresent(PaneId.self, forKey: .zoomed)
        for retired in saved where retired.pane == nil {
            layout.remove(retired.id)
            if zoomed == retired.id { zoomed = nil }
        }
        var tab = Tab(id: try container.decode(TabId.self, forKey: .id),
                      panes: saved.compactMap(\.pane), layout: layout)
        tab.customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        tab.color = try container.decodeIfPresent(TabColor.self, forKey: .color)
        tab.pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        tab.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        tab.zoomed = zoomed
        tab.sanitizeTitles()
        do {
            try tab.validate()
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(error)"))
        }
        self.tab = tab
    }
}

/// A saved pane with its title; `pane` is `nil` for the retired management pane.
private struct SavedPane: Decodable {
    let id: PaneId
    let pane: Pane?

    private enum Keys: String, CodingKey { case id, title, content }
    private enum ContentKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(PaneId.self, forKey: .id)
        let content = try container.nestedContainer(keyedBy: ContentKeys.self, forKey: .content)
        guard try content.decode(String.self, forKey: .type) != "servers" else {
            pane = nil
            return
        }
        var pane = try Pane(from: decoder)
        if let title = try container.decodeIfPresent(String.self, forKey: .title) { pane.title = title }
        self.pane = pane
    }
}
