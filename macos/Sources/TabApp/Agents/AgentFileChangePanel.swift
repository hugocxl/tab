import AppKit
import TabProtocol

/// The typed file-change inspector keeps successful patches behind the diff action.
@MainActor
final class AgentFileChangePanel: NSView, @preconcurrency NSLayoutManagerDelegate {
    override var isFlipped: Bool { true }
    var onOpenDiff: (() -> Void)?
    private let path = AgentRichTextView(frame: .zero)
    private let fileIcon = NSImageView()
    private var operationIcons: [NSImageView] = []
    private let counts = AgentRichTextView(frame: .zero)
    private let button = AgentDiffButton(frame: .zero)
    private let error = AgentRichTextView(frame: .zero)
    private let errorScroll = NSScrollView(frame: .zero)
    /// The edit's own diff, in place, so reviewing edits needs no window per tool.
    private let preview = AgentRichTextView(frame: .zero)
    private let previewScroll = AgentPassThroughScrollView(frame: .zero)
    static let previewHeight: CGFloat = 320
    private var operations: [AgentRichTextView] = []
    var compactControls = true
    var outputScrollPosition: NSPoint { restoredScrollPosition ?? errorScroll.contentView.bounds.origin }
    private var restoredScrollPosition: NSPoint?
    func restoreOutputScrollPosition(_ position: NSPoint?) { restoredScrollPosition = position }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        path.layoutManager?.delegate = self
        for view in [path, fileIcon, counts, button, errorScroll] { addSubview(view) }
        errorScroll.drawsBackground = false
        errorScroll.borderType = .noBorder
        errorScroll.hasVerticalScroller = true
        errorScroll.autohidesScrollers = true
        errorScroll.documentView = error
        previewScroll.drawsBackground = false
        previewScroll.borderType = .noBorder
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.documentView = preview
        previewScroll.isHidden = true
        preview.setAccessibilityLabel("Diff")
        addSubview(previewScroll)
        button.onPress = { [weak self] in self?.onOpenDiff?() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func displayPath(_ path: String, root: String?) -> String {
        let source = path as NSString
        if let expression = try? NSRegularExpression(pattern: ":([0-9]+)(?::([0-9]+))?$"),
           let match = expression.firstMatch(in: path, range: NSRange(location: 0, length: source.length)) {
            let base = displayBarePath(source.substring(to: match.range.location), root: root)
            guard let line = UInt64(source.substring(with: match.range(at: 1))), line > 0 else { return base }
            let columnRange = match.range(at: 2)
            let column = columnRange.location == NSNotFound ? nil : UInt64(source.substring(with: columnRange))
            return base + ":" + String(line) + (column.flatMap { $0 > 0 ? ":" + String($0) : nil } ?? "")
        }
        return displayBarePath(path, root: root)
    }

    private static func displayBarePath(_ path: String, root: String?) -> String {
        func normalize(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "/")
                .replacingOccurrences(of: "^/([A-Za-z]:/)", with: "$1", options: .regularExpression)
        }
        let path = normalize(path)
        guard let workspace = root, !workspace.isEmpty else { return path }
        let root = normalize(workspace).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let label = root.split(separator: "/").last.map(String.init) ?? ""
        let insensitive = root.range(of: "^[A-Za-z]:/", options: .regularExpression) != nil
        let compared = insensitive ? path.lowercased() : path
        let base = insensitive ? root.lowercased() : root
        if compared == base { return label }
        if compared.hasPrefix(base + "/") { return label + "/" + path.dropFirst(root.count + 1) }
        if !path.hasPrefix("/") {
            if compared.hasPrefix((insensitive ? label.lowercased() : label) + "/") { return path }
            return label + "/" + path.replacingOccurrences(of: "^\\./+|^/+", with: "", options: .regularExpression)
        }
        return path
    }

