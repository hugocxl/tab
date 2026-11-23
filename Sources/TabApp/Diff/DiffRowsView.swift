import AppKit
import TabCore
import TabProtocol

/// Draws the visible diff rows only: tinted backgrounds, dim line numbers,
/// markers and syntax-colored source text in the code font, clipped to the
/// visible columns.
@MainActor
public final class DiffRowsView: ThemedView {
    public var document: DiffDocument? { didSet { reviewSelection = nil; reviewAnchor = nil; reviewHead = nil; markReviewedRows(); needsDisplay = true } }
    /// Saved review comments, drawn on the side and lines each was made on.
    var reviewMarks: [DiffReviewMark] = [] { didSet { if oldValue != reviewMarks { markReviewedRows(); needsDisplay = true } } }
    /// Rows a comment covers on their old or new side, by index into the document's rows.
    private(set) var markedOld = IndexSet()
    private(set) var markedNew = IndexSet()
    var reviewEnabled = false
    var onReviewSelection: (() -> Void)?
    var reviewSelection: DiffReviewSelection? { didSet { needsDisplay = true; onReviewSelection?() } }
    private var reviewAnchor: Int?
    private var reviewHead: Int?
    public var split = false { didSet { needsDisplay = true } }
    public var font: NSFont = AppFont.mono(12) {
        didSet {
            cell = NativeStyle.cell(font)
            tokenAttributes = Self.tokenAttributes(theme: theme, font: font)
            needsDisplay = true
        }
    }
    public private(set) var cell = NativeStyle.cell(AppFont.mono(12))
    private var visibleWidth: CGFloat = 0
    private var tokenAttributes: [TokenKind: [NSAttributedString.Key: Any]] = [:]

    public override func themeDidChange() {
        tokenAttributes = Self.tokenAttributes(theme: theme, font: font)
        needsDisplay = true
    }

    private static func tokenAttributes(theme: AppTheme, font: NSFont) -> [TokenKind: [NSAttributedString.Key: Any]] {
        let colors = theme.syntaxColors
        var attributes: [TokenKind: [NSAttributedString.Key: Any]] = [:]
        for kind in TokenKind.allCases {
            attributes[kind] = [.font: font].merging(colors.attributes(kind, font: font)) { $1 }
        }
        return attributes
    }

    public override var acceptsFirstResponder: Bool { true }

    func reviewRow(at point: NSPoint) -> (index: Int, old: Bool)? {
        guard let document, cell.height > 0, point.y >= 0 else { return nil }
        let index = Int(point.y / cell.height)
        if split {
            guard document.split.indices.contains(index) else { return nil }
            let old = point.x < bounds.width / 2
            guard let row = old ? document.split[index].left : document.split[index].right,
                  (old ? document.rows[row].oldLineNumber : document.rows[row].newLineNumber) != nil else { return nil }
            return (row, old)
        }
        guard document.rows.indices.contains(index), document.rows[index].kind != .hunk else { return nil }
        let row = document.rows[index]
        let old = row.kind == .deletion || (row.kind == .context && point.x < Metrics.gutter + CGFloat(document.numberColumns) * cell.width)
        guard (old ? row.oldLineNumber : row.newLineNumber) != nil else { return nil }
        return (index, old)
    }

    public override func mouseDown(with event: NSEvent) {
        guard reviewEnabled, let row = reviewRow(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event); return
        }
        window?.makeFirstResponder(self)
        if !event.modifierFlags.contains(.shift) || reviewSelection?.old != row.old { reviewAnchor = row.index }
        let anchor = reviewAnchor ?? row.index
        reviewHead = row.index
        reviewSelection = .init(rows: min(anchor, row.index)...max(anchor, row.index), old: row.old)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard reviewEnabled, let anchor = reviewAnchor,
              let row = reviewRow(at: convert(event.locationInWindow, from: nil)), row.old == reviewSelection?.old else { return }
        reviewHead = row.index
        reviewSelection = .init(rows: min(anchor, row.index)...max(anchor, row.index), old: row.old)
        autoscroll(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        guard reviewEnabled else { super.keyDown(with: event); return }
        interpretKeyEvents([event])
    }
    public override func moveUp(_ sender: Any?) { moveReview(-1, extend: false) }
    public override func moveDown(_ sender: Any?) { moveReview(1, extend: false) }
    public override func moveUpAndModifySelection(_ sender: Any?) { moveReview(-1, extend: true) }
    public override func moveDownAndModifySelection(_ sender: Any?) { moveReview(1, extend: true) }
    public override func moveLeft(_ sender: Any?) { selectReviewSide(old: true) }
    public override func moveRight(_ sender: Any?) { selectReviewSide(old: false) }

