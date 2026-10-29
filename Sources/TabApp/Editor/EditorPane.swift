import AppKit
import TabCore
import TabProtocol

/// What an editor pane needs from the app.
@MainActor
public protocol EditorHost: NativeHost {
    /// The monospaced font from the terminal settings; see `NativeStyle.codeFont`.
    var codeFont: NSFont { get }
    /// The pane's title changed, such as gaining or losing the unsaved marker.
    func editorTitleDidChange(_ title: String, dirty: Bool)
    /// Makes the side connection watch the project's folder, so
    /// `filesChanged(_:)` hears when the file changes on disk.
    func watchProjectFiles()
}

/// A pane editing one project file: line numbers, the code font, syntax
/// highlighting, Cmd+S to save, Cmd+F to find, and care for changes on
/// disk. One controller per project and path; look an open one up with
/// `existing(project:path:)` to reuse its pane.
@MainActor
public final class EditorPaneController: NSViewController, NSTextViewDelegate, NSTextStorageDelegate {
    public weak var host: EditorHost?
    public let path: String
    /// Whether the text differs from what was last read or written.
    public private(set) var isDirty = false
    /// The text on disk while it differs from the editor's unsaved text.
    public private(set) var diskText: String?
    /// Called when `paneTitle` changes.
    public var onTitleChange: (() -> Void)?

    private enum State {
        case loading
        case ready
        case message(String)
    }

    private var state = State.loading
    private var requested = false
    private var saved: String?
    private var pendingJump: (line: Int, column: Int)?
    private var highlighter: SyntaxHighlighter
    private var pendingEdits: [(range: NSRange, delta: Int)] = []
    private var indent = 4
    private var wrapsLines = false

    private let background = ThemedBackground(color: { $0.card })
    private let banner = DiskChangeBanner()
    private let message = NativeMessageView("Loading…")
    private let scroll = NSScrollView()
    let textView = EditorTextView()
    private var ruler: LineNumberRuler?

    private static let open = NSMapTable<NSString, EditorPaneController>.strongToWeakObjects()

    public init(host: EditorHost, path: String) {
        self.host = host
        self.path = path
        highlighter = SyntaxHighlighter(language: SyntaxLanguage.detect(fileName: path))
        super.init(nibName: nil, bundle: nil)
        Self.open.setObject(self, forKey: Self.key(project: host.nativeProject.id, path: path))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func key(project: ProjectId, path: String) -> NSString {
        "\(project.uuid.uuidString)\u{0}\(path)" as NSString
    }

    /// The open editor for this file, to reuse instead of opening another.
    public static func existing(project: ProjectId, path: String) -> EditorPaneController? {
        open.object(forKey: key(project: project, path: path))
    }

    /// The pane's title, marked while there are unsaved changes.
    public var paneTitle: String { EditorModel.title(path: path, dirty: isDirty) }

    /// The editor's text.
    public var text: String { textView.string }

    public override func loadView() {
        let theme = host?.theme ?? .shared
        background.theme = theme
        view = background
        banner.theme = theme
        banner.isHidden = true
        banner.onReload = { [weak self] in self?.resolveDiskChange(reload: true) }
        banner.onKeep = { [weak self] in self?.resolveDiskChange(reload: false) }
        message.theme = theme

        textView.controller = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.setAccessibilityLabel(NativePath.basename(path))
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let ruler = LineNumberRuler(textView: textView)
        ruler.theme = theme
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        self.ruler = ruler
        applyWrapping()

        let stack = NSStackView(views: [banner, message, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            banner.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        message.setContentHuggingPriority(.defaultLow, for: .vertical)
        themeDidChange()
        render()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        host?.watchProjectFiles()
        if case .loading = state, !requested { load() }
    }

    /// Puts the keyboard in the text.
    public func focus() {
        guard case .ready = state else { return }
        view.window?.makeFirstResponder(textView)
    }

    // MARK: Events from the app

    /// Files changed on the project's server.
    public func filesChanged(_ changes: FileChanges) {
        guard changes.rescan || changes.paths.contains(where: { $0.rawValue == path }) else { return }
        checkDisk()
    }

    /// The side connection opened again: loads the file if it could not be read.
    public func reconnected() {
        if case .loading = state, !requested { load() }
    }

    public func themeDidChange() {
        let theme = background.theme
        textView.insertionPointColor = theme.fg
        textView.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.35)]
        ruler?.needsDisplay = true
        codeFontDidChange()
    }

    /// The terminal font changed.
    public func codeFontDidChange() {
        let font = host?.codeFont ?? AppFont.mono(12)
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: background.theme.syntaxColors.foreground.nsColor]
        ruler?.font = font
        highlightAll()
    }