    func update(_ activity: AgentToolActivity, root: String?, theme: AppTheme) {
        let details = activity.fileChangeDetails ?? .init(fileName: activity.filePaths?.first ?? activity.fileChanges?.first?.path ?? "")
        func text(_ value: String, color: NSColor) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 16; paragraph.maximumLineHeight = 16
            return NSAttributedString(string: value, attributes: [.font: AppFont.mono(12), .foregroundColor: color, .paragraphStyle: paragraph])
        }
        fileIcon.image = FileIcon.image(for: details.fileName, theme: theme)
        fileIcon.setAccessibilityElement(false)
        path.setContent(text(Self.displayPath(details.fileName, root: root), color: theme.fgMuted))
        counts.isHidden = details.additions == nil && details.deletions == nil
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        func count(_ value: UInt64) -> String { formatter.string(from: NSNumber(value: value)) ?? String(value) }
        let summary = NSMutableAttributedString(string: "")
        if let additions = details.additions {
            summary.append(text("+" + count(additions), color: theme.diffAdd))
        }
        if let deletions = details.deletions {
            if summary.length > 0 { summary.append(text(" ", color: theme.fg)) }
            summary.append(text("-" + count(deletions), color: theme.diffRemove))
        }
        // Count typography inherits the inspector's sans-serif face.
        summary.addAttribute(.font, value: AppFont.system(12), range: NSRange(location: 0, length: summary.length))
        counts.setContent(summary)
        button.theme = theme
        let failed = activity.status == .failed && details.diff?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        errorScroll.isHidden = !failed
        error.setContent(AgentCommandPresentation.text(failed ? details.diff ?? "" : "", color: theme.fgMuted))
        let diffs = failed ? [] : Self.diffs(activity)
        previewScroll.isHidden = diffs.isEmpty
        preview.setContent(diffs.isEmpty ? NSAttributedString() : AgentToolText.diffText(diffs.joined(separator: "\n"), theme: theme))
        let changes = details.operations ?? []
        while operations.count > changes.count {
            operations.removeLast().removeFromSuperview()
            operationIcons.removeLast().removeFromSuperview()
        }
        while operations.count < changes.count {
            let view = AgentRichTextView(frame: .zero)
            view.layoutManager?.delegate = self
            operations.append(view); addSubview(view)
            let icon = NSImageView(); icon.setAccessibilityElement(false)
            operationIcons.append(icon); addSubview(icon)
        }
        for (index, operation) in changes.enumerated() {
            let view = operations[index]
            operationIcons[index].image = FileIcon.image(for: operation.path, mimeType: operation.mimeType, theme: theme)
            let types = [operation.fileType, operation.mimeType].compactMap { $0 }.filter { !$0.isEmpty }
            let value = operation.operation + " " + (operation.oldPath.map { $0 + " → " } ?? "") + Self.displayPath(operation.path, root: root)
                + (types.isEmpty ? "" : " (" + types.joined(separator: ", ") + ")")
            view.setContent(text(value, color: theme.fgMuted))
        }
        for view in [path, counts, error] + operations { view.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)] }
        needsLayout = true
    }

    /// The diffs an edit carries: its details' patch, else each change's.
    static func diffs(_ activity: AgentToolActivity) -> [String] {
        if let diff = activity.fileChangeDetails?.diff, !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [diff] }
        return (activity.fileChanges ?? []).compactMap { change in
            guard let diff = change.diff, !diff.isEmpty else { return nil }
            return (activity.fileChanges?.count ?? 0) > 1 ? change.path + "\n" + diff : diff
        }
    }

    var showsDiff: Bool { !previewScroll.isHidden }

    @discardableResult
    func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let width = max(1, width)
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        var frames: [(NSView, NSRect)] = []
        func finishLine() {
            if apply { for (view, rect) in frames { var rect = rect; rect.origin.y += (lineHeight - rect.height) / 2; view.frame = rect } }
            frames.removeAll(keepingCapacity: true)
        }
        button.compact = compactControls
        for view: NSView in [path, counts, button] where !view.isHidden {
            let size: NSSize
            if let text = view as? AgentRichTextView {
                let natural = text.attributedString().size().width
                let w = min(max(1, width - (view === path ? 20 : 0)), ceil(natural))
                _ = text.height(for: max(1, w))
                let h = text.textContainer.flatMap { text.layoutManager?.usedRect(for: $0).maxY } ?? 16
                size = NSSize(width: w + (view === path ? 20 : 0), height: h)
            } else { size = button.intrinsicContentSize }
            if x > 0 && x + size.width > width { finishLine(); y += lineHeight + 8; x = 0; lineHeight = 0 }
            if view === path {
                frames.append((fileIcon, NSRect(x: x, y: y, width: 14, height: 14)))
                frames.append((view, NSRect(x: x + 20, y: y, width: size.width - 20, height: size.height)))
            } else { frames.append((view, NSRect(origin: NSPoint(x: x, y: y), size: size))) }
            lineHeight = max(lineHeight, size.height); x += size.width + 8
        }
        finishLine(); y += lineHeight
        if !previewScroll.isHidden {
            y += 8
            let height = preview.height(for: width)
            if apply {
                previewScroll.frame = NSRect(x: 0, y: y, width: width, height: min(Self.previewHeight, height))
                preview.frame = NSRect(x: 0, y: 0, width: width, height: height)
            }
            y += min(Self.previewHeight, height)
        }
        if !errorScroll.isHidden {
            y += 8
            let height = error.height(for: width)
            if apply { errorScroll.frame = NSRect(x: 0, y: y, width: width, height: min(320, height)); error.frame = NSRect(x: 0, y: 0, width: width, height: height)
                if let position = restoredScrollPosition {
                    error.scroll(NSPoint(x: 0, y: min(max(0, position.y), max(0, height - errorScroll.contentSize.height))))
                    restoredScrollPosition = nil
                }
            }
            y += min(320, height)
        }
        for (index, view) in operations.enumerated() {
            y += index == 0 ? 8 : 4
            _ = view.height(for: max(1, width - 20))
            let height = view.textContainer.flatMap { view.layoutManager?.usedRect(for: $0).maxY } ?? 16
            if apply {
                operationIcons[index].frame = NSRect(x: 0, y: y + 1, width: 14, height: 14)
                view.frame = NSRect(x: 20, y: y, width: max(1, width - 20), height: height)
            }
            y += height
        }
        return y
    }
    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        guard let text = layoutManager.textStorage?.string as NSString?, charIndex > 0, charIndex <= text.length else { return true }
        let previous = text.character(at: charIndex - 1)
        // CSS normal white-space does not add soft wrapping opportunities at path separators.
        return previous != 47 && previous != 92
    }
    override func layout() { super.layout(); arrange(width: bounds.width, apply: true) }
}

