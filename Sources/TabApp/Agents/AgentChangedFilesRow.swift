import AppKit
import TabProtocol

@MainActor
final class AgentChangedFilesRow: AgentTimelineRow {
    var checkpoint: AgentTurnCheckpoint? { didSet { rebuild() } }
    private let heading = makeLabel("", font: AppFont.small)
    private let totals = makeLabel("", font: AppFont.small)
    private let openDiff = PillButton("Open diff", style: .plain)
    /// Puts every file of the turn back as it was before; shown when the pane can revert.
    private let revert = PillButton("Revert", style: .plain)
    private let toggleAll = PillButton("", style: .plain)
    private var nodes: [AgentChangedFilesTree.Node] = []
    private var expandedDirectories: Set<String> = []
    /// The user opened or closed folders, so a small card no longer opens them all.
    private var foldersChosen = false
    private var rows: [(AgentChangedFilesTree.Node, Int, PillButton, NSTextField)] = []
    private let more = PillButton("", style: .plain)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        for view in [heading, totals, openDiff, revert, toggleAll, more] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        openDiff.font = AppFont.small
        openDiff.image = AppIcon.diff.image(size: 12, theme: theme)
        openDiff.imagePosition = .imageLeading
        openDiff.onPress = { [weak self] in self?.open(nil) }
        revert.font = AppFont.small
        revert.isHidden = true
        revert.toolTip = "Put this turn's files back as they were before it"
        revert.setAccessibilityLabel("Revert this turn's changes")
        revert.onPress = { [weak self] in
            guard let self, let checkpoint = self.checkpoint else { return }
            self.onRevert?(checkpoint, nil)
        }
        toggleAll.onPress = { [weak self] in
            guard let self else { return }
            let paths = self.directoryPaths(self.nodes)
            self.foldersChosen = true
            self.expandedDirectories = paths.isSubset(of: self.expandedDirectories) ? [] : paths
            self.rebuildRows()
            self.onDisclosure?()
        }
        more.font = AppFont.small
        more.onPress = { [weak self] in self?.open(nil) }
        themeDidChange()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func revertHandlerDidChange() { rebuildRows() }

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
        // A dozen files or fewer show at once, not as folder names.
        if !foldersChosen, checkpoint.totalFiles <= 12 { expandedDirectories = directoryPaths(nodes) }
        heading.stringValue = "\(checkpoint.totalFiles) changed file\(checkpoint.totalFiles == 1 ? "" : "s")"
        totals.attributedStringValue = Self.stat(checkpoint.additions, checkpoint.deletions, font: AppFont.small, theme: theme)
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
                button.image = FileIcon.image(for: node.path, isDirectory: node.isDirectory, isExpanded: expandedDirectories.contains(node.path), theme: theme)
                button.imagePosition = .imageLeading
                button.setTitleColor(theme.fgMuted)
                if node.isDirectory {
                    let chevron: AppIcon = expandedDirectories.contains(node.path) ? .chevronDown : .chevronRight
                    let attachment = NSTextAttachment()
                    attachment.image = chevron.image(size: 12, color: theme.fgDim)
                    attachment.bounds = NSRect(x: 0, y: -2, width: 12, height: 12)
                    let title = NSMutableAttributedString(attachment: attachment)
                    title.append(NSAttributedString(string: "  " + node.name, attributes: [.font: AppFont.mono(12), .foregroundColor: theme.fgMuted]))
                    button.attributedTitle = title
                }
                button.contentTintColor = node.isDirectory ? theme.fgDim : nil
                button.toolTip = node.path
                button.setAccessibilityLabel(node.name + (node.isDirectory ? ", folder" : ", open diff"))
                button.onPress = { [weak self] in
                    guard let self else { return }
                    if node.isDirectory {
                        self.foldersChosen = true
                        if self.expandedDirectories.contains(node.path) { self.expandedDirectories.remove(node.path) }
                        else { self.expandedDirectories.insert(node.path) }
                        self.rebuildRows()
                        self.onDisclosure?()
                    } else { self.open(node.path) }
                }
                if !node.isDirectory {
                    let menu = NSMenu()
                    var actions = [("Open diff", 0), ("Open file", 1), ("Copy path", 2)]
                    if onRevert != nil { actions.append(("Revert File…", 3)) }
                    for (title, tag) in actions {
                        let item = NSMenuItem(title: title, action: #selector(fileAction(_:)), keyEquivalent: "")
                        item.target = self; item.tag = tag; item.representedObject = node.path
                        menu.addItem(item)
                    }
                    button.menu = menu
                }
                let stat = makeLabel("", font: AppFont.mono(11))
                stat.translatesAutoresizingMaskIntoConstraints = true
                stat.alignment = .right
                stat.attributedStringValue = Self.stat(node.additions, node.deletions, font: AppFont.mono(11), theme: theme)
                addSubview(button); addSubview(stat)
                rows.append((node, depth, button, stat))
                if node.isDirectory && expandedDirectories.contains(node.path) { append(node.children, depth: depth + 1) }
            }
        }
        append(nodes, depth: 0)
        let paths = directoryPaths(nodes)
        toggleAll.isHidden = paths.isEmpty
        let all = !paths.isEmpty && paths.isSubset(of: expandedDirectories)
        toggleAll.image = (all ? AppIcon.chevronsIn : .chevronsUpDown).image(size: 12, color: theme.fgDim)
        toggleAll.setAccessibilityLabel(all ? "Collapse all folders" : "Expand all folders")
        toggleAll.toolTip = all ? "Collapse all folders" : "Expand all folders"
        needsLayout = true
    }
    @objc private func fileAction(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }
        switch item.tag {
        case 1: onOpenFile?(path, nil)
        case 2: NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string)
        case 3: if let checkpoint { onRevert?(checkpoint, [path]) }
        default: open(path)
        }
    }
    static func stat(_ additions: UInt64?, _ deletions: UInt64?, font: NSFont, theme: AppTheme) -> NSAttributedString {
        let value = NSMutableAttributedString(string: "")
        if let additions, additions > 0 {
            value.append(NSAttributedString(string: "+\(additions)", attributes: [.font: font, .foregroundColor: theme.diffAdd]))
        }
        if let deletions, deletions > 0 {
            value.append(NSAttributedString(string: (value.length > 0 ? "  " : "") + "−\(deletions)", attributes: [.font: font, .foregroundColor: theme.diffRemove]))
        }
        return value
    }
    override func preferredHeight(for width: CGFloat) -> CGFloat { 44 + CGFloat(rows.count) * 28 + (more.isHidden ? 8 : 32) }
    override func layoutRow(width: CGFloat) {
        let narrow = width < 384
        openDiff.title = narrow ? "" : "Open diff"
        openDiff.setTitleColor(theme.fgDim)
        openDiff.contentTintColor = theme.fgDim
        openDiff.image = AppIcon.diff.image(size: 12, theme: theme)
        toggleAll.contentTintColor = theme.fgDim
        openDiff.frame = NSRect(x: width - (narrow ? 40 : 104), y: 6, width: narrow ? 28 : 92, height: 28)
        revert.isHidden = onRevert == nil
        revert.setTitleColor(theme.fgDim)
        let revertWidth: CGFloat = revert.isHidden ? 0 : ceil(revert.fittingSize.width)
        revert.frame = NSRect(x: openDiff.frame.minX - 4 - revertWidth, y: 6, width: revertWidth, height: 28)
        toggleAll.frame = NSRect(x: (revert.isHidden ? openDiff.frame.minX : revert.frame.minX) - 30, y: 6, width: 28, height: 28)
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
    override func restoreState(_ state: AgentTimelineRowState) {
        expandedDirectories = state.expandedDirectories
        foldersChosen = true
        rebuildRows()
    }
}