    private func selectReviewSide(old: Bool) {
        guard let selection = reviewSelection, let document else { return }
        let current = reviewHead ?? selection.rows.lowerBound
        guard let pair = document.split.first(where: { $0.left == current || $0.right == current }),
              let target = old ? pair.left : pair.right,
              (old ? document.rows[target].oldLineNumber : document.rows[target].newLineNumber) != nil else { return }
        reviewAnchor = target
        reviewHead = target
        reviewSelection = .init(rows: target...target, old: old)
    }

    private func moveReview(_ delta: Int, extend: Bool) {
        guard let document else { return }
        let old = reviewSelection?.old ?? false
        let current = reviewHead ?? reviewSelection.map { delta < 0 ? $0.rows.lowerBound : $0.rows.upperBound }
        var next = current.map { $0 + delta } ?? (delta > 0 ? 0 : document.rows.count - 1)
        while document.rows.indices.contains(next) {
            if (old ? document.rows[next].oldLineNumber : document.rows[next].newLineNumber) != nil {
                let anchor = extend ? (reviewAnchor ?? next) : next
                reviewAnchor = anchor
                reviewHead = next
                reviewSelection = .init(rows: min(anchor, next)...max(anchor, next), old: old)
                let visual = split ? document.split.firstIndex(where: { (old ? $0.left : $0.right) == next }) ?? 0 : next
                scrollToVisible(NSRect(x: visibleRect.minX, y: CGFloat(visual) * cell.height, width: 1, height: cell.height))
                return
            }
            next += delta
        }
    }

    private func markReviewedRows() {
        markedOld = IndexSet(); markedNew = IndexSet()
        guard let document, !reviewMarks.isEmpty else { return }
        for (index, row) in document.rows.enumerated() where row.kind != .hunk {
            if let line = row.oldLineNumber, reviewMarks.contains(where: { $0.old && $0.lines.contains(line) }) { markedOld.insert(index) }
            if let line = row.newLineNumber, reviewMarks.contains(where: { !$0.old && $0.lines.contains(line) }) { markedNew.insert(index) }
        }
    }

    /// The rows `mark` covers, or nil when the document doesn't show all of its lines.
    func rows(for mark: DiffReviewMark) -> ClosedRange<Int>? {
        guard let document else { return nil }
        let covered = document.rows.indices.filter { index in
            let row = document.rows[index]
            guard row.kind != .hunk, let line = mark.old ? row.oldLineNumber : row.newLineNumber else { return false }
            return mark.lines.contains(line)
        }
        guard let first = covered.first, let last = covered.last,
              let start = mark.old ? document.rows[first].oldLineNumber : document.rows[first].newLineNumber,
              let end = mark.old ? document.rows[last].oldLineNumber : document.rows[last].newLineNumber,
              start == mark.lines.lowerBound, end == mark.lines.upperBound else { return nil }
        return first...last
    }

    /// Selects `rows` on one side and scrolls them into view, as a reader choosing them would.
    func reveal(_ rows: ClosedRange<Int>, old: Bool) {
        guard let document, document.rows.indices.contains(rows.upperBound) else { return }
        reviewAnchor = rows.lowerBound
        reviewHead = rows.upperBound
        reviewSelection = .init(rows: rows, old: old)
        let visual = { (row: Int) -> Int in
            self.split ? document.split.firstIndex(where: { (old ? $0.left : $0.right) == row }) ?? row : row
        }
        let top = CGFloat(visual(rows.lowerBound)) * cell.height
        let bottom = CGFloat(visual(rows.upperBound) + 1) * cell.height
        scrollToVisible(NSRect(x: visibleRect.minX, y: max(0, top - cell.height * 3), width: 1, height: bottom - top + cell.height * 6))
    }

