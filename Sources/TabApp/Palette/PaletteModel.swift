import AppKit
import TabCore

/// The palette's geometry from `docs/codesh/style.md`, in points. Every
/// height comes from row counts; the panel never measures itself.
public enum PaletteLayout {
    public static let width: CGFloat = 740
    public static let maxHeight: CGFloat = 480
    public static let top: CGFloat = 72
    public static let radius: CGFloat = 20
    public static let header: CGFloat = 56
    public static let section: CGFloat = 28
    public static let row: CGFloat = 40
    public static let rowInset: CGFloat = 8
    public static let rowRadius: CGFloat = 10
    public static let tile: CGFloat = 24
    public static let tileRadius: CGFloat = 6
    /// The strip the floating footer capsule sits in; rows scroll under it.
    public static let footer: CGFloat = 52
    public static let capsule: CGFloat = 36
    public static let status: CGFloat = 96
    public static let listInset: CGFloat = 6
    public static let searchFont: CGFloat = 18
    public static let actionsWidth: CGFloat = 300
    public static let actionsRow: CGFloat = 32
    public static let actionsMax: CGFloat = 320
    /// The outer border, top and bottom.
    static let border: CGFloat = 2

    /// The panel's height for a page of `sections` headers and `items` rows,
    /// or of a status message when `list` is false.
    public static func height(sections: Int, items: Int, list: Bool, maxHeight: CGFloat = maxHeight) -> CGFloat {
        let body = list ? CGFloat(sections) * section + CGFloat(items) * row + listInset * 2 : status
        return min(header + body + footer, maxHeight) + border
    }

    /// The panel's distance from the top of a window `height` tall: 20% of
    /// the window lower than `top`, as long as a full-height panel still fits.
    /// It doesn't depend on the page, so the panel stays put while typing.
    public static func offset(windowHeight height: CGFloat) -> CGFloat {
        max(top, min(top + height * 0.2, height - maxHeight - border - 8)).rounded()
    }

    /// The ⌘K panel's height for `rows` actions.
    public static func actionsHeight(rows: Int) -> CGFloat {
        let list = CGFloat(max(rows, 1)) * actionsRow + listInset * 2
        return min(list + listInset, actionsMax) + border
    }
}

/// A tile's background, a hue gradient with a white glyph.
public enum TileHue: Equatable, Sendable {
    case red, orange, amber, green, teal, blue, indigo, purple, pink, gray, accent
    /// No background: the glyph draws muted.
    case none

    /// Hue, saturation and lightness of the tile's color.
    var hsl: (Double, Double, Double)? {
        switch self {
        case .red: return (4, 0.72, 0.52)
        case .orange: return (24, 0.85, 0.52)
        case .amber: return (38, 0.90, 0.46)
        case .green: return (142, 0.52, 0.42)
        case .teal: return (176, 0.58, 0.40)
        case .blue: return (214, 0.78, 0.54)
        case .indigo: return (242, 0.58, 0.58)
        case .purple: return (276, 0.58, 0.56)
        case .pink: return (332, 0.68, 0.56)
        case .gray: return (220, 0.08, 0.50)
        case .accent, .none: return nil
        }
    }
}

/// What a row's tile draws.
public enum TileGlyph: Equatable {
    case icon(AppIcon)
    case monogram(String)
    /// Up to four colors in a 2×2 grid, such as a theme preview.
    case swatches([NSColor])
    case image(NSImage)
    case none
}

public struct PaletteTile: Equatable {
    public var glyph: TileGlyph
    public var hue: TileHue

    public init(_ glyph: TileGlyph, _ hue: TileHue) {
        self.glyph = glyph
        self.hue = hue
    }

    public static let none = PaletteTile(.none, .none)
    public static func icon(_ icon: AppIcon, _ hue: TileHue) -> PaletteTile { PaletteTile(.icon(icon), hue) }
}

/// What Return does on a row.
public enum PaletteTarget {
    /// Closes the palette, then runs.
    case run(@MainActor () -> Void)
    /// Runs and keeps the palette open.
    case apply(@MainActor () -> Void)
    /// Opens another page.
    case page(PalettePage)

    var kindKey: String {
        switch self {
        case .run: return "run"
        case .apply: return "apply"
        case .page(let page): return "page:\(page)"
        }
    }
}