    /// Wraps long lines at the pane's width instead of scrolling sideways.
    public func setWrapsLines(_ wraps: Bool) {
        wrapsLines = wraps
        applyWrapping()
    }

    private func applyWrapping() {
        guard let container = textView.textContainer else { return }
        textView.isHorizontallyResizable = !wrapsLines
        scroll.hasHorizontalScroller = !wrapsLines
        container.widthTracksTextView = wrapsLines
        if wrapsLines {
            container.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: textView.frame.height))
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }

    var isWrappingLines: Bool { wrapsLines }

    // MARK: Loading and saving

    private func load() {
        guard let host, let transport = host.nativeTransport else { return }
        requested = true
        let request = FilesRequest(project: host.nativeProject.id, action: .read(ServerPath(path)))
        Task { [weak self] in
            do {
                let reply = try await transport.files(request)
                self?.loaded(reply)
            } catch {
                self?.loadFailed(NativeErrors.describe(error))
            }
        }
    }

    func loaded(_ reply: FilesReply) {
        requested = false
        switch EditorModel.loaded(reply) {
        case .text(let text):
            saved = text
            indent = EditorModel.indentWidth(text)
            highlighter = SyntaxHighlighter(language: SyntaxLanguage.detect(
                fileName: path, firstLine: String(text.prefix { $0 != "\n" })
            ))
            state = .ready
            setText(text)
            setDirty(false)
            render()
            if let jump = pendingJump {
                pendingJump = nil
                go(line: jump.line, column: jump.column)
            }
        case .message(let text):
            state = .message(text)
            render()
        case nil:
            break
        }
    }

    private func loadFailed(_ error: String) {
        requested = false
        guard case .loading = state else { return }
        state = .message(EditorModel.loadFailure(error))
        render()
    }

    /// Writes the text to the file; `completion` hears whether it was saved.
    public func save(completion: ((Bool) -> Void)? = nil) {
        guard case .ready = state, let host else {
            completion?(false)
            return
        }
        guard let transport = host.nativeTransport else {
            host.showToast("Could not save \(path): the project's server isn't connected.", style: .error)
            completion?(false)
            return
        }
        let text = textView.string
        let request = FilesRequest(project: host.nativeProject.id, action: .write(path: ServerPath(path), content: text))
        Task { [weak self] in
            do {
                _ = try await transport.files(request)
                guard let self else { return }
                self.saved = text
                self.diskText = nil
                self.banner.isHidden = true
                if self.textView.string == text { self.setDirty(false) }
                completion?(true)
            } catch {
                self?.host?.showToast("Could not save \(self?.path ?? ""): \(NativeErrors.describe(error))", style: .error)
                completion?(false)
            }
        }
    }

    /// Reads the file again after it changed on disk: takes it when there
    /// are no unsaved changes, else offers it.
    private func checkDisk() {
        guard case .ready = state else {
            if case .loading = state, !requested { load() }
            return
        }
        guard let host, let transport = host.nativeTransport else { return }
        let request = FilesRequest(project: host.nativeProject.id, action: .read(ServerPath(path)))
        Task { [weak self] in
            guard let reply = try? await transport.files(request), case .content(let file) = reply else { return }
            self?.diskChanged(file.content)
        }
    }

    func diskChanged(_ disk: String) {
        switch EditorModel.diskChange(saved: saved, disk: disk, dirty: isDirty) {
        case .ignore:
            return
        case .offer:
            diskText = disk
            banner.isHidden = false
        case .reload:
            saved = disk
            diskText = nil
            banner.isHidden = true
            if textView.string != disk { setText(disk) }
        }
    }

    /// Answers the changed-on-disk banner: take the disk's text, or keep yours.
    public func resolveDiskChange(reload: Bool) {
        guard let disk = diskText else { return }
        diskText = nil
        banner.isHidden = true
        guard reload else { return }
        saved = disk
        setText(disk)
        setDirty(false)
    }

    /// Asks whether to save unsaved changes before the pane closes;
    /// `completion` hears whether it may close.
    public func willClose(completion: @escaping (Bool) -> Void) {
        Self.confirmClose([self], window: view.window, completion: completion)
    }

    /// Asks once whether to save `editors`' unsaved changes, as closing
    /// several panes or quitting does; `completion` hears whether to go on.
    public static func confirmClose(_ editors: [EditorPaneController], window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let dirty = editors.filter(\.isDirty)
        guard !dirty.isEmpty else {
            completion(true)
            return
        }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Save changes to “\(NativePath.basename(dirty[0].path))”?"
            : "Save changes to \(dirty.count) files?"
        alert.informativeText = "Your changes are lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.appearance = (dirty.first?.host?.theme ?? .shared).nsAppearance
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: saveAll(dirty, completion: completion)
            case .alertSecondButtonReturn: completion(true)
            default: completion(false)
            }
        }
        guard let window else {
            answer(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: answer)
    }

    private static func saveAll(_ editors: [EditorPaneController], completion: @escaping (Bool) -> Void) {
        var remaining = editors.count
        var failed = false
        for editor in editors {
            editor.save { saved in
                failed = failed || !saved
                remaining -= 1
                if remaining == 0 { completion(!failed) }
            }
        }
    }

    // MARK: Navigation

    /// Puts the caret at a one-based line and column, centered in the pane.
    public func go(line: Int, column: Int) {
        guard case .ready = state else {
            pendingJump = (line, column)
            return
        }
        let offset = EditorModel.offset(line: line, column: column, in: textView.string)
        let range = NSRange(location: offset, length: 0)
        textView.setSelectedRange(range)
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(forCharacterRange: NSRange(location: offset, length: 0))
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let visible = scroll.contentView.bounds
        let maximum = max(textView.frame.height - visible.height, 0)
        let y = min(max(rect.midY + textView.textContainerOrigin.y - visible.height / 2, 0), maximum)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        focus()
    }

    // MARK: Editing

    private func setText(_ text: String) {
        pendingEdits.removeAll()
        textView.string = text
        textView.undoManager?.removeAllActions()
        ruler?.textDidChange()
        highlightAll()
    }

    private func highlightAll() {
        guard let storage = textView.textStorage, case .ready = state else { return }
        highlighter.setText(storage.string)
        highlighter.apply(to: storage, in: NSRange(location: 0, length: storage.length),
                          colors: background.theme.syntaxColors, font: textView.font ?? AppFont.mono(12))
    }

    private func setDirty(_ dirty: Bool) {
        guard dirty != isDirty else { return }
        isDirty = dirty
        host?.editorTitleDidChange(paneTitle, dirty: dirty)
        onTitleChange?()
    }

    public nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                        range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { pendingEdits.append((editedRange, delta)) }
    }

    public func textDidChange(_ notification: Notification) {
        guard let storage = textView.textStorage else { return }
        let font = textView.font ?? AppFont.mono(12)
        let colors = background.theme.syntaxColors
        if pendingEdits.count == 1, let edit = pendingEdits.first {
            let changed = highlighter.update(storage.string, editedRange: edit.range, changeInLength: edit.delta)
            highlighter.apply(to: storage, in: changed, colors: colors, font: font)
        } else {
            highlightAll()
        }
        pendingEdits.removeAll()
        ruler?.textDidChange()
        setDirty(computeDirty())
    }

    private func computeDirty() -> Bool {
        guard let saved else { return true }
        let current = textView.string
        if current.utf16.count != saved.utf16.count { return true }
        return current != saved
    }

    /// Text for Return: the line break with this line's indentation.
    func newlineText() -> String {
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let prefix = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        return EditorModel.newline(after: prefix, indent: indent)
    }

    /// Text for Tab: spaces to the next indent stop.
    func tabText() -> String {
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let column = text.substring(with: NSRange(location: lineStart, length: caret - lineStart)).count
        return EditorModel.tabSpaces(column: column, indent: indent)
    }

    private func render() {
        guard isViewLoaded else { return }
        switch state {
        case .loading:
            message.set("Loading…")
            message.isHidden = false
            scroll.isHidden = true
        case .message(let text):
            message.set(text)
            message.isHidden = false
            scroll.isHidden = true
        case .ready:
            message.isHidden = true
            scroll.isHidden = false
        }
        banner.isHidden = diskText == nil
    }
}