    /// Sizes the view to its rows and widest line, at least `width` wide.
    public func fitWidth(_ width: CGFloat) {
        visibleWidth = width
        guard let document else {
            setFrameSize(NSSize(width: width, height: 0))
            return
        }
        let columns = CGFloat(document.totalColumns(split: split)) * (split ? 2 : 1)
        let contentWidth = columns * cell.width + Metrics.gutter * 2
        let height = CGFloat(document.rowCount(split: split)) * cell.height + Metrics.gutter
        setFrameSize(NSSize(width: max(contentWidth, width), height: height))
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let document, cell.height > 0 else { return }
        let count = document.rowCount(split: split)
        let first = max(Int(dirtyRect.minY / cell.height), 0)
        let last = min(Int((dirtyRect.maxY / cell.height).rounded(.up)), count)
        guard first < last else { return }
        let half = bounds.width / 2
        for index in first..<last {
            let y = CGFloat(index) * cell.height
            if split {
                let pair = document.split[index]
                drawCell(pair.left, old: true, unified: false,
                         frame: NSRect(x: 0, y: y, width: half, height: cell.height), dirty: dirtyRect, document: document)
                drawCell(pair.right, old: false, unified: false,
                         frame: NSRect(x: half, y: y, width: half, height: cell.height), dirty: dirtyRect, document: document)
            } else {
                drawCell(index, old: document.rows[index].kind == .deletion, unified: true,
                         frame: NSRect(x: 0, y: y, width: bounds.width, height: cell.height), dirty: dirtyRect, document: document)
            }
        }
    }

    private func drawCell(_ index: Int?, old: Bool, unified: Bool, frame: NSRect, dirty: NSRect, document: DiffDocument) {
        guard let index else { return }
        let row = document.rows[index]
        switch row.kind {
        case .addition:
            theme.diffAdd.withAlphaComponent(0.12).setFill()
            frame.intersection(dirty).fill()
        case .deletion:
            theme.diffRemove.withAlphaComponent(0.12).setFill()
            frame.intersection(dirty).fill()
        default:
            break
        }
        if (old ? markedOld : markedNew).contains(index) || (unified && (markedOld.contains(index) || markedNew.contains(index))) {
            theme.accent.withAlphaComponent(0.08).setFill()
            frame.intersection(dirty).fill()
            theme.accent.setFill()
            NSRect(x: frame.minX, y: frame.minY, width: 3, height: frame.height).intersection(dirty).fill()
        }
        if reviewEnabled, let selection = reviewSelection, selection.rows.contains(index),
           unified || selection.old == old {
            theme.accent.withAlphaComponent(0.18).setFill()
            frame.intersection(dirty).fill()
        }
        let origin = frame.minX + Metrics.gutter
        let firstColumn = max(Int((max(dirty.minX, frame.minX) - origin) / cell.width), 0)
        let lastColumn = Int(((min(dirty.maxX, frame.maxX) - origin) / cell.width).rounded(.up)) + 1
        guard lastColumn > firstColumn else { return }
        let color = row.kind == .hunk ? theme.diffHunk : theme.fg
        let baseline = frame.minY + (cell.height - (font.ascender - font.descender)) / 2
        let segments = DiffDocument.segments(row, old: old, unified: unified, numberColumns: document.numberColumns)
        for (position, segment) in segments.enumerated() {
            guard let (column, text) = DiffDocument.visible(segment, first: firstColumn, last: lastColumn) else { continue }
            let point = NSPoint(x: origin + CGFloat(column) * cell.width, y: baseline)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: segment.dim ? theme.fgDim : color]
            let runs = position == segments.count - 1 ? document.runs(index, old: old) : []
            guard !runs.isEmpty else {
                (text as NSString).draw(at: point, withAttributes: attributes)
                continue
            }
            let colored = NSMutableAttributedString()
            for piece in DiffDocument.colored(text, skip: column - segment.column, runs: runs) {
                colored.append(NSAttributedString(string: String(piece.text), attributes: piece.kind.flatMap { tokenAttributes[$0] } ?? attributes))
            }
            colored.draw(at: point)
        }
    }
}
