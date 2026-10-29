import AppKit
import TabClient
import TabCore
import TabProtocol

/// What a terminal does besides typing, for menus and shortcuts.
public enum TerminalCommand: Hashable, Sendable {
    case copy
    case paste
    case selectAll
    case selectCommandOutput
    case clearScreen
    case scrollToTop
    case scrollToBottom
    case scrollPageUp
    case scrollPageDown
    case previousPrompt
    case nextPrompt
    case find
    case findNext
    case findPrevious
    case increaseFontSize(Double)
    case decreaseFontSize(Double)
    case resetFontSize
    case reloadConfiguration
}

/// How a terminal handles a key: a key binding from `terminal.json` (or a
/// built-in one), or one of the terminal's own shortcuts.
public enum TerminalKeyHandling: Equatable, Sendable {
    case binding(TerminalAction)
    case command(TerminalCommand)
}

/// What the shell provides to a terminal view: opening links, its menu items,
/// and notifications.
@MainActor public protocol TerminalViewDelegate: AnyObject {
    func terminalView(_ view: TerminalView, openURL url: URL)
    /// A file on this computer, at an optional line and column.
    func terminalView(_ view: TerminalView, openFile path: String, line: Int?, column: Int?)
    /// A file on the terminal's remote server: offer a read-only copy or the path.
    func terminalView(_ view: TerminalView, openRemoteFile path: String, line: Int?, column: Int?)
    /// The shell's items in the right-click menu.
    func terminalViewContextMenuItems(_ view: TerminalView) -> TerminalContextMenu.ShellItems
    func terminalView(_ view: TerminalView, perform item: TerminalContextMenu.Item)
    func terminalView(_ view: TerminalView, didChangeFocus focused: Bool)
}

public extension TerminalViewDelegate {
    func terminalView(_ view: TerminalView, openRemoteFile path: String, line: Int?, column: Int?) {}
    func terminalViewContextMenuItems(_ view: TerminalView) -> TerminalContextMenu.ShellItems {
        TerminalContextMenu.ShellItems()
    }
    func terminalView(_ view: TerminalView, perform item: TerminalContextMenu.Item) {}
    func terminalView(_ view: TerminalView, didChangeFocus focused: Bool) {}
}

/// The session side of a terminal view: input goes to the server, scrolling
/// pages history, and commands that need the session run there.
@MainActor protocol TerminalViewHost: AnyObject {
    var isLive: Bool { get }
    var isRemote: Bool { get }
    /// The terminal's folder on its server, for relative link paths.
    var linkDirectory: String? { get }
    func terminalView(_ view: TerminalView, send input: TerminalInput)
    /// Scrolls history by rows (positive is older), fetching pages as needed.
    func terminalView(_ view: TerminalView, scrollBy rows: Int)
    /// Scrolls to an offset above live output, fetching pages as needed.
    func terminalView(_ view: TerminalView, scrollTo offset: Int)
    func terminalView(_ view: TerminalView, perform command: TerminalCommand, at point: TerminalPoint?)
    func terminalView(_ view: TerminalView, dropFiles paths: [String])
    func terminalView(_ view: TerminalView, pasteImage png: Data)
    func terminalView(_ view: TerminalView, didChangeViewport viewport: Size)
    func terminalView(_ view: TerminalView, didChangeFocus focused: Bool)
}

/// A terminal's screen: draws the session's rows through a `TerminalRenderer`,
/// redrawing only rows that changed, and turns keys, the mouse, the input
/// method, pastes and drops into terminal input.
public final class TerminalView: NSView, NSTextInputClient, NSMenuItemValidation {
    public weak var delegate: TerminalViewDelegate?
    weak var host: TerminalViewHost?

    /// The screen shown, with fetched history and the scroll position.
    public private(set) var grid: RunGrid?
    public private(set) var settings: TerminalSettings
    public private(set) var palette: TerminalPalette
    public private(set) var fonts: TerminalFontSet
    public private(set) var metrics: TerminalMetrics
    public private(set) var layout: TerminalLayout
    /// The pane card's own inset, subtracted from the configured padding.
    public var basePadding: CGFloat = 0 { didSet { if basePadding != oldValue { relayout() } } }
    /// Font size for this pane, when changed with Cmd+= / Cmd+-.
    public private(set) var fontSize: Double

    public private(set) var selection: TerminalSelection?
    public internal(set) var inputModes = InputModes()
    /// Set from the session: whether the program asked the cursor to blink.
    public var cursorBlinks = true { didSet { if cursorBlinks != oldValue { syncBlink() } } }
    /// Terminal shortcuts that are app shortcuts in the menu bar; the view
    /// handles them while focused so they work in any host. The shell can
    /// replace them with the user's keymap.
    public var shortcuts: [KeyChord: TerminalCommand] = TerminalView.defaultShortcuts
    /// Turns off the built-in key bindings (Cmd+K, Shift+Return…), keeping the user's.
    public var builtInBindingsEnabled = true
    /// The find state whose matches are highlighted.
    public var find: TerminalFind? { didSet { if find != oldValue { needsDisplay = true } } }