/// The editor's text view: Tab and Return indent, Cmd+S saves, Cmd+F finds.
final class EditorTextView: NSTextView {
    weak var controller: EditorPaneController?

    override func insertTab(_ sender: Any?) {
        guard let controller else { return super.insertTab(sender) }
        insertText(controller.tabText(), replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        guard let controller else { return super.insertNewline(sender) }
        insertText(controller.newlineText(), replacementRange: selectedRange())
    }

    @objc func saveDocument(_ sender: Any?) {
        controller?.save()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (flags, key) {
        case (.command, "s"):
            controller?.save()
            return true
        case (.command, "f"):
            find(.showFindInterface)
            return true
        case (.command, "g"):
            find(.nextMatch)
            return true
        case ([.command, .shift], "g"):
            find(.previousMatch)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(saveDocument(_:)) { return controller != nil }
        if item.action == #selector(toggleWrapping(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    @objc func toggleWrapping(_ sender: Any?) {
        guard let controller else { return }
        controller.setWrapsLines(!controller.isWrappingLines)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let wrap = NSMenuItem(title: "Wrap Lines", action: #selector(toggleWrapping(_:)), keyEquivalent: "")
        wrap.target = self
        wrap.state = controller?.isWrappingLines == true ? .on : .off
        menu.addItem(.separator())
        menu.addItem(wrap)
        return menu
    }
}

/// The line number gutter beside the editor's text.
final class LineNumberRuler: NSRulerView {
    var theme: AppTheme = .shared
    var font: NSFont = AppFont.mono(12) {
        didSet { updateThickness() }
    }
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        updateThickness()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var textView: NSTextView? { clientView as? NSTextView }

    /// Recounts lines after an edit.
    func textDidChange() {
        guard let string = textView?.string else { return }
        var starts = [0]
        var offset = 0
        for unit in string.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        let digitsChanged = String(starts.count).count != String(lineStarts.count).count
        lineStarts = starts
        if digitsChanged { updateThickness() }
        needsDisplay = true
    }

    private func updateThickness() {
        let digits = max(String(lineStarts.count).count, 3)
        let width = (String(repeating: "8", count: digits) as NSString).size(withAttributes: [.font: font]).width
        ruleThickness = (width + 16).rounded(.up)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        theme.card.setFill()
        bounds.fill()
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caret = textView.selectedRange().location
        var line = lineIndex(containing: characters.location)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.fgDim]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.fgMuted]
        let caretLine = lineIndex(containing: caret)
        let origin = convert(NSPoint.zero, from: textView)
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters) {
            let start = lineStarts[line]
            let length = (textView.string as NSString).length
            var fragment: NSRect
            if start >= length && length > 0 {
                fragment = layout.extraLineFragmentRect
                if fragment.isEmpty { break }
            } else {
                let glyph = layout.glyphIndexForCharacter(at: min(start, max(length - 1, 0)))
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            }
            let label = String(line + 1) as NSString
            let size = label.size(withAttributes: attributes)
            let y = fragment.minY + textView.textContainerOrigin.y + origin.y + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y),
                       withAttributes: line == caretLine ? current : attributes)
            line += 1
        }
    }

    private func lineIndex(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

/// "Changed on disk" with Reload and Keep mine, above an editor whose file
/// changed while it had unsaved changes.
final class DiskChangeBanner: ThemedView {
    private let label = makeLabel("Changed on disk", font: AppFont.footnote)
    private let reload = TextGlyphButton("Reload", tooltip: "Take the version on disk", font: AppFont.footnote)
    private let keep = TextGlyphButton("Keep mine", tooltip: "Keep your unsaved changes", font: AppFont.footnote)
    var onReload: (() -> Void)?
    var onKeep: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        reload.action = { [weak self] in self?.onReload?() }
        keep.action = { [weak self] in self?.onKeep?() }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [label, reload, keep])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Metrics.controlGap
        addSubview(stack)
        stack.pinEdges(to: self, insets: NSEdgeInsets(top: 4, left: Metrics.gutter, bottom: 4, right: Metrics.gutter))
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.surface.cgColor
    }

    override func themeDidChange() {
        label.textColor = theme.fg
        needsDisplay = true
    }
}