@MainActor
private final class AgentDiffButton: NSButton {
    var onPress: (() -> Void)?
    var theme = AppTheme.shared { didSet { needsDisplay = true } }
    var compact = true
    private var hovered = false
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "Open diff"; isBordered = false; focusRingType = .none
        setButtonType(.momentaryPushIn); target = self; action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: AppFont.system(compact ? 12 : 14, weight: .medium)]).width) + 16, height: compact ? 24 : 28)
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = isHighlighted ? bounds.insetBy(dx: bounds.width * 0.015, dy: bounds.height * 0.015) : bounds
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        (hovered ? theme.hover : theme.bg).setFill(); shape.fill()
        theme.border.setStroke(); shape.lineWidth = 1; shape.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: AppFont.system(compact ? 12 : 14, weight: .medium), .foregroundColor: theme.fg]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if window?.firstResponder === self {
            theme.accent.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2; ring.stroke()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); needsDisplay = true; return accepted }
    override func resignFirstResponder() -> Bool { let accepted = super.resignFirstResponder(); needsDisplay = true; return accepted }
    override func keyDown(with event: NSEvent) { if event.keyCode == 36 || event.keyCode == 49 { pressed() } else { super.keyDown(with: event) } }
    @objc private func pressed() { if isEnabled { onPress?() } }
}
