import AppKit
import TabProtocol

/// Native counterpart to T3's WorkLog disclosures: stable, independently expandable tool rows.
@MainActor
final class AgentToolDetailView: ThemedView {
    var onOpenFile: ((String, Int?) -> Void)?
    var onDisclosure: (() -> Void)?
    var expandedIDs: Set<String> {
        get { expanded }
        set {
            guard expanded != newValue else { return }
            let wasUpdating = updating
            updating = true
            defer { updating = wasUpdating }
            let changed = expanded.symmetricDifference(newValue)
            let anchor = captureAnchor()
            expanded = newValue
            for id in changed { heights.removeValue(forKey: id); dirty.insert(id) }
            rebuildOffsets()
            restoreAnchor(anchor)
            needsLayout = true
        }
    }
    var scrollOffset: NSPoint {
        get { requestedScrollOffset ?? scroll.contentView.bounds.origin }
        set { requestedScrollOffset = newValue; needsLayout = true }
    }
    var mountedRowCount: Int { mounted.count }
    var retainedRowCount: Int { mounted.count + detached.count }
    private(set) var measurementCount = 0

    private let scroll = NSScrollView(frame: .zero)
    private let document = AgentToolLogDocument(frame: .zero)
    private var items: [AgentChatItem] = []
    private var indexByID: [String: Int] = [:]
    private var expanded: Set<String> = []
    private var mounted: [String: AgentToolDisclosure] = [:]
    private var detached: [String: AgentToolDisclosure] = [:]
    private var detachedOrder: [String] = []
    private var innerOffsets: [String: NSPoint] = [:]
    private var heights: [String: CGFloat] = [:]
    private var dirty: Set<String> = []
    private var offsets: [CGFloat] = [0]
    private var measuredWidth: CGFloat = 0
    private var contentWidth: CGFloat = 0
    private var updating = false
    private var notificationPending = false
    private var boundsObserver: NSObjectProtocol?
    private var requestedScrollOffset: NSPoint?