/// An entry of a row's ⌘K panel. The first describes Return; the second
/// Command-Return.
public struct PaletteItemAction: Equatable {
    public var id: String
    public var title: String
    /// Shown beside the action; it binds no key.
    public var shortcut: KeyChord?
    /// Drawn in red, and asks for a second Return.
    public var destructive: Bool
    public var keepOpen: Bool

    public init(_ id: String, _ title: String, shortcut: KeyChord? = nil, destructive: Bool = false, keepOpen: Bool = false) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.destructive = destructive
        self.keepOpen = keepOpen
    }
}

/// One palette row.
public struct PaletteItem {
    public var id: String
    public var title: String
    /// UTF-16 ranges of `title` drawn in the accent color.
    public var highlights: [Range<Int>] = []
    public var subtitle: String?
    /// The muted label at the right edge, such as "Command" or "File".
    public var kind: String?
    public var badge: String?
    public var tile: PaletteTile = .none
    public var shortcut: KeyChord?
    public var actions: [PaletteItemAction] = []
    public var disabled = false
    public var current = false
    public var target: PaletteTarget

    public init(id: String, title: String, target: PaletteTarget) {
        self.id = id
        self.title = title
        self.target = target
    }

    /// What Return does, as the footer names it.
    public var primaryTitle: String {
        if let action = actions.first { return action.title }
        switch target {
        case .run: return "Run"
        case .apply: return "Apply"
        case .page: return "Open"
        }
    }

    func sameAppearance(_ other: PaletteItem) -> Bool {
        id == other.id && title == other.title && highlights == other.highlights && subtitle == other.subtitle
            && kind == other.kind && badge == other.badge && tile == other.tile && shortcut == other.shortcut
            && actions == other.actions && disabled == other.disabled && current == other.current
            && target.kindKey == other.target.kindKey
    }
}

public struct PaletteSection {
    public var title: String?
    public var items: [PaletteItem]

    public init(_ title: String?, _ items: [PaletteItem]) {
        self.title = title
        self.items = items
    }
}

public enum PaletteStatus: Equatable {
    case ready
    case loading(String)
    case empty(String)
    case error(String)
}

/// Everything a page shows.
public struct PageContent {
    public var sections: [PaletteSection]
    public var status: PaletteStatus

    public init(sections: [PaletteSection] = [], status: PaletteStatus = .ready) {
        self.sections = sections
        self.status = status
    }

    public static func items(_ items: [PaletteItem]) -> PageContent { PageContent(sections: [PaletteSection(nil, items)]) }
    public static func loading(_ message: String) -> PageContent { PageContent(status: .loading(message)) }
    public static func empty(_ message: String) -> PageContent { PageContent(status: .empty(message)) }
    public static func error(_ message: String) -> PageContent { PageContent(status: .error(message)) }

    func sameAppearance(_ other: PageContent) -> Bool {
        status == other.status && sections.count == other.sections.count
            && zip(sections, other.sections).allSatisfy { left, right in
                left.title == right.title && left.items.count == right.items.count
                    && zip(left.items, right.items).allSatisfy { $0.sameAppearance($1) }
            }
    }
}

/// A control at the right of the search field.
public enum PaletteAccessory: Equatable {
    /// A pill the user toggles, such as case sensitivity.
    case toggle(id: String, label: String, active: Bool)
    /// A muted hint with an optional keycap.
    case hint(label: String, key: KeyChord?)
}

/// How a page presents itself.
public struct PageSpec: Equatable {
    public var page: PalettePage
    public var placeholder: String
    /// The back chip on pushed pages.
    public var breadcrumb: String?
    public var accessories: [PaletteAccessory] = []
    /// Tab completes the query instead of moving the selection.
    public var completesOnTab = false
    /// Shown when the page is ready but has no rows.
    public var emptyMessage = "No results"

    public init(_ page: PalettePage, placeholder: String, breadcrumb: String? = nil) {
        self.page = page
        self.placeholder = placeholder
        self.breadcrumb = breadcrumb
    }
}

/// A flattened list row.
public enum PaletteRow: Equatable {
    case section(Int)
    case item(section: Int, item: Int)
}

/// One page of the stack: its spec, content, query and selection.
public struct PageState {
    public var spec: PageSpec
    public private(set) var content: PageContent
    public private(set) var rows: [PaletteRow] = []
    public var query = ""
    private var selectedId: String?
    /// Whether the user picked the selection since the query last changed;
    /// until then it follows the first row as results arrive.
    private var picked = false
    public private(set) var counts = (sections: 0, items: 0)

