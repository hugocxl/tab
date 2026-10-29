import AppKit
import TabCore

/// The root page's sections, in display order.
enum PaletteCategory: Int, CaseIterable {
    case terminal, panes, files, git, worktrees, projects, view, window, remote, settings, custom

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .panes: return "Panes"
        case .files: return "Files"
        case .git: return "Git"
        case .worktrees: return "Worktrees"
        case .projects: return "Projects"
        case .view: return "View"
        case .window: return "Window"
        case .remote: return "Remote"
        case .settings: return "Settings"
        case .custom: return "Custom Commands"
        }
    }

    var tile: PaletteTile {
        switch self {
        case .terminal: return .icon(.terminalStack, .green)
        case .panes: return .icon(.columns, .teal)
        case .files: return .icon(.file, .blue)
        case .git: return .icon(.gitBranch, .orange)
        case .worktrees: return .icon(.gitBranch, .purple)
        case .projects: return .icon(.folder, .blue)
        case .view: return .icon(.panelLeft, .indigo)
        case .window: return .icon(.appWindow, .gray)
        case .remote: return .icon(.network, .pink)
        case .settings: return .icon(.settings, .gray)
        case .custom: return .icon(.play, .amber)
        }
    }
}

/// What a row is, as its kind label and tile show.
enum PaletteKind: String {
    case command = "Command", file = "File", branch = "Branch", change = "Change", worktree = "Worktree"
    case project = "Project", workspace = "Workspace", terminal = "Terminal", theme = "Theme", server = "Server"
    case folder = "Folder"

    var tile: PaletteTile {
        switch self {
        case .command: return .icon(.play, .gray)
        case .file: return .icon(.file, .blue)
        case .branch: return .icon(.gitBranch, .orange)
        case .change: return .icon(.pencil, .orange)
        case .worktree: return .icon(.gitBranch, .purple)
        case .project, .folder: return .icon(.folder, .blue)
        case .workspace: return .icon(.rows, .indigo)
        case .terminal: return .icon(.terminal, .green)
        case .theme: return PaletteTile(.swatches([]), .none)
        case .server: return .icon(.network, .pink)
        }
    }
}

/// One command on the root page.
struct RootCommand {
    var id: String
    var title: String
    /// Words it is also found by, without highlights.
    var keywords = ""
    var category: PaletteCategory
    var shortcut: KeyChord?
    var disabled = false
    var target: PaletteTarget

    func item(highlights: [Range<Int>] = []) -> PaletteItem {
        var item = PaletteItem(id: id, title: title, target: target)
        item.highlights = highlights
        item.kind = PaletteKind.command.rawValue
        item.tile = category.tile
        item.disabled = disabled
        item.shortcut = shortcut
        return item
    }
}

/// Ranking and sections for the root page, kept apart from the app so
/// they can be tested.
enum RootRanking {
    static let commandLimit = 20
    static let hitLimit = 5
    static let recentLimit = 8
    static let keywordPenalty = 50

    /// The empty query: recent commands, then every category.
    static func sections(_ commands: [RootCommand], recent: [String]) -> [PaletteSection] {
        let suggestions = recent.compactMap { id in commands.first { $0.id == id } }
            .filter { !$0.disabled }.prefix(recentLimit)
        let suggested = Set(suggestions.map(\.id))
        var sections: [PaletteSection] = []
        if !suggestions.isEmpty { sections.append(PaletteSection("Suggestions", suggestions.map { $0.item() })) }
        for category in PaletteCategory.allCases {
            let items = commands.filter { $0.category == category && !suggested.contains($0.id) }.map { $0.item() }
            if !items.isEmpty { sections.append(PaletteSection(category.title, items)) }
        }
        return sections
    }

    /// Commands whose title matches best, then those only their keywords
    /// match. Ties go to the earlier category, then the shorter title.
    static func ranked(_ commands: [RootCommand], query: String) -> [PaletteItem] {
        let normalized = Fuzzy.normalize(query)
        var ranked: [(Int, RootCommand, [Range<Int>])] = []
        for command in commands {
            if let match = Fuzzy.match(command.title, normalized) {
                ranked.append((match.score, command, match.ranges))
            } else if !command.keywords.isEmpty, let match = Fuzzy.match(command.keywords, normalized) {
                ranked.append((match.score - keywordPenalty, command, []))
            }
        }
        ranked.sort { left, right in
            if left.0 != right.0 { return left.0 > right.0 }
            if left.1.category != right.1.category { return left.1.category.rawValue < right.1.category.rawValue }
            return left.1.title.count < right.1.title.count
        }
        return ranked.prefix(commandLimit).map { $0.1.item(highlights: $0.2) }
    }
}
