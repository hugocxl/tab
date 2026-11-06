import TabMobileKit
import TabProtocol
import TabShared
import UIKit

/// Shows a terminal session and types into it.
///
/// Rows are separate layers that redraw only when their content changes, the
/// cursor is a layer of its own that blinks on the render server, and frames
/// are acknowledged in the layout pass that draws them, so the server never
/// sends faster than this view shows.
final class TerminalView: UIView, UIKeyInput, TerminalDisplay {
    let controller: TerminalController
    private(set) var font: TerminalFont
    private(set) var palette: TerminalPalette
    private var rowLayers: [TerminalRowLayer] = []
    private let cursorLayer = TerminalCursorLayer()
    private let padding = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
    private var gridSize = Size(cols: 0, rows: 0)
    private var dirty = GridChanges()
    private var frameWaiting = false
    private lazy var accessoryBar = TerminalAccessoryBar(terminal: self)
    private var editMenu: UIEditMenuInteraction?

    /// Modifiers latched on the accessory bar for the next key.
    var stickyModifiers: KeyModifiers = [] {
        didSet { accessoryBar.showModifiers(stickyModifiers) }
    }

    // Scrolling and selection.
    private var scrollRemainder: CGFloat = 0
    private var momentum: CADisplayLink?
    private var momentumVelocity: CGFloat = 0
    private var selection: (anchor: TerminalPoint, head: TerminalPoint)?
    private var pinchStart: CGFloat = 0

    /// Called when the grid's font size changes by pinching.
    var onFontSizeChange: ((CGFloat) -> Void)?

    init(controller: TerminalController, fontSize: CGFloat, scheme: ColorScheme, dark: Bool) {
        self.controller = controller
        let scale = UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 3
        font = TerminalFont(size: fontSize, scale: scale)
        palette = TerminalPalette(scheme: scheme, dark: dark)
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = palette.uiColor(palette.background)
        layer.addSublayer(cursorLayer)
        cursorLayer.zPosition = 1
        installGestures()
        controller.display = self
        controller.onClipboardWrite = { text in UIPasteboard.general.string = text }
        accessibilityLabel = "Terminal"
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Appearance

    func apply(fontSize: CGFloat, scheme: ColorScheme, dark: Bool) {
        let scale = traitCollection.displayScale
        if fontSize != font.size || scale != font.scale { font = TerminalFont(size: fontSize, scale: scale) }
        palette = TerminalPalette(scheme: scheme, dark: dark)
        backgroundColor = palette.uiColor(palette.background)
        for row in rowLayers {
            row.runs = []
            row.setNeedsDisplay()
        }
        setNeedsLayout()
    }

    var terminalColors: TerminalColors { palette.terminalColors }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let usable = bounds.inset(by: padding)
        let size = Size(cols: UInt16(clamping: max(2, Int(usable.width / font.cellWidth))),
                        rows: UInt16(clamping: max(2, Int(usable.height / font.cellHeight))))
        if size != gridSize || rowLayers.first?.bounds.width != usable.width {
            gridSize = size
            layoutRows(width: usable.width)
            let cell = CellSize(width: UInt16(font.cellWidth * font.scale), height: UInt16(font.cellHeight * font.scale))
            if window != nil { controller.attach(size: size, cell: cell) }
            dirty = GridChanges(full: true, cursor: true)
        }
        flushChanges()
        if frameWaiting {
            frameWaiting = false
            controller.frameDrawn()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            controller.detach()
            stopMomentum()
        } else {
            gridSize = Size(cols: 0, rows: 0)
            setNeedsLayout()
        }
    }

    private func layoutRows(width: CGFloat) {
        let count = Int(gridSize.rows)
        while rowLayers.count < count {
            let row = TerminalRowLayer()
            layer.insertSublayer(row, below: cursorLayer)
            rowLayers.append(row)
        }
        while rowLayers.count > count { rowLayers.removeLast().removeFromSuperlayer() }
        let painter = TerminalRowPainter(font: font, palette: palette)
        for (index, row) in rowLayers.enumerated() {
            row.contentsScale = font.scale
            row.painter = painter
            row.frame = CGRect(x: padding.left, y: padding.top + CGFloat(index) * font.cellHeight,
                               width: width, height: font.cellHeight)
            row.runs = []
            row.setNeedsDisplay()
        }
        cursorLayer.painter = painter
        cursorLayer.contentsScale = font.scale
    }

