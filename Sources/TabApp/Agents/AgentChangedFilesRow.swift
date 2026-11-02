import AppKit
import TabProtocol

@MainActor
final class AgentChangedFilesRow: AgentTimelineRow {
    var checkpoint: AgentTurnCheckpoint? { didSet { rebuild() } }
    private let heading = makeLabel("", font: AppFont.small)
    private let totals = makeLabel("", font: AppFont.small)
    private let openDiff = PillButton("Open diff", style: .plain)
    private let toggleAll = PillButton("", style: .plain)
    private var nodes: [AgentChangedFilesTree.Node] = []
    private var expandedDirectories: Set<String> = []
    private var rows: [(AgentChangedFilesTree.Node, Int, PillButton, NSTextField)] = []
    private let more = PillButton("", style: .plain)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        for view in [heading, totals, openDiff, toggleAll, more] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        openDiff.font = AppFont.small
        openDiff.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        openDiff.imagePosition = .imageLeading
        openDiff.onPress = { [weak self] in self?.open(nil) }
        toggleAll.onPress = { [weak self] in
            guard let self else { return }
            let paths = self.directoryPaths(self.nodes)
            self.expandedDirectories = paths.isSubset(of: self.expandedDirectories) ? [] : paths
            self.rebuildRows()
            self.onDisclosure?()
        }
        more.font = AppFont.small
        more.onPress = { [weak self] in self?.open(nil) }
        themeDidChange()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func symbol(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        image.isTemplate = true
        return image.tinted(theme.fgDim)
    }
    private func directoryPaths(_ nodes: [AgentChangedFilesTree.Node]) -> Set<String> {
        Set(nodes.filter(\.isDirectory).map(\.path)).union(nodes.reduce(into: Set<String>()) { $0.formUnion(directoryPaths($1.children)) })
    }
    private func open(_ path: String?) {
        guard let checkpoint else { return }
        onOpenCheckpoint?(checkpoint.id, path)
    }
    private func rebuild() {
        guard let checkpoint else { return }
        nodes = AgentChangedFilesTree.build(checkpoint.files)
        heading.stringValue = "\(checkpoint.totalFiles) changed file\(checkpoint.totalFiles == 1 ? "" : "s")"
        totals.attributedStringValue = Self.stat(checkpoint.additions, checkpoint.deletions, font: AppFont.small)
        more.title = "\(checkpoint.totalFiles - checkpoint.files.count) more files in the full diff"
        more.isHidden = checkpoint.totalFiles <= checkpoint.files.count
        rebuildRows()
    }
    private func rebuildRows() {
        for row in rows { row.2.removeFromSuperview(); row.3.removeFromSuperview() }
        rows = []
        func append(_ nodes: [AgentChangedFilesTree.Node], depth: Int) {
            for node in nodes {
                let button = PillButton(node.name, style: .plain)
                button.translatesAutoresizingMaskIntoConstraints = true
                button.font = AppFont.mono(12)
                button.alignment = .left
                button.lineBreakMode = .byTruncatingMiddle
                button.image = FileIcon.image(for: node.path, isDirectory: node.isDirectory, theme: theme)
                button.imagePosition = .imageLeading
                button.title = node.isDirectory ? (expandedDirectories.contains(node.path) ? "⌄  " : "›  ") + node.name : node.name
                button.setTitleColor(theme.fgMuted)
                button.contentTintColor = node.isDirectory ? theme.fgDim : nil
                button.toolTip = node.path
                button.setAccessibilityLabel(node.name + (node.isDirectory ? ", folder" : ", open diff"))
                button.onPress = { [weak self] in
                    guard let self else { return }
                    if node.isDirectory {
                        if self.expandedDirectories.contains(node.path) { self.expandedDirectories.remove(node.path) }
                        else { self.expandedDirectories.insert(node.path) }
                        self.rebuildRows()
                        self.onDisclosure?()
                    } else { self.open(node.path) }
                }
                if !node.isDirectory {
                    let menu = NSMenu()
                    for (title, tag) in [("Open diff", 0), ("Open file", 1), ("Copy path", 2)] {
                        let item = NSMenuItem(title: title, action: #selector(fileAction(_:)), keyEquivalent: "")
                        item.target = self; item.tag = tag; item.representedObject = node.path
                        menu.addItem(item)
                    }
                    button.menu = menu
                }
                let stat = makeLabel("", font: AppFont.mono(11))
                stat.translatesAutoresizingMaskIntoConstraints = true
                stat.alignment = .right
                stat.attributedStringValue = Self.stat(node.additions, node.deletions, font: AppFont.mono(11))
                addSubview(button); addSubview(stat)
                rows.append((node, depth, button, stat))
                if node.isDirectory && expandedDirectories.contains(node.path) { append(node.children, depth: depth + 1) }
            }
        }
        append(nodes, depth: 0)
        let paths = directoryPaths(nodes)
        toggleAll.isHidden = paths.isEmpty
        let all = !paths.isEmpty && paths.isSubset(of: expandedDirectories)
        toggleAll.image = symbol(all ? "chevron.up.chevron.down" : "arrow.up.and.down")
        toggleAll.setAccessibilityLabel(all ? "Collapse all folders" : "Expand all folders")
        toggleAll.toolTip = all ? "Collapse all folders" : "Expand all folders"
        needsLayout = true
    }
    @objc private func fileAction(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }
        switch item.tag {
        case 1: onOpenFile?(path, nil)
        case 2: NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string)
        default: open(path)
        }
    }
    static func stat(_ additions: UInt64?, _ deletions: UInt64?, font: NSFont) -> NSAttributedString {
        let value = NSMutableAttributedString(string: "")
        if let additions, additions > 0 {
            value.append(NSAttributedString(string: "+\(additions)", attributes: [.font: font, .foregroundColor: NSColor.systemGreen]))
        }
        if let deletions, deletions > 0 {
            value.append(NSAttributedString(string: (value.length > 0 ? "  " : "") + "−\(deletions)", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
        }
        return value
    }
    override func preferredHeight(for width: CGFloat) -> CGFloat { 44 + CGFloat(rows.count) * 28 + (more.isHidden ? 8 : 32) }
    override func layoutRow(width: CGFloat) {
        let narrow = width < 384
        openDiff.title = narrow ? "" : "Open diff"
        openDiff.setTitleColor(theme.fgDim)
        openDiff.contentTintColor = theme.fgDim
        openDiff.image = symbol("doc.badge.plus")
        toggleAll.contentTintColor = theme.fgDim
        openDiff.frame = NSRect(x: width - (narrow ? 40 : 104), y: 6, width: narrow ? 28 : 92, height: 28)
        toggleAll.frame = NSRect(x: openDiff.frame.minX - 30, y: 6, width: 28, height: 28)
        let headingWidth = ceil(heading.intrinsicContentSize.width) + 4
        heading.frame = NSRect(x: 12, y: 12, width: min(headingWidth, max(0, toggleAll.frame.minX - 20)), height: 18)
        totals.frame = NSRect(x: heading.frame.maxX + 12, y: 12, width: max(0, toggleAll.frame.minX - heading.frame.maxX - 16), height: 18)
        for (index, row) in rows.enumerated() {
            let x = 12 + CGFloat(row.1) * 16
            row.2.frame = NSRect(x: x, y: 44 + CGFloat(index) * 28, width: max(0, width - x - 100), height: 26)
            row.3.frame = NSRect(x: max(0, width - 92), y: 49 + CGFloat(index) * 28, width: 80, height: 18)
        }
        more.frame = NSRect(x: 8, y: 44 + CGFloat(rows.count) * 28, width: max(0, width - 16), height: 28)
    }
    override func layout() { super.layout(); layoutRow(width: bounds.width) }
    override func themeDidChange() {
        layer?.backgroundColor = theme.fg.withAlphaComponent(0.035).cgColor
        heading.textColor = theme.fg
        openDiff.setTitleColor(theme.fgDim); more.setTitleColor(theme.fgDim)
        rebuildRows()
    }
    override func captureState() -> AgentTimelineRowState { AgentTimelineRowState(expandedDirectories: expandedDirectories) }
    override func restoreState(_ state: AgentTimelineRowState) { expandedDirectories = state.expandedDirectories; rebuildRows() }
}
