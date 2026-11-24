import AppKit
import TabCore

/// What a sidebar row stands for, so a rebuild finds the view it showed
/// before.
enum SidebarRowKey: Hashable {
    case host(ServerId)
    case project(ProjectId)
    case card(SidebarListing.Target)
    case creating(UUID)
    case divider(above: SidebarListing.Target, below: SidebarListing.Target)
}

/// One row of the sidebar's list: what it stands for, what it shows, the
/// gap above it, and how to make its view.
struct SidebarRow {
    var key: SidebarRowKey
    /// Compared with the shown row's; while equal, the row keeps its view.
    var content: any Equatable
    var spacingBefore: CGFloat
    var make: () -> NSView
    /// Applies the new content to the view showing `old`, when the view can
    /// take that change in place; returns whether it did.
    var update: ((_ old: any Equatable, _ view: NSView) -> Bool)?
}

/// The sidebar's list: rows stacked top to bottom by frame, each as tall as
/// its intrinsic height and as wide as the list. Updating it keeps the view
/// of every row whose content is unchanged, so selecting a card or one card's
/// activity changing remakes only those cards, and nothing is solved by
/// constraints.
final class SidebarListView: NSView {
    /// The views shown, in order.
    private(set) var views: [NSView] = []
    private var spacings: [CGFloat] = []
    private var shown: [Slot: (content: any Equatable, view: NSView)] = [:]
    private var contentHeight: CGFloat = 0
    var insets = NSEdgeInsets() {
        didSet { needsLayout = true }
    }

    /// A key and which occurrence of it, should two rows share a key.
    private struct Slot: Hashable {
        var key: SidebarRowKey
        var occurrence: Int
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: contentHeight) }

    /// Shows `rows`, reusing the views of rows whose content is unchanged.
    /// Returns how many views were made.
    @discardableResult
    func update(_ rows: [SidebarRow]) -> Int {
        var next: [Slot: (content: any Equatable, view: NSView)] = [:]
        var occurrences: [SidebarRowKey: Int] = [:]
        var made = 0
        views = rows.map { row in
            let occurrence = occurrences[row.key, default: 0]
            occurrences[row.key] = occurrence + 1
            let slot = Slot(key: row.key, occurrence: occurrence)
            if let old = shown[slot] {
                if Self.same(old.content, row.content) {
                    next[slot] = old
                    return old.view
                }
                if row.update?(old.content, old.view) == true {
                    next[slot] = (row.content, old.view)
                    return old.view
                }
            }
            let view = row.make()
            view.translatesAutoresizingMaskIntoConstraints = true
            next[slot] = (row.content, view)
            made += 1
            return view
        }
        spacings = rows.map(\.spacingBefore)
        let kept = Set(views.map(ObjectIdentifier.init))
        for (_, old) in shown where !kept.contains(ObjectIdentifier(old.view)) {
            old.view.removeFromSuperview()
        }
        shown = next
        for view in views where view.superview !== self { addSubview(view) }
        layoutRows()
        return made
    }

    private static func same(_ old: any Equatable, _ new: any Equatable) -> Bool {
        func matches<T: Equatable>(_ old: T) -> Bool { (new as? T) == old }
        return matches(old)
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    /// Places every row and sizes the list to them.
    private func layoutRows() {
        let width = max(bounds.width - insets.left - insets.right, 0)
        var y = insets.top
        for (index, view) in views.enumerated() {
            if index > 0 { y += spacings[index] }
            if view.frame.width != width { view.setFrameSize(NSSize(width: width, height: view.frame.height)) }
            let height = max(view.intrinsicContentSize.height, 0)
            let frame = NSRect(x: insets.left, y: y, width: width, height: height)
            if view.frame != frame { view.frame = frame }
            y += height
        }
        y += insets.bottom
        guard abs(y - contentHeight) > 0.25 else { return }
        contentHeight = y
        invalidateIntrinsicContentSize()
    }
}