    public init(spec: PageSpec, content: PageContent = PageContent()) {
        self.spec = spec
        self.content = content
        rebuildRows()
        selectedId = firstSelectable()
    }

    /// Whether the content's rows show, rather than a status message.
    public var showsRows: Bool { content.status == .ready && !rows.isEmpty }

    /// The message shown instead of rows, if any.
    public var message: (String, isError: Bool)? {
        switch content.status {
        case .ready: return rows.isEmpty ? (spec.emptyMessage, false) : nil
        case .loading(let text), .empty(let text): return (text, false)
        case .error(let text): return (text, true)
        }
    }

    /// The panel height for this page.
    public var height: CGFloat {
        PaletteLayout.height(sections: counts.sections, items: counts.items, list: showsRows)
    }

    /// Replaces the content, keeping a picked selection on its item when it
    /// is still there. Returns whether the rows changed.
    @discardableResult
    public mutating func setContent(_ content: PageContent) -> Bool {
        if self.content.sameAppearance(content) {
            self.content = content
            return false
        }
        self.content = content
        rebuildRows()
        if picked, let selectedId, isSelectable(selectedId) { return true }
        selectedId = firstSelectable()
        return true
    }

    /// The query changed: the selection follows the first row again.
    public mutating func queryChanged(_ query: String) {
        self.query = query
        picked = false
    }

    public var selected: String? { content.status == .ready ? selectedId : nil }

    public var selectedItem: PaletteItem? { selected.flatMap(item) }

    public var selectedRow: Int? {
        guard let selected else { return nil }
        return rows.firstIndex { rowItem($0)?.id == selected }
    }

    public func item(_ id: String) -> PaletteItem? {
        for section in content.sections {
            if let item = section.items.first(where: { $0.id == id }) { return item }
        }
        return nil
    }

    public func rowItem(_ row: PaletteRow) -> PaletteItem? {
        guard case let .item(section, item) = row, content.sections.indices.contains(section),
              content.sections[section].items.indices.contains(item) else { return nil }
        return content.sections[section].items[item]
    }

    public func sectionTitle(_ row: PaletteRow) -> String? {
        guard case .section(let index) = row, content.sections.indices.contains(index) else { return nil }
        return content.sections[index].title
    }

    @discardableResult
    public mutating func select(_ id: String) -> Bool {
        guard isSelectable(id) else { return false }
        selectedId = id
        picked = true
        return true
    }

    /// Moves by `delta` selectable items, wrapping around.
    @discardableResult
    public mutating func moveSelection(_ delta: Int) -> Bool {
        guard content.status == .ready else { return false }
        let selectable = rows.compactMap { rowItem($0) }.filter { !$0.disabled }.map(\.id)
        guard !selectable.isEmpty else { return false }
        let count = selectable.count
        let next: Int
        if let current = selectedId.flatMap({ selectable.firstIndex(of: $0) }) {
            next = ((current + delta) % count + count) % count
        } else {
            next = delta >= 0 ? 0 : count - 1
        }
        guard selectedId != selectable[next] else { return false }
        selectedId = selectable[next]
        picked = true
        return true
    }

    private func isSelectable(_ id: String) -> Bool { item(id).map { !$0.disabled } ?? false }

    private func firstSelectable() -> String? {
        rows.compactMap { rowItem($0) }.first { !$0.disabled }?.id
    }

    private mutating func rebuildRows() {
        rows = []
        counts = (0, 0)
        for (sectionIndex, section) in content.sections.enumerated() where !section.items.isEmpty {
            if section.title != nil {
                counts.sections += 1
                rows.append(.section(sectionIndex))
            }
            counts.items += section.items.count
            for index in section.items.indices { rows.append(.item(section: sectionIndex, item: index)) }
        }
    }
}

/// Text with fuzzy-matched ranges drawn in the accent color.
@MainActor
func highlighted(_ text: String, ranges: [Range<Int>], font: NSFont, color: NSColor, accent: NSColor) -> NSAttributedString {
    let string = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let length = (text as NSString).length
    for range in ranges where range.lowerBound >= 0 && range.upperBound <= length {
        string.addAttribute(.foregroundColor, value: accent, range: NSRange(location: range.lowerBound, length: range.count))
        string.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: NSRange(location: range.lowerBound, length: range.count))
    }
    return string
}