    // MARK: Drawing

    func gridChanged(_ changes: GridChanges) -> Bool {
        dirty.full = dirty.full || changes.full
        dirty.rows.formUnion(changes.rows)
        dirty.cursor = dirty.cursor || changes.cursor
        guard window != nil else { return false }
        frameWaiting = true
        setNeedsLayout()
        return true
    }

    /// Hands rows that changed to their layers; unchanged rows stay drawn.
    private func flushChanges() {
        guard let grid = controller.grid else { return }
        let changes = dirty
        dirty = GridChanges()
        let rows = changes.full ? IndexSet(integersIn: 0..<rowLayers.count) : changes.rows
        let historyAbove = grid.history.count - grid.scrollOffset
        for index in rows where index < rowLayers.count {
            let content = historyAbove + index
            let links = grid.scrollOffset == 0 ? grid.links.row(UInt16(index), size: grid.size) : []
            rowLayers[index].update(grid.contentRow(content) ?? [], selection: selectedColumns(row: content),
                                    links: links)
        }
        if changes.cursor || changes.full { placeCursor(grid) }
    }

    private func placeCursor(_ grid: RunGrid) {
        let cursor = grid.cursor
        let row = Int(cursor.row) + grid.scrollOffset
        let hidden = !cursor.visible || row >= rowLayers.count || controller.state != .attached
        cursorLayer.isHidden = hidden
        guard !hidden else { return }
        let runs = grid.rows.indices.contains(Int(cursor.row)) ? grid.rows[Int(cursor.row)] : []
        let covered = Self.run(in: runs, at: Int(cursor.col))
        let width = CGFloat(covered.map { TerminalRowPainter.columns($0) } ?? 1) * font.cellWidth
        cursorLayer.frame = CGRect(x: padding.left + CGFloat(cursor.col) * font.cellWidth,
                                   y: padding.top + CGFloat(row) * font.cellHeight, width: width, height: font.cellHeight)
        cursorLayer.shape = cursor.shape
        cursorLayer.focused = isFirstResponder
        cursorLayer.glyph = covered
        cursorLayer.setNeedsDisplay()
        cursorLayer.setBlinking(isFirstResponder && controller.cursorBlinks)
    }