    convenience init(items: [AgentChatItem], theme: AppTheme) {
        self.init(frame: .zero)
        update(items: items, theme: theme)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mountVisibleRows() }
            }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }

    func update(items: [AgentChatItem], theme: AppTheme) {
        updating = true
        defer { updating = false }
        let themeChanged = self.theme !== theme
        let anchor = captureAnchor()
        let old = Dictionary(self.items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        if themeChanged { self.theme = theme }
        let ids = Set(items.map(\.id))
        for (id, row) in mounted where !ids.contains(id) { row.removeFromSuperview(); mounted.removeValue(forKey: id) }
        detached = detached.filter { ids.contains($0.key) }
        detachedOrder.removeAll { !ids.contains($0) }
        heights = heights.filter { ids.contains($0.key) }
        innerOffsets = innerOffsets.filter { ids.contains($0.key) }
        expanded.formIntersection(ids)
        self.items = items
        indexByID = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, last in last })
        for item in items where old[item.id] != item || themeChanged { dirty.insert(item.id) }
        dirty.formIntersection(ids)
        if themeChanged {
            detached.removeAll(); detachedOrder.removeAll()
            for row in mounted.values { row.refresh(theme: theme) }
        }
        rebuildOffsets()
        restoreAnchor(anchor)
        needsLayout = true
    }

    func height(for width: CGFloat) -> CGFloat {
        prepareWidth(width)
        return min(360, offsets.last ?? 0)
    }

    override func layout() {
        super.layout()
        updating = true
        prepareWidth(bounds.width)
        scroll.frame = bounds
        if let position = requestedScrollOffset, bounds.width > 0, bounds.height > 0, !items.isEmpty {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(position.y, (offsets.last ?? 0) - scroll.contentSize.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
            requestedScrollOffset = nil
        }
        updating = false
        mountVisibleRows()
    }

    override func themeDidChange() {
        dirty.formUnion(items.map(\.id))
        detached.removeAll(); detachedOrder.removeAll()
        for row in mounted.values { row.refresh(theme: theme) }
        needsLayout = true
    }

    private func prepareWidth(_ width: CGFloat) {
        let width = max(1, width)
        guard measuredWidth != width else { return }
        measuredWidth = width
        dirty.formUnion(items.map(\.id))
    }

    private func rebuildOffsets() {
        offsets = [0]
        offsets.reserveCapacity(items.count + 1)
        for item in items {
            let height = expanded.contains(item.id) ? heights[item.id] ?? 180 : 28
            offsets.append((offsets.last ?? 0) + height + 4)
        }
        document.frame.size = NSSize(width: max(1, scroll.contentSize.width), height: offsets.last ?? 0)
    }

    private func index(at y: CGFloat) -> Int {
        var low = 0
        var high = items.count
        while low < high {
            let middle = (low + high) / 2
            if offsets[middle + 1] <= y { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func captureAnchor() -> (String, CGFloat)? {
        let y = scroll.contentView.bounds.minY
        let index = index(at: y)
        guard items.indices.contains(index) else { return nil }
        return (items[index].id, y - offsets[index])
    }

    private func restoreAnchor(_ anchor: (String, CGFloat)?) {
        guard let anchor, let index = indexByID[anchor.0] else { return }
        let withinRow = min(anchor.1, max(0, offsets[index + 1] - offsets[index] - 1))
        let y = max(0, min(offsets[index] + withinRow, (offsets.last ?? 0) - scroll.contentSize.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func mountVisibleRows() {
        guard !updating, bounds.width > 0, bounds.height > 0 else { return }
        updating = true
        defer { updating = false }
        if contentWidth != scroll.contentSize.width {
            contentWidth = scroll.contentSize.width
            dirty.formUnion(items.map(\.id))
        }
        // Refine estimates only around the viewport; shrinking rows can reveal more rows.
        // Four bounded passes cover even the shortest expanded tools without a blank viewport.
        for _ in 0..<4 {
            if !reconcileVisibleRows() { break }
        }
    }

    private func reconcileVisibleRows() -> Bool {
        let previousHeight = min(360, offsets.last ?? 0)
        let anchor = captureAnchor()
        let viewport = scroll.contentView.bounds
        let first = index(at: max(0, viewport.minY - 96))
        let end = min(items.count, index(at: viewport.maxY + 96) + 1)
        var indices = first < end ? Array(first..<end) : []
        if let responder = window?.firstResponder as? NSView,
           let focused = mounted.first(where: { responder === $0.value || responder.isDescendant(of: $0.value) }),
           let focusedIndex = indexByID[focused.key], !indices.contains(focusedIndex) {
            indices.append(focusedIndex)
        }
        let visibleIDs = Set(indices.map { items[$0].id })
        for (id, row) in mounted where !visibleIDs.contains(id) {
            innerOffsets[id] = row.outputScrollPosition
            row.removeFromSuperview()
            mounted.removeValue(forKey: id)
            detached[id] = row
            detachedOrder.removeAll { $0 == id }
            detachedOrder.append(id)
        }
        while detachedOrder.count > 24 {
            detached.removeValue(forKey: detachedOrder.removeFirst())
        }
        var refined = false
        for index in indices {
            let item = items[index]
            let row: AgentToolDisclosure
            if let existing = mounted[item.id] { row = existing }
            else {
                row = detached.removeValue(forKey: item.id) ?? AgentToolDisclosure(frame: .zero)
                detachedOrder.removeAll { $0 == item.id }
                mounted[item.id] = row
                document.addSubview(row)
                row.restoreOutputScrollPosition(innerOffsets[item.id])
                row.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
                let id = item.id
                row.onDisclosure = { [weak self] in
                    guard let self else { return }
                    var ids = self.expandedIDs
                    if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
                    self.expandedIDs = ids
                    self.notifyDisclosure()
                }
            }
            row.update(item, expanded: expanded.contains(item.id), theme: theme)
            if dirty.contains(item.id) || heights[item.id] == nil {
                if expanded.contains(item.id) {
                    let previous = heights[item.id] ?? 180
                    let height = row.height(for: max(1, scroll.contentSize.width))
                    measurementCount += 1
                    heights[item.id] = height
                    if previous != height { refined = true }
                } else { heights[item.id] = 28 }
                dirty.remove(item.id)
            }
        }
        if refined { rebuildOffsets(); restoreAnchor(anchor) }
        document.frame.size.width = max(1, scroll.contentSize.width)
        for index in indices {
            let item = items[index]
            mounted[item.id]?.frame = NSRect(x: 0, y: offsets[index], width: document.bounds.width,
                                           height: offsets[index + 1] - offsets[index] - 4)
        }
        if previousHeight != min(360, offsets.last ?? 0) { notifyDisclosure() }
        return refined
    }

    private func notifyDisclosure() {
        guard !notificationPending else { return }
        notificationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notificationPending = false
            self.onDisclosure?()
        }
    }
}

@MainActor
private final class AgentToolLogDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class AgentToolDisclosure: NSView, NSTextViewDelegate {
    override var isFlipped: Bool { true }
    var onOpenFile: ((String, Int?) -> Void)?
    var onDisclosure: (() -> Void)?
    private let header = PillButton("", style: .plain)
    private let body = AgentRichTextView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private var item: AgentChatItem?
    private var expanded = false
    private var theme = AppTheme.shared
    private var restoredScrollPosition: NSPoint?
    private var bodyHeights: [CGFloat: CGFloat] = [:]

    var outputScrollPosition: NSPoint { restoredScrollPosition ?? scroll.contentView.bounds.origin }
    func restoreOutputScrollPosition(_ position: NSPoint?) { restoredScrollPosition = position }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        header.translatesAutoresizingMaskIntoConstraints = true
        header.alignment = .left
        header.font = AppFont.small
        header.lineBreakMode = .byTruncatingTail
        header.imagePosition = .imageLeading
        header.imageScaling = .scaleProportionallyDown
        header.onPress = { [weak self] in
            guard let self else { return }
            self.onDisclosure?()
        }
        body.delegate = self
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = body
        addSubview(header)
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ item: AgentChatItem, expanded: Bool, theme: AppTheme) {
        guard self.item != item || self.theme !== theme || self.expanded != expanded else { return }
        self.item = item
        self.expanded = expanded
        refresh(theme: theme)
    }

    func refresh(theme: AppTheme) {
        self.theme = theme
        guard let item else { return }
        bodyHeights.removeAll(keepingCapacity: true)
        let activity = item.tool
        let status = activity?.status ?? (item.isComplete ? .completed : .running)
        let symbol: String
        switch status {
        case .running: symbol = "◌"
        case .completed: symbol = "✓"
        case .failed: symbol = "!"
        case .denied: symbol = "⊘"
        case .interrupted: symbol = "■"
        }
        let name = activity?.name ?? item.text
        let summary = activity?.summary ?? String(item.text.prefix(240))
        let title = name == summary ? name : name + " · " + summary
        let statusText = status.rawValue.capitalized
        let icon: String
        switch activity?.category {
        case .command: icon = "terminal"
        case .read: icon = "doc.text"
        case .search: icon = "magnifyingglass"
        case .edit: icon = "pencil"
        case .web: icon = "globe"
        case .subagent: icon = "person.2"
        default: icon = "wrench.and.screwdriver"
        }
        header.image = NSImage(systemSymbolName: icon, accessibilityDescription: activity?.category?.rawValue)
        header.title = "\(expanded ? "⌄" : "›")  \(symbol)  \(title) · \(statusText)"
        header.setTitleColor(status == .failed || status == .denied ? .systemRed : theme.fgDim)
        header.toolTip = title + " · " + statusText
        header.setAccessibilityLabel((expanded ? "Collapse " : "Expand ") + title + ", " + statusText)
        scroll.isHidden = !expanded
        if expanded { body.setContent(AgentToolText.content(item, theme: theme)) }
        body.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        needsLayout = true
    }

    func height(for width: CGFloat) -> CGFloat {
        expanded ? 38 + min(320, bodyHeight(for: max(1, width - 46))) : 28
    }

    private func bodyHeight(for width: CGFloat) -> CGFloat {
        if let height = bodyHeights[width] { return height }
        let height = body.height(for: width)
        if bodyHeights.count >= 4 { bodyHeights.removeAll(keepingCapacity: true) }
        bodyHeights[width] = height
        return height
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 26)
        if expanded {
            let follow = scroll.contentView.bounds.maxY >= body.bounds.height - 8
            scroll.frame = NSRect(x: 26, y: 32, width: max(1, bounds.width - 32), height: max(1, bounds.height - 38))
            let width = max(1, scroll.contentSize.width)
            body.frame = NSRect(x: 0, y: 0, width: width, height: bodyHeight(for: width))
            if let position = restoredScrollPosition {
                body.scroll(NSPoint(x: 0, y: min(position.y, max(0, body.bounds.height - scroll.contentSize.height))))
                restoredScrollPosition = nil
            } else if follow, item?.tool?.category == .command {
                body.scroll(NSPoint(x: 0, y: max(0, body.bounds.height - scroll.contentSize.height)))
            }
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return true }
        if url.scheme == "agent-file", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
            let line = components.queryItems?.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
            onOpenFile?(path, line)
        } else if url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
        }
        return true
    }
}

/// Kept separate from views so output, diff colors and safe link targets are directly testable.
@MainActor
enum AgentToolText {
    static func content(_ item: AgentChatItem, theme: AppTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let activity = item.tool
        func heading(_ text: String) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(NSAttributedString(string: text + "\n", attributes: [.font: AppFont.system(11, weight: .semibold), .foregroundColor: theme.fgDim]))
        }
        if let input = activity?.input, !input.isEmpty {
            heading(activity?.category == .command ? "Command" : "Input")
            result.append(AgentMarkdown.plain(readableInput(input), theme: theme, monospaced: true))
        }
        for change in activity?.fileChanges ?? [] {
            heading(change.path)
            if let diff = change.diff {
                let displayed = change.kind == "add" && !diff.hasPrefix("+")
                    ? diff.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n") : diff
                result.append(diffText(displayed, theme: theme))
            }
        }
        if let output = activity?.output ?? (activity == nil ? item.detail : nil), !output.isEmpty {
            heading("Output")
            result.append(terminalText(output, theme: theme, terminal: activity?.category == .command))
        }
        if let code = activity?.exitCode {
            heading("Exit code: \(code)")
        }
        for path in activity?.filePaths ?? [] where !(activity?.fileChanges?.contains(where: { $0.path == path }) ?? false) {
            heading(path)
        }
        for url in activity?.urls ?? [] { heading(url) }
        if result.length == 0 { result.append(AgentMarkdown.plain(item.detail ?? "No output", theme: theme, muted: true, monospaced: true)) }
        addLinks(to: result, paths: activity?.filePaths ?? [], theme: theme)
        return result
    }

    static func readableInput(_ input: String) -> String {
        guard let data = input.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return bounded(input) }
        if let files = object as? [[String: Any]] {
            return bounded(files.map { file in
                let path = file["path"] as? String ?? "File"
                let kind = (file["kind"] as? [String: Any])?["type"] as? String
                return path + (kind.map { " · " + $0 } ?? "")
            }.joined(separator: "\n"))
        }
        guard let fields = object as? [String: Any] else { return bounded(input) }
        return bounded(fields.keys.sorted().map { key in
            let value = fields[key]
            let text = value as? String ?? value.map { String(describing: $0) } ?? ""
            return key.replacingOccurrences(of: "_", with: " ").capitalized + ": " + text
        }.joined(separator: "\n"))
    }

    static func diffText(_ diff: String, theme: AppTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for line in bounded(diff).components(separatedBy: "\n") {
            let color: NSColor = line.hasPrefix("+") && !line.hasPrefix("+++") ? .systemGreen
                : line.hasPrefix("-") && !line.hasPrefix("---") ? .systemRed : theme.fgMuted
            result.append(NSAttributedString(string: line + "\n", attributes: [.font: AppFont.mono(12), .foregroundColor: color]))
        }
        return result
    }

    static func terminalText(_ source: String, theme: AppTheme, terminal: Bool) -> NSAttributedString {
        // A carriage return overwrites the current progress line, as in T3's command fixture.
        let source = bounded(source).components(separatedBy: "\n").map {
            $0.components(separatedBy: "\r").last ?? ""
        }.joined(separator: "\n")
        let result = NSMutableAttributedString(string: "")
        let expression = try? NSRegularExpression(pattern: "\u{1b}\\[[0-9;]*[A-Za-z]")
        let ns = source as NSString
        var offset = 0
        var color = theme.fg
        let palette: [Int: NSColor] = [30: .black, 31: .systemRed, 32: .systemGreen, 33: .systemYellow,
                                      34: .systemBlue, 35: .systemPurple, 36: .systemTeal, 37: .white]
        func append(_ range: NSRange) {
            guard range.length > 0 else { return }
            var attributes: [NSAttributedString.Key: Any] = [.font: AppFont.mono(12), .foregroundColor: color]
            if terminal { attributes[.backgroundColor] = theme.fg.withAlphaComponent(0.045) }
            result.append(NSAttributedString(string: ns.substring(with: range), attributes: attributes))
        }
        for match in expression?.matches(in: source, range: NSRange(location: 0, length: ns.length)) ?? [] {
            append(NSRange(location: offset, length: match.range.location - offset))
            let escape = ns.substring(with: match.range)
            if escape.hasSuffix("m") {
                for code in escape.dropFirst(2).dropLast().split(separator: ";").compactMap({ Int($0) }) {
                    if code == 0 || code == 39 { color = theme.fg }
                    else if let next = palette[code] ?? palette[code - 60] { color = next }
                }
            }
            offset = NSMaxRange(match.range)
        }
        append(NSRange(location: offset, length: ns.length - offset))
        return result
    }

    private static func bounded(_ text: String) -> String {
        text.count > 32_000 ? "[Earlier output omitted from preview]\n" + String(text.suffix(32_000)) : text
    }

    private static func addLinks(to text: NSMutableAttributedString, paths: [String], theme: AppTheme) {
        let ns = text.string as NSString
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector?.matches(in: text.string, range: NSRange(location: 0, length: text.length)) ?? [] {
            guard let url = match.url, ["http", "https"].contains(url.scheme ?? "") else { continue }
            text.addAttributes([.link: url, .foregroundColor: theme.accent], range: match.range)
        }
        for path in Set(paths) where !path.isEmpty {
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let range = ns.range(of: path, range: search)
                guard range.location != NSNotFound else { break }
                var components = URLComponents()
                components.scheme = "agent-file"
                components.queryItems = [URLQueryItem(name: "path", value: path)]
                let suffix = ns.substring(from: NSMaxRange(range))
                if suffix.hasPrefix(":"), let line = Int(suffix.dropFirst().prefix(while: \.isNumber)), line > 0 {
                    components.queryItems?.append(URLQueryItem(name: "line", value: String(line)))
                }
                if let url = components.url { text.addAttributes([.link: url, .foregroundColor: theme.accent], range: range) }
                search = NSRange(location: NSMaxRange(range), length: ns.length - NSMaxRange(range))
            }
        }
    }
}