    let renderer: TerminalRenderer
    let scrollbar = TerminalScrollbar()
    private var dirty: [CGRect] = []
    private var markedText = ""
    private var markedSelection = NSRange(location: 0, length: 0)
    private var pendingKey: KeyEvent?
    private var pressed: [UInt16: KeyEvent] = [:]
    private var blinkTimer: Timer?
    private var blinkVisible = true
    private var focused = false
    private var link: TerminalLinkCandidate?
    private var dragUnit: DragUnit?
    private var selectionFingerprint: [String] = []
    private var heldButtons: Set<MouseButton> = []
    private var lastMouse: MouseEvent?
    private var wheelRemainder: CGFloat = 0
    private var scrollRemainder: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var lastCursorRow: Int?

    private enum DragUnit {
        case cell
        case word(TerminalSelection)
        case line(TerminalSelection)
    }

    public static let defaultShortcuts: [KeyChord: TerminalCommand] = {
        let entries: [(String, TerminalCommand)] = [
            ("cmd-c", .copy), ("cmd-v", .paste), ("cmd-f", .find), ("cmd-g", .findNext),
            ("cmd-shift-g", .findPrevious), ("cmd-up", .previousPrompt), ("cmd-down", .nextPrompt),
            ("cmd-=", .increaseFontSize(1)), ("cmd-shift-=", .increaseFontSize(1)), ("cmd-minus", .decreaseFontSize(1)),
        ]
        return Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            (try? KeyChord(entry.0)).map { ($0, entry.1) }
        })
    }()

    public init(settings: TerminalSettings, palette: TerminalPalette, renderer: TerminalRenderer? = nil) {
        self.settings = settings
        self.palette = palette
        self.renderer = renderer ?? CoreTextRenderer()
        fontSize = settings.fontSize
        fonts = TerminalFontSet(settings: settings)
        metrics = TerminalMetrics(fonts: fonts, cellWidth: settings.font.cellWidth, cellHeight: settings.cellHeight,
                                  scale: NSScreen.main?.backingScaleFactor ?? 2)
        layout = TerminalLayout(bounds: .zero, metrics: metrics, options: settings.options)
        cursorBlinks = palette.cursorBlink ?? true
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL, .string, .png, .tiff])
        scrollbar.onScroll = { [weak self] offset in
            guard let self else { return }
            self.host?.terminalView(self, scrollTo: Int(offset.rounded()))
        }
        addSubview(scrollbar)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { palette.isOpaque }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Configuration

    /// Applies new terminal settings and colors, re-measuring the font when
    /// it changed.
    public func configure(settings: TerminalSettings, palette: TerminalPalette) {
        let fontChanged = settings.fontFamilies != self.settings.fontFamilies || settings.font != self.settings.font
            || settings.cellHeight != self.settings.cellHeight || settings.fontSize != self.settings.fontSize
        if settings.fontSize != self.settings.fontSize { fontSize = settings.fontSize }
        self.settings = settings
        let paletteChanged = palette != self.palette
        if palette.cursorBlink != self.palette.cursorBlink { cursorBlinks = palette.cursorBlink ?? true }
        self.palette = palette
        if fontChanged {
            remeasure()
        } else {
            relayout()
        }
        if paletteChanged {
            renderer.invalidateAll()
            scrollbar.thumbColor = NSColor(cgColor: CGColor.terminal(palette.foreground, alpha: 0.3)) ?? .gray
            needsDisplay = true
        }
        syncBlink()
    }

    /// Changes this pane's font size; `nil` goes back to the configured size.
    public func setFontSize(_ size: Double?) {
        let next = min(max(size ?? settings.fontSize, 1), 256)
        guard next != fontSize else { return }
        fontSize = next
        remeasure()
    }

    private func remeasure() {
        fonts = TerminalFontSet(settings: settings, size: fontSize)
        metrics = TerminalMetrics(fonts: fonts, cellWidth: settings.font.cellWidth, cellHeight: settings.cellHeight,
                                  scale: window?.backingScaleFactor ?? metrics.scale)
        renderer.invalidateAll()
        relayout(force: true)
    }

    private func relayout(force: Bool = false) {
        let next = TerminalLayout(bounds: bounds, metrics: metrics, options: settings.options, basePadding: basePadding)
        guard force || next != layout else { return }
        let viewportChanged = next.viewport != layout.viewport
        layout = next
        scrollbar.frame = CGRect(x: bounds.maxX - TerminalScrollbar.width * 2 - TerminalScrollbar.edgeGap,
                                 y: bounds.minY, width: TerminalScrollbar.width * 2 + TerminalScrollbar.edgeGap,
                                 height: bounds.height)
        needsDisplay = true
        if viewportChanged || force, bounds.width > 0, bounds.height > 0 {
            host?.terminalView(self, didChangeViewport: layout.viewport)
        }
    }

    /// The grid size that fits the view.
    public var viewport: Size { layout.viewport }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor, scale != metrics.scale else { return }
        remeasure()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged),
                                                   name: NSWindow.didResignKeyNotification, object: window)
            if window.backingScaleFactor != metrics.scale { remeasure() }
        }
        windowKeyChanged()
    }

    // MARK: Grid

    /// Replaces the grid, such as with a session's first or cached screen.
    public func setGrid(_ grid: RunGrid?) {
        self.grid = grid
        _ = self.grid?.takeChanges()
        lastCursorRow = nil
        validateSelection()
        needsDisplay = true
        updateScrollbar()
    }

    /// Changes the grid in place and redraws only what changed. Returns
    /// whether anything visible was invalidated.
    @discardableResult
    public func updateGrid(_ body: (inout RunGrid) -> Void) -> Bool {
        guard grid != nil else { return false }
        let graphicsBefore = grid?.graphics.map(GraphicsIdentity.init)
        body(&grid!)
        guard let changes = grid?.takeChanges() else { return false }
        var invalidated = invalidate(changes)
        if grid?.graphics.map(GraphicsIdentity.init) != graphicsBefore {
            needsDisplay = true
            invalidated = true
        }
        validateSelection()
        updateScrollbar()
        if changes.full { syncBlink() }
        return invalidated
    }

    private func invalidate(_ changes: GridChanges) -> Bool {
        guard let grid, !changes.isEmpty else { return false }
        if changes.full {
            needsDisplay = true
            return true
        }
        let rows = Int(layout.viewport.rows)
        var touched = IndexSet()
        for row in changes.rows {
            let visible = row + grid.scrollOffset
            if visible >= 0, visible < rows { touched.insert(visible) }
        }
        if changes.cursor {
            let current = grid.scrollOffset == 0 ? Int(grid.cursor.row) : nil
            for row in [lastCursorRow, current].compactMap({ $0 }) where row < rows { touched.insert(row) }
            lastCursorRow = current
            restartBlinkPhase()
        }
        renderer.invalidate(rows: touched)
        for row in touched { setNeedsDisplay(layout.rowRect(row)) }
        return !touched.isEmpty
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        dirty.removeAll(keepingCapacity: true)
        var rects: UnsafePointer<NSRect>?
        var count = 0
        getRectsBeingDrawn(&rects, count: &count)
        if let rects, count > 0 {
            for index in 0..<count { dirty.append(rects[index]) }
        } else {
            dirty.append(dirtyRect)
        }
        guard let grid else {
            context.setFillColor(CGColor.terminal(palette.background, alpha: CGFloat(palette.backgroundOpacity)))
            for rect in dirty { context.fill(rect) }
            return
        }
        let state = TerminalRenderState(
            grid: grid, layout: layout, metrics: metrics, fonts: fonts, palette: palette, cursor: cursorState(grid),
            selection: selection, find: find, link: link, markedText: markedText.isEmpty ? nil : markedText)
        renderer.draw(state, dirty: dirty, in: context)
    }

    private func cursorState(_ grid: RunGrid) -> TerminalCursorState {
        let live = host?.isLive ?? true
        let visible = live && focused && blinkVisible && grid.scrollOffset == 0 && grid.cursor.visible
            && grid.cursor.col < grid.size.cols && Int(grid.cursor.row) < Int(layout.viewport.rows)
        return TerminalCursorState(visible: visible || !markedText.isEmpty && focused, shape: grid.cursor.shape,
                                   row: Int(grid.cursor.row), column: Int(grid.cursor.col),
                                   thickness: settings.options.cursorThickness)
    }

    // MARK: Cursor blink

    private var shouldBlink: Bool {
        guard let grid, cursorBlinks, focused, host?.isLive ?? true, grid.scrollOffset == 0,
              grid.cursor.visible, markedText.isEmpty else { return false }
        return true
    }

    private func syncBlink() {
        guard shouldBlink else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            if !blinkVisible {
                blinkVisible = true
                invalidateCursor()
            }
            return
        }
        guard blinkTimer == nil else { return }
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated {
                guard self.shouldBlink else { return self.syncBlink() }
                self.blinkVisible.toggle()
                self.invalidateCursor()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func restartBlinkPhase() {
        if !blinkVisible {
            blinkVisible = true
            invalidateCursor()
        }
        if blinkTimer != nil {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
        syncBlink()
    }

    private func invalidateCursor() {
        guard let grid, grid.scrollOffset == 0 else { return }
        setNeedsDisplay(layout.rowRect(Int(grid.cursor.row)))
    }

    // MARK: Focus

    public override func becomeFirstResponder() -> Bool {
        windowKeyChanged()
        return true
    }

    public override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.windowKeyChanged() }
        setFocused(false)
        return true
    }

    @objc private func windowKeyChanged() {
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        setFocused(focused)
    }

    private func setFocused(_ value: Bool) {
        guard value != focused else { return }
        focused = value
        if !value {
            releaseKeys()
            releaseButtons()
            if !markedText.isEmpty {
                markedText = ""
                inputContext?.discardMarkedText()
            }
            dragUnit = nil
        }
        blinkVisible = true
        syncBlink()
        invalidateCursor()
        host?.terminalView(self, didChangeFocus: value)
        delegate?.terminalView(self, didChangeFocus: value)
    }

    public var isFocused: Bool { focused }

    // MARK: Keyboard

    /// How the terminal handles `event`, if it is one of its key bindings or
    /// shortcuts. The shell asks before running app shortcuts.
    public func handledShortcut(_ event: NSEvent) -> TerminalKeyHandling? {
        guard let chord = KeyMapping.chord(event) else { return nil }
        let bindings = settings.keybindings
        if let action = bindings.bindings[chord] {
            return action == .unbind ? nil : .binding(action)
        }
        if builtInBindingsEnabled, !bindings.clearDefaults, let action = TerminalBindings.defaults[chord] {
            return .binding(action)
        }
        return shortcuts[chord].map(TerminalKeyHandling.command)
    }

    /// Whether the terminal takes `event` while focused: its bindings and
    /// shortcuts, and every key without Command (those go to the program).
    public func canHandle(_ event: NSEvent) -> Bool {
        if let chord = KeyMapping.chord(event), settings.keybindings.bindings[chord] == .unbind { return true }
        return handledShortcut(event) != nil || !event.modifierFlags.contains(.command)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, markedText.isEmpty,
              let handling = handledShortcut(event) else { return super.performKeyEquivalent(with: event) }
        perform(handling, event: event)
        return true
    }

    public override func keyDown(with event: NSEvent) {
        if !markedText.isEmpty {
            interpretKeyEvents([event])
            return
        }
        if let handling = handledShortcut(event) {
            perform(handling, event: event)
            return
        }
        let unbound = KeyMapping.chord(event).map { settings.keybindings.bindings[$0] == .unbind } ?? false
        if !unbound, event.modifierFlags.contains(.command) { return }
        if !event.isARepeat, KeyMapping.usesTextInput(event, optionAsAlt: settings.optionAsAlt) {
            pendingKey = KeyMapping.keyEvent(event, optionAsAlt: settings.optionAsAlt)
            interpretKeyEvents([event])
            pendingKey = nil
            return
        }
        sendKey(KeyMapping.keyEvent(event, optionAsAlt: settings.optionAsAlt))
    }

    public override func keyUp(with event: NSEvent) {
        guard let press = pressed.removeValue(forKey: event.keyCode) else { return }
        var release = press
        release.action = .release
        release.text = ""
        release.modifiers = KeyMapping.keyModifiers(event.modifierFlags)
        host?.terminalView(self, send: .key(release))
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateLinkHover(at: window?.mouseLocationOutsideOfEventStream, flags: event.modifierFlags)
    }

    private func perform(_ handling: TerminalKeyHandling, event: NSEvent) {
        switch handling {
        case .command(let command):
            perform(command)
        case .binding(let action):
            perform(action, event: event)
        }
    }

    private func perform(_ action: TerminalAction, event: NSEvent) {
        switch action {
        case .text(let bytes):
            guard prepareInput() else { return }
            host?.terminalView(self, send: .bytes(Data(bytes)))
        case .ignore:
            break
        case .unbind:
            sendKey(KeyMapping.keyEvent(event, optionAsAlt: settings.optionAsAlt))
        case .copy: perform(.copy)
        case .paste: perform(.paste)
        case .selectAll: perform(.selectAll)
        case .reload: perform(.reloadConfiguration)
        case .clearScreen: perform(.clearScreen)
        case .scrollTop: perform(.scrollToTop)
        case .scrollBottom: perform(.scrollToBottom)
        case .scrollPageUp: perform(.scrollPageUp)
        case .scrollPageDown: perform(.scrollPageDown)
        case .increaseFontSize(let amount): perform(.increaseFontSize(amount))
        case .decreaseFontSize(let amount): perform(.decreaseFontSize(amount))
        case .resetFontSize: perform(.resetFontSize)
        }
    }

    /// Runs a terminal command, from a shortcut, a menu or the shell.
    public func perform(_ command: TerminalCommand, at point: TerminalPoint? = nil) {
        switch command {
        case .copy:
            copySelection()
        case .paste:
            pasteClipboard()
        case .selectAll:
            guard let grid else { return }
            select(TerminalSelection.all(in: grid))
        case .scrollToTop:
            host?.terminalView(self, scrollBy: Int.max / 2)
        case .scrollToBottom:
            host?.terminalView(self, scrollTo: 0)
        case .scrollPageUp:
            host?.terminalView(self, scrollBy: Int(layout.viewport.rows))
        case .scrollPageDown:
            host?.terminalView(self, scrollBy: -Int(layout.viewport.rows))
        case .increaseFontSize(let amount):
            setFontSize(fontSize + amount)
        case .decreaseFontSize(let amount):
            setFontSize(fontSize - amount)
        case .resetFontSize:
            setFontSize(nil)
        case .selectCommandOutput, .clearScreen, .previousPrompt, .nextPrompt, .find, .findNext, .findPrevious,
             .reloadConfiguration:
            host?.terminalView(self, perform: command, at: point)
        }
    }

    private func sendKey(_ event: KeyEvent) {
        guard (try? TerminalInput.key(event).validate()) != nil, prepareInput() else { return }
        if let code = keyCode(of: event) { pressed[code] = event }
        host?.terminalView(self, send: .key(event))
    }

    private func keyCode(of event: KeyEvent) -> UInt16? {
        guard event.action != .release, let current = NSApp.currentEvent, current.type == .keyDown else { return nil }
        return current.keyCode
    }

    private func releaseKeys() {
        let keys = pressed
        pressed = [:]
        for (_, press) in keys {
            var release = press
            release.action = .release
            release.text = ""
            host?.terminalView(self, send: .key(release))
        }
    }

    /// Before input: back to live output, clear the selection when asked,
    /// show the cursor. Returns whether the terminal takes input.
    private func prepareInput() -> Bool {
        guard host?.isLive ?? false else { return false }
        if settings.options.scrollOnKeystroke, let grid, grid.scrollOffset > 0 {
            host?.terminalView(self, scrollTo: 0)
        }
        if settings.options.selectionClearOnTyping, selection != nil {
            clearSelection()
        }
        restartBlinkPhase()
        return true
    }

    // MARK: NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let hadMarked = !markedText.isEmpty
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        if hadMarked { invalidateCursor() }
        guard !text.isEmpty else { return }
        if var key = pendingKey {
            pendingKey = nil
            key.text = text
            if (try? TerminalInput.key(key).validate()) != nil {
                sendKey(key)
                return
            }
        }
        guard prepareInput() else { return }
        for chunk in TerminalPaste.chunks(text) { host?.terminalView(self, send: .text(chunk)) }
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedSelection = selectedRange
        pendingKey = nil
        syncBlink()
        invalidateCursor()
    }

    public func unmarkText() {
        let text = markedText
        markedText = ""
        if !text.isEmpty { insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    public func selectedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: 0, length: 0) : markedSelection
    }

    public func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }

    public func hasMarkedText() -> Bool { !markedText.isEmpty }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
        -> NSAttributedString? {
        let text = markedText as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        actualRange?.pointee = clamped
        return NSAttributedString(string: text.substring(with: clamped))
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let grid, let window else { return .zero }
        let rect = layout.cellRect(row: Int(grid.cursor.row), column: Int(grid.cursor.col))
        return window.convertToScreen(convert(rect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    public override func doCommand(by selector: Selector) {
        guard let key = pendingKey else { return }
        pendingKey = nil
        sendKey(key)
    }

    // MARK: Selection

    /// The cell under a point in view coordinates; `nearest` rounds to the
    /// closest cell edge, for selection boundaries.
    public func point(at location: CGPoint, nearest: Bool = false) -> TerminalPoint? {
        guard let grid else { return nil }
        let x = (location.x - layout.grid.minX) / layout.cellWidth
        let column = nearest ? x.rounded() : x.rounded(.down)
        let rows = max(1, Int(layout.viewport.rows))
        let row = min(max(Int(((location.y - layout.grid.minY) / layout.cellHeight).rounded(.down)), 0), rows - 1)
        let clamped = UInt16(min(max(column, 0), CGFloat(grid.size.cols)))
        return TerminalPoint(row: row - grid.scrollOffset, column: clamped)
    }

    public func select(_ selection: TerminalSelection?) {
        let next = selection.flatMap { $0.isEmpty ? nil : $0 }
        guard next != self.selection else { return }
        self.selection = next
        selectionFingerprint = grid.flatMap { grid in next.map { $0.fingerprint(in: grid) } } ?? []
        needsDisplay = true
    }

    public func clearSelection() {
        select(nil)
        dragUnit = nil
    }

    /// Drops the selection when the text under it changed.
    private func validateSelection() {
        guard let selection, let grid else { return }
        if selection.fingerprint(in: grid) != selectionFingerprint { clearSelection() }
    }

    public var selectedText: String? {
        guard let selection, let grid else { return nil }
        let text = selection.text(in: grid)
        return text.isEmpty ? nil : text
    }

    @discardableResult
    public func copySelection() -> Bool {
        guard let text = selectedText else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if settings.options.selectionClearOnCopy { clearSelection() }
        return true
    }

    // MARK: Paste and drop

    public func pasteClipboard() {
        paste(from: NSPasteboard.general)
    }

    func paste(from pasteboard: NSPasteboard) {
        guard host?.isLive ?? false else { return }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL], !urls.isEmpty {
            host?.terminalView(self, dropFiles: urls.map(\.path))
            return
        }
        if let text = pasteboard.string(forType: .string) {
            pasteText(text)
            return
        }
        if let png = Self.pngData(pasteboard) {
            host?.terminalView(self, pasteImage: png)
        }
    }

    /// Sends text as a paste, bracketed by the engine when the program asked.
    public func pasteText(_ text: String) {
        guard !text.isEmpty, prepareInput() else { return }
        for chunk in TerminalPaste.chunks(text) { host?.terminalView(self, send: .paste(chunk)) }
    }

    static func pngData(_ pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png) { return data }
        guard let tiff = pasteboard.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff) else { return nil }
        return image.representation(using: .png, properties: [:])
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        host?.isLive ?? false ? .copy : []
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard host?.isLive ?? false else { return false }
        paste(from: sender.draggingPasteboard)
        return true
    }

    // MARK: Mouse

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect,
                                                         .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    private func reportsMouse(_ flags: NSEvent.ModifierFlags) -> Bool {
        (host?.isLive ?? false) && settings.options.mouseReporting && inputModes.mouseTracking
            && !flags.contains(.shift)
    }

    private var reportsWheel: Bool {
        (host?.isLive ?? false) && settings.options.mouseReporting
            && (inputModes.mouseTracking || inputModes.alternateScroll)
    }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = location(event)
        if event.modifierFlags.contains(.command), openLink(at: location) { return }
        if reportsMouse(event.modifierFlags) {
            sendMouse(.press, button: .left, at: location, flags: event.modifierFlags)
            return
        }
        guard let grid, let point = point(at: location, nearest: event.clickCount < 2) else { return }
        let rectangular = event.modifierFlags.contains(.option)
        switch event.clickCount {
        case 2:
            let word = TerminalSelection.word(at: self.point(at: location) ?? point, in: grid)
            dragUnit = .word(word)
            select(word)
        case 3...:
            let line = TerminalSelection.line(at: point, in: grid)
            dragUnit = .line(line)
            select(line)
        default:
            if event.modifierFlags.contains(.shift), var current = selection {
                current.head = point
                dragUnit = .cell
                dragOrigin = current
                select(current)
            } else {
                dragUnit = .cell
                select(nil)
                dragOrigin = TerminalSelection(anchor: point, head: point, rectangular: rectangular)
            }
        }
    }

    private var dragOrigin: TerminalSelection?

    public override func mouseDragged(with event: NSEvent) {
        let location = location(event)
        if heldButtons.contains(.left) {
            sendMouse(.motion, button: .left, at: location, flags: event.modifierFlags)
            return
        }
        guard let grid, let unit = dragUnit else { return }
        if location.y < layout.grid.minY {
            host?.terminalView(self, scrollBy: 1)
        } else if location.y > layout.grid.maxY {
            host?.terminalView(self, scrollBy: -1)
        }
        guard let point = point(at: location, nearest: true) else { return }
        switch unit {
        case .cell:
            guard var current = dragOrigin else { return }
            current.head = point
            current.rectangular = current.rectangular || event.modifierFlags.contains(.option)
            select(current)
        case .word(let origin):
            let word = TerminalSelection.word(at: self.point(at: location) ?? point, in: grid)
            select(Self.union(origin, word))
        case .line(let origin):
            select(Self.union(origin, TerminalSelection.line(at: point, in: grid)))
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if heldButtons.contains(.left) {
            sendMouse(.release, button: .left, at: location(event), flags: event.modifierFlags)
            return
        }
        dragOrigin = nil
        guard dragUnit != nil else { return }
        dragUnit = nil
        if settings.options.copyOnSelect ?? false, let text = selectedText {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        let location = location(event)
        updateLinkHover(at: event.locationInWindow, flags: event.modifierFlags)
        if reportsMouse(event.modifierFlags) {
            sendMouse(.motion, button: nil, at: location, flags: event.modifierFlags)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        setLink(nil)
    }

    public override func rightMouseDown(with event: NSEvent) {
        if reportsMouse(event.modifierFlags) {
            sendMouse(.press, button: .right, at: location(event), flags: event.modifierFlags)
            return
        }
        super.rightMouseDown(with: event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        if heldButtons.contains(.right) {
            sendMouse(.release, button: .right, at: location(event), flags: event.modifierFlags)
            return
        }
        super.rightMouseUp(with: event)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard reportsMouse(event.modifierFlags) else { return }
        sendMouse(.press, button: Self.button(event.buttonNumber), at: location(event), flags: event.modifierFlags)
    }

    public override func otherMouseUp(with event: NSEvent) {
        let button = Self.button(event.buttonNumber)
        guard heldButtons.contains(button) else { return }
        sendMouse(.release, button: button, at: location(event), flags: event.modifierFlags)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        guard heldButtons.contains(.right) else { return }
        sendMouse(.motion, button: .right, at: location(event), flags: event.modifierFlags)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        let button = Self.button(event.buttonNumber)
        guard heldButtons.contains(button) else { return }
        sendMouse(.motion, button: button, at: location(event), flags: event.modifierFlags)
    }

    private static func button(_ number: Int) -> MouseButton {
        switch number {
        case 3: return .back
        case 4: return .forward
        default: return .middle
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        if reportsMouse(event.modifierFlags) { return nil }
        let location = location(event)
        let shell = delegate?.terminalViewContextMenuItems(self) ?? TerminalContextMenu.ShellItems()
        let state = TerminalContextMenu.TerminalState(hasSelection: selection != nil, isLive: host?.isLive ?? false,
                                                      hasContent: grid != nil)
        let point = self.point(at: location)
        return TerminalContextMenu.menu(terminal: state, shell: shell) { [weak self] item in
            self?.performMenuItem(item, at: point)
        }
    }

    /// Runs a context menu item: the terminal's own, or the shell's.
    public func performMenuItem(_ item: TerminalContextMenu.Item, at point: TerminalPoint? = nil) {
        switch item {
        case .copy: perform(.copy)
        case .paste: perform(.paste)
        case .selectAll: perform(.selectAll)
        case .selectCommandOutput: perform(.selectCommandOutput, at: point)
        case .find: perform(.find)
        case .clear: perform(.clearScreen)
        default: delegate?.terminalView(self, perform: item)
        }
    }

    private func sendMouse(_ action: MouseAction, button: MouseButton?, scroll: ScrollDirection? = nil, at location: CGPoint,
                           flags: NSEvent.ModifierFlags) {
        guard host?.isLive ?? false else { return }
        let cols = max(1, Int(layout.viewport.cols))
        let rows = max(1, Int(layout.viewport.rows))
        let column = min(max(Int(((location.x - layout.grid.minX) / layout.cellWidth).rounded(.down)), 0), cols - 1)
        let row = min(max(Int(((location.y - layout.grid.minY) / layout.cellHeight).rounded(.down)), 0), rows - 1)
        var modifiers = KeyMapping.keyModifiers(flags)
        modifiers.remove([.super, .capsLock])
        let event = MouseEvent(action: action, button: button, scroll: scroll, col: UInt16(column), row: UInt16(row),
                               modifiers: modifiers)
        if action == .motion, lastMouse == event { return }
        lastMouse = event
        if let button {
            if action == .press { heldButtons.insert(button) }
            if action == .release { heldButtons.remove(button) }
        }
        host?.terminalView(self, send: .mouse(event))
    }

    private func releaseButtons() {
        guard let last = lastMouse else { return }
        for button in heldButtons {
            host?.terminalView(self, send: .mouse(MouseEvent(action: .release, button: button, col: last.col,
                                                             row: last.row, modifiers: last.modifiers)))
        }
        heldButtons = []
        lastMouse = nil
        wheelRemainder = 0
    }

    public override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        let rows = precise
            ? event.scrollingDeltaY / max(layout.cellHeight, 1) * CGFloat(settings.options.scrollPrecision)
            : event.scrollingDeltaY * CGFloat(settings.options.scrollDiscrete)
        if reportsWheel, !event.modifierFlags.contains(.shift) {
            if rows.sign != wheelRemainder.sign { wheelRemainder = 0 }
            wheelRemainder = min(max(wheelRemainder + rows, -100), 100)
            if abs(wheelRemainder) >= 1, let grid, grid.scrollOffset > 0 {
                host?.terminalView(self, scrollTo: 0)
            }
            let location = location(event)
            while abs(wheelRemainder) >= 1 {
                sendMouse(.scroll, button: nil, scroll: wheelRemainder > 0 ? .up : .down, at: location,
                          flags: event.modifierFlags)
                wheelRemainder -= wheelRemainder > 0 ? 1 : -1
            }
            return
        }
        wheelRemainder = 0
        if event.phase == .began || event.phase == .mayBegin { scrollRemainder = 0 }
        scrollRemainder += rows
        let whole = Int(scrollRemainder.rounded(.towardZero))
        guard whole != 0 else { return }
        scrollRemainder -= CGFloat(whole)
        host?.terminalView(self, scrollBy: whole)
    }

    private func updateScrollbar() {
        guard let grid else {
            scrollbar.hide()
            return
        }
        let scrollable = reportsWheel ? 0 : Double(grid.historyTotal)
        scrollbar.visibleRows = Double(layout.viewport.rows)
        scrollbar.scrollable = scrollable
        scrollbar.offset = Double(grid.scrollOffset)
        if grid.scrollOffset != lastScrollOffset {
            lastScrollOffset = grid.scrollOffset
            scrollbar.reveal()
            syncBlink()
            if grid.scrollOffset == 0 { lastCursorRow = nil }
        }
    }

    private var lastScrollOffset = 0

    // MARK: Links

    private func updateLinkHover(at windowLocation: NSPoint?, flags: NSEvent.ModifierFlags) {
        guard flags.contains(.command), let windowLocation else { return setLink(nil) }
        let location = convert(windowLocation, from: nil)
        guard bounds.contains(location) else { return setLink(nil) }
        let candidate = linkCandidate(at: location)
        setLink(candidate.flatMap { linkTarget(for: $0) == nil ? nil : $0 })
    }

    private func setLink(_ candidate: TerminalLinkCandidate?) {
        guard candidate != link else { return }
        for old in [link, candidate].compactMap({ $0 }) { invalidateContentRow(old.row) }
        link = candidate
        if candidate != nil { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
    }

    private func invalidateContentRow(_ row: Int) {
        guard let grid else { return }
        let visible = row + grid.scrollOffset
        if visible >= 0, visible < Int(layout.viewport.rows) { setNeedsDisplay(layout.rowRect(visible)) }
    }

    /// The link under a point: an OSC 8 hyperlink, a URL or a path.
    public func linkCandidate(at location: CGPoint) -> TerminalLinkCandidate? {
        guard let grid, layout.grid.contains(location), let point = point(at: location) else { return nil }
        let runs = grid.contentRow(grid.history.count + point.row) ?? []
        let links = point.row >= 0 ? grid.links.row(UInt16(point.row), size: grid.size) : []
        return TerminalLinkDetector.detect(runs: runs, row: point.row, column: point.column, links: links)
    }

    func linkTarget(for candidate: TerminalLinkCandidate) -> TerminalLinkTarget? {
        let remote = host?.isRemote ?? false
        let target = TerminalLinkDetector.target(
            for: candidate.text, directory: host?.linkDirectory, home: remote ? nil : NSHomeDirectory(),
            exists: remote ? nil : { FileManager.default.fileExists(atPath: $0) })
        if remote, case .file(let path, _, _)? = target, !Self.looksLikePath(candidate.text) || path.isEmpty {
            return nil
        }
        return target
    }

    static func looksLikePath(_ text: String) -> Bool {
        if text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../")
            || text.lowercased().hasPrefix("file://") { return true }
        let path = TerminalLinkDetector.location(text).0
        guard let dot = path.lastIndex(of: "."), dot != path.startIndex else { return false }
        let ext = path[path.index(after: dot)...]
        return path.contains("/") && !ext.isEmpty && ext.count <= 8 && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Opens the link under a point; returns whether there was one.
    @discardableResult
    public func openLink(at location: CGPoint) -> Bool {
        guard let candidate = linkCandidate(at: location), let target = linkTarget(for: candidate) else { return false }
        switch target {
        case .url(let url):
            delegate?.terminalView(self, openURL: url)
        case .file(let path, let line, let column):
            if host?.isRemote ?? false {
                delegate?.terminalView(self, openRemoteFile: path, line: line, column: column)
            } else {
                delegate?.terminalView(self, openFile: path, line: line, column: column)
            }
        }
        return true
    }

    // MARK: Menus and accessibility

    @objc public func copy(_ sender: Any?) { perform(.copy) }
    @objc public func paste(_ sender: Any?) { perform(.paste) }
    @objc public override func selectAll(_ sender: Any?) { perform(.selectAll) }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return selection != nil
        case #selector(paste(_:)): return host?.isLive ?? false
        case #selector(selectAll(_:)): return grid != nil
        default: return true
        }
    }

    public override func accessibilityValue() -> Any? {
        grid?.screenText(lines: Int(layout.viewport.rows))
    }

    private static func union(_ lhs: TerminalSelection, _ rhs: TerminalSelection) -> TerminalSelection {
        if rhs.start < lhs.start {
            return TerminalSelection(anchor: lhs.end, head: rhs.start)
        }
        return TerminalSelection(anchor: lhs.start, head: max(lhs.end, rhs.end))
    }
}

/// What identifies a grid's images and placements without comparing pixels.
private struct GraphicsIdentity: Equatable {
    var images: [UInt64]
    var placements: [GraphicPlacement]

    init(_ graphics: Graphics) {
        images = graphics.images.map { UInt64($0.id) << 32 ^ $0.generation }
        placements = graphics.placements
    }
}