    /// The run covering `column`, as a one-cell run for ASCII.
    private static func run(in runs: [Run], at column: Int) -> Run? {
        var start = 0
        for run in runs {
            let span = TerminalRowPainter.columns(run)
            if column < start + span {
                guard TerminalRowPainter.isSimple(run) else { return run }
                let offset = column - start
                let index = run.text.utf8.index(run.text.utf8.startIndex, offsetBy: offset)
                let byte = run.text.utf8[index]
                return Run(text: String(UnicodeScalar(byte)), width: 1, style: run.style)
            }
            start += span
        }
        return nil
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override var inputAccessoryView: UIView? { accessoryBar }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusChanged() }
        return became
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusChanged() }
        return resigned
    }

    private func focusChanged() {
        if controller.inputModes.focusEvents { controller.send(.focus(isFirstResponder)) }
        dirty.cursor = true
        setNeedsLayout()
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        typed()
        if !stickyModifiers.isEmpty {
            let modifiers = stickyModifiers
            stickyModifiers = []
            if let event = TerminalKeys.event(for: text, modifiers: modifiers) {
                controller.send(.key(event))
                return
            }
        }
        if text == "\n" {
            controller.send(.key(KeyEvent(key: "enter")))
        } else if text == "\t" {
            controller.send(.key(KeyEvent(key: "tab")))
        } else {
            controller.send(.text(text))
        }
    }

    func deleteBackward() {
        typed()
        sendKey("backspace")
    }

    /// Sends a named key, with any latched modifiers.
    func sendKey(_ name: String, modifiers: KeyModifiers = []) {
        typed()
        let all = modifiers.union(stickyModifiers)
        stickyModifiers = []
        controller.send(.key(KeyEvent(key: name, modifiers: all, optionAsAlt: all.contains(.alt))))
    }

    func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        typed()
        controller.paste(text)
    }

    private func typed() {
        clearSelection()
        cursorLayer.setBlinking(controller.cursorBlinks)
    }

    // Hardware keyboards: keys go out as key events, so Control, Option,
    // arrows and function keys reach programs exactly as on the Mac.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, let keyEvent = TerminalKeys.event(for: key) else {
                unhandled.insert(press)
                continue
            }
            typed()
            controller.send(.key(keyEvent))
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, let keyEvent = TerminalKeys.event(for: key, action: .release) else {
                unhandled.insert(press)
                continue
            }
            controller.send(.key(keyEvent))
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Paste", action: #selector(pasteCommand), input: "v", modifierFlags: .command),
            UIKeyCommand(title: "Copy", action: #selector(copyCommand), input: "c", modifierFlags: .command),
            UIKeyCommand(title: "Clear", action: #selector(clearCommand), input: "k", modifierFlags: .command),
            UIKeyCommand(title: "Bigger Text", action: #selector(biggerText), input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Smaller Text", action: #selector(smallerText), input: "-", modifierFlags: .command),
        ]
    }

    @objc private func pasteCommand() { paste() }
    @objc private func copyCommand() { copySelection() }
    @objc private func clearCommand() { controller.clear() }
    @objc private func biggerText() { onFontSizeChange?(min(28, font.size + 1)) }
    @objc private func smallerText() { onFontSizeChange?(max(8, font.size - 1)) }

    // Text input traits: a terminal wants exactly what was typed.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default
    var keyboardAppearance: UIKeyboardAppearance = .default
    var textContentType: UITextContentType! = nil

    // MARK: Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.maximumNumberOfTouches = 1
        pan.allowedScrollTypesMask = .continuous
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        addGestureRecognizer(pinch)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
        press.minimumPressDuration = 0.35
        addGestureRecognizer(press)
        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        editMenu = menu
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        stopMomentum()
        let point = gesture.location(in: self)
        if selection != nil {
            clearSelection()
            return
        }
        if let url = link(at: point) {
            UIApplication.shared.open(url)
            return
        }
        if !isFirstResponder { becomeFirstResponder() }
        guard controller.inputModes.mouseTracking, let cell = cell(at: point) else { return }
        controller.send(.mouse(MouseEvent(action: .press, button: .left, col: cell.col, row: cell.row)))
        controller.send(.mouse(MouseEvent(action: .release, button: .left, col: cell.col, row: cell.row)))
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopMomentum()
            scrollRemainder = 0
        case .changed:
            scrollBy(points: gesture.translation(in: self).y, at: gesture.location(in: self))
            gesture.setTranslation(.zero, in: self)
        case .ended:
            startMomentum(gesture.velocity(in: self).y)
        default:
            break
        }
    }

    /// Positive points move content down, showing older lines.
    private func scrollBy(points: CGFloat, at location: CGPoint) {
        scrollRemainder += points
        let rows = Int(scrollRemainder / font.cellHeight)
        guard rows != 0 else { return }
        scrollRemainder -= CGFloat(rows) * font.cellHeight
        let modes = controller.inputModes
        if modes.mouseTracking || (modes.alternateScroll && controller.grid?.historyTotal == 0) {
            let cell = cell(at: location) ?? (0, 0)
            for _ in 0..<min(abs(rows), 100) {
                controller.send(.mouse(MouseEvent(action: .press, scroll: rows > 0 ? .up : .down,
                                                  col: cell.col, row: cell.row)))
            }
        } else {
            controller.scroll(by: rows)
        }
    }

    private func startMomentum(_ velocity: CGFloat) {
        guard abs(velocity) > 300 else { return }
        momentumVelocity = velocity
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let elapsed = link.targetTimestamp - link.timestamp
        scrollBy(points: momentumVelocity * elapsed, at: CGPoint(x: bounds.midX, y: bounds.midY))
        momentumVelocity *= pow(0.998, elapsed * 1000)
        if abs(momentumVelocity) < 40 { stopMomentum() }
    }

    private func stopMomentum() {
        momentum?.invalidate()
        momentum = nil
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStart = font.size
        case .changed:
            let size = (pinchStart * gesture.scale).rounded()
            if size != font.size, (8...28).contains(size) { onFontSizeChange?(size) }
        default:
            break
        }
    }

    // MARK: Selection

    struct TerminalPoint: Comparable {
        var row: Int
        var column: Int

        static func < (left: TerminalPoint, right: TerminalPoint) -> Bool {
            (left.row, left.column) < (right.row, right.column)
        }
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard let point = contentPoint(at: gesture.location(in: self)) else { return }
        switch gesture.state {
        case .began:
            UISelectionFeedbackGenerator().selectionChanged()
            let word = wordRange(at: point)
            selection = (word.lowerBound, word.upperBound)
            redrawSelection()
        case .changed:
            selection?.head = point
            redrawSelection()
        case .ended:
            let location = gesture.location(in: self)
            editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: location))
        default:
            break
        }
    }

    private func contentPoint(at location: CGPoint) -> TerminalPoint? {
        guard let grid = controller.grid else { return nil }
        let row = Int(floor((location.y - padding.top) / font.cellHeight))
        let column = Int(floor((location.x - padding.left) / font.cellWidth))
        let clampedRow = min(max(row, 0), rowLayers.count - 1)
        return TerminalPoint(row: grid.history.count - grid.scrollOffset + clampedRow,
                             column: min(max(column, 0), Int(gridSize.cols) - 1))
    }

    private func wordRange(at point: TerminalPoint) -> ClosedRange<TerminalPoint> {
        let text = Array(cellText(row: point.row))
        guard point.column < text.count, !text[point.column].isWhitespace else { return point...point }
        var start = point.column
        var end = point.column
        let isWord = { (character: Character) in !character.isWhitespace && !"()[]{}<>\"'`|".contains(character) }
        while start > 0, isWord(text[start - 1]) { start -= 1 }
        while end + 1 < text.count, isWord(text[end + 1]) { end += 1 }
        return TerminalPoint(row: point.row, column: start)...TerminalPoint(row: point.row, column: end)
    }

    /// A row's characters, one per column.
    private func cellText(row: Int) -> [Character] {
        guard let runs = controller.grid?.contentRow(row) else { return [] }
        var characters: [Character] = []
        for run in runs {
            if TerminalRowPainter.isSimple(run) {
                characters.append(contentsOf: run.text)
            } else {
                characters.append(run.text.first ?? " ")
                for _ in 1..<max(1, Int(run.width)) { characters.append(" ") }
            }
        }
        return characters
    }

    private func selectedColumns(row: Int) -> Range<Int>? {
        guard let selection else { return nil }
        let start = min(selection.anchor, selection.head)
        let end = max(selection.anchor, selection.head)
        guard row >= start.row, row <= end.row else { return nil }
        let from = row == start.row ? start.column : 0
        let to = row == end.row ? end.column + 1 : Int.max
        return from..<to
    }

    var selectedText: String? {
        guard let selection else { return nil }
        let start = min(selection.anchor, selection.head)
        let end = max(selection.anchor, selection.head)
        var lines: [String] = []
        for row in start.row...end.row {
            let characters = cellText(row: row)
            let from = row == start.row ? start.column : 0
            let to = row == end.row ? min(end.column + 1, characters.count) : characters.count
            var line = from < to ? String(characters[from..<to]) : ""
            while line.last == " " { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func copySelection() {
        guard let text = selectedText else { return }
        UIPasteboard.general.string = text
        clearSelection()
    }

    private func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        redrawSelection()
    }

    private func redrawSelection() {
        dirty.full = true
        flushChanges()
    }

    // MARK: Hit testing

    private func cell(at location: CGPoint) -> (col: UInt16, row: UInt16)? {
        guard gridSize.cols > 0 else { return nil }
        let col = Int(floor((location.x - padding.left) / font.cellWidth))
        let row = Int(floor((location.y - padding.top) / font.cellHeight))
        return (UInt16(min(max(col, 0), Int(gridSize.cols) - 1)), UInt16(min(max(row, 0), Int(gridSize.rows) - 1)))
    }

    private func link(at location: CGPoint) -> URL? {
        guard let grid = controller.grid, grid.scrollOffset == 0, let cell = cell(at: location) else { return nil }
        let span = grid.links.row(cell.row, size: grid.size).first { cell.col >= $0.start && cell.col < $0.end }
        return span.flatMap { URL(string: $0.uri) }
    }
}

extension TerminalView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions: [UIMenuElement] = []
        if selection != nil {
            actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copySelection()
            })
        }
        if UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.paste()
            })
        }
        return UIMenu(children: actions)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {}
}
