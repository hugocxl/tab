import AppKit
import TabProtocol

@MainActor
final class AgentMediaPreviewWindow: NSWindowController, NSWindowDelegate {
    private let item: String
    private let attachments: [AgentChatAttachmentDescriptor]
    private let fetch: AgentAttachmentCache.Fetch
    let content = AgentMediaPreviewView(frame: .zero)
    private(set) var selectedIndex: Int
    private var task: Task<Void, Never>?
    private var generation = 0
    private weak var presentingWindow: NSWindow?
    private weak var returnFocus: NSResponder?
    private var observers: [NSObjectProtocol] = []
    let imageActions = AgentImageActions(name: "image")

    init(item: String, attachments: [AgentChatAttachmentDescriptor], index: Int, fetch: @escaping AgentAttachmentCache.Fetch, theme: AppTheme) {
        self.item = item; self.attachments = attachments; self.fetch = fetch
        selectedIndex = max(0, min(index, attachments.count - 1))
        let window = AgentMediaWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        super.init(window: window)
        content.theme = theme
        content.themeDidChange()
        window.contentView = content
        imageActions.view = content
        content.image.imageActions = imageActions
        window.delegate = self
        window.minSize = NSSize(width: 360, height: 280)
        window.center()
        content.previous.onPress = { [weak self] in self?.select((self?.selectedIndex ?? 0) - 1) }
        content.next.onPress = { [weak self] in self?.select((self?.selectedIndex ?? 0) + 1) }
        content.onClose = { [weak self] in self?.close() }
        content.onKey = { [weak self] key in
            if self?.content.scroll.pan(key: key) == true { return true }
            switch key { case 53: self?.close(); case 123: self?.select((self?.selectedIndex ?? 0) - 1)
            case 124: self?.select((self?.selectedIndex ?? 0) + 1); default: return false }
            return true
        }
        window.onKey = content.onKey
        load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { task?.cancel(); observers.forEach { NotificationCenter.default.removeObserver($0) } }
    func present(in parent: NSWindow?) {
        guard let parent, let window else { showWindow(nil); return }
        presentingWindow = parent; returnFocus = parent.firstResponder
        alignWithParent()
        parent.addChildWindow(window, ordered: .above)
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.alignWithParent() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content.closeButton)
    }
    private func alignWithParent() {
        guard let parent = presentingWindow else { return }
        window?.setFrame(parent.convertToScreen(parent.contentLayoutRect), display: true)
    }
    func windowWillClose(_ notification: Notification) {
        task?.cancel(); imageActions.cancel(); generation += 1; content.image.animates = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        if let parent = presentingWindow, let window {
            parent.removeChildWindow(window)
            parent.makeKey()
            if let view = returnFocus as? NSView, view.window === parent { parent.makeFirstResponder(view) }
        }
        presentingWindow = nil; returnFocus = nil
    }
    func select(_ index: Int) {
        guard !attachments.isEmpty else { return }
        let wrapped = ((index % attachments.count) + attachments.count) % attachments.count
        guard wrapped != selectedIndex else { return }
        selectedIndex = wrapped
        load()
    }
    private func load() {
        guard attachments.indices.contains(selectedIndex) else { return }
        generation += 1
        let token = generation, attachment = attachments[selectedIndex], item = item, fetch = fetch
        task?.cancel()
        imageActions.cancel()
        imageActions.fetch = { try await fetch(item, attachment) }
        imageActions.name = attachment.name
        imageActions.mimeType = attachment.mimeType
        window?.title = attachment.name
        content.scroll.setAccessibilityLabel(attachment.name + ", zoomable image")
        content.caption.stringValue = attachment.name + (attachments.count > 1 ? " (\(selectedIndex + 1)/\(attachments.count))" : "")
        content.previous.isHidden = attachments.count <= 1
        content.next.isHidden = attachments.count <= 1
        content.image.image = nil
        content.scroll.reset()
        content.status.stringValue = ""
        content.setLoaded(false)
        task = Task { [weak self] in
            do {
                let data = try await fetch(item, attachment)
                guard let image = await AgentAttachmentImporter.previewImage(data: data, pixels: 4096) else { throw ModelError("This image could not be decoded.") }
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.imageActions.fetch = { data }
                self.content.image.image = image
                self.content.image.animates = true
                self.content.image.setAccessibilityLabel(attachment.name)
                self.content.status.stringValue = ""
                self.content.setLoaded(true)
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.content.showFailure()
            }
        }
    }

}

@MainActor
final class AgentMediaPreviewView: ThemedView {
    let scroll = AgentZoomableImage()
    var image: AgentZoomImageView { scroll.image }
    let caption = makeLabel("", font: AppFont.system(12))
    let status = makeLabel("", font: AppFont.system(14))
    let previous = AgentMediaButton(.previous, label: "Previous media")
    let next = AgentMediaButton(.next, label: "Next media")
    let closeButton = AgentMediaButton(.close, label: "Close image preview")
    private let imageShadow = NSView()
    private let failureFrame = NSView()
    private(set) var failed = false
    var onKey: ((UInt16) -> Bool)?
    var onClose: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.onGeometryChanged = { [weak self] in self?.needsLayout = true }
        caption.alignment = .center; caption.lineBreakMode = .byTruncatingTail
        status.alignment = .center; status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 0
        for child in [imageShadow, scroll, failureFrame, status, caption, previous, next, closeButton] {
            child.translatesAutoresizingMaskIntoConstraints = true; addSubview(child)
        }
        for view in [scroll, imageShadow, failureFrame] { view.wantsLayer = true; view.layer?.cornerRadius = 8 }
        scroll.layer?.masksToBounds = true
        failureFrame.layer?.backgroundColor = NSColor.black.cgColor
        closeButton.onPress = { [weak self] in self?.onClose?() }
        setAccessibilityRole(.group); setAccessibilityLabel("Expanded image preview")
        setLoaded(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setLoaded(_ loaded: Bool) {
        failed = false; failureFrame.isHidden = true; status.isHidden = true
        scroll.isHidden = !loaded; imageShadow.isHidden = !loaded
        needsLayout = true
    }
    func showFailure() {
        failed = true; scroll.isHidden = true; imageShadow.isHidden = true
        failureFrame.isHidden = false; status.isHidden = false
        let text = "Image unavailable. The file may have been moved or deleted."
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = 20; paragraph.maximumLineHeight = 20
        status.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: AppFont.system(14), .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ])
        NSAccessibility.post(element: status, notification: .announcementRequested, userInfo: [.announcement: text])
        needsLayout = true
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !scroll.frame.contains(point), !caption.frame.contains(point) { onClose?() }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return scroll.frame.contains(point) || caption.frame.contains(point) ? image.imageActions?.menu() : nil
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109, event.modifierFlags.contains(.shift) {
            image.imageActions?.menu().popUp(positioning: nil, at: NSPoint(x: scroll.frame.minX, y: scroll.frame.maxY), in: self)
        } else if !scroll.handleKey(event), onKey?(event.keyCode) != true { super.keyDown(with: event) }
    }
    override func themeDidChange() {
        wantsLayer = true; layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        caption.textColor = NSColor.white.withAlphaComponent(0.8); status.textColor = .white
        imageShadow.layer?.backgroundColor = theme.bg.cgColor
        scroll.layer?.backgroundColor = theme.bg.cgColor
        let border = theme.border.withAlphaComponent(theme.border.alphaComponent * 0.7).cgColor
        imageShadow.layer?.borderWidth = 1; imageShadow.layer?.borderColor = border
        failureFrame.layer?.borderWidth = 1; failureFrame.layer?.borderColor = border
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !scroll.isHidden || failed else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 50
        shadow.shadowOffset = NSSize(width: 0, height: -25)
        shadow.set()
        theme.bg.setFill()
        NSBezierPath(roundedRect: scroll.frame.insetBy(dx: 12, dy: 12), xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    override func layout() {
        super.layout()
        let narrow = bounds.width < 640
        let maxWidth = max(1, bounds.width * 0.92 - (narrow ? 0 : 96))
        var size = scroll.configure(viewer: bounds.size)
        if failed { size = NSSize(width: min(maxWidth, 512), height: 192) }
        let media = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height - 24) / 2, width: size.width, height: size.height)
        scroll.frame = media; imageShadow.frame = media.insetBy(dx: -1, dy: -1); failureFrame.frame = media
        let captionWidth = max(1, maxWidth - (narrow ? 80 : 0))
        caption.frame = NSRect(x: (bounds.width - captionWidth) / 2, y: media.maxY + 8, width: captionWidth, height: 16)
        let statusWidth = max(1, media.width - 48)
        let statusHeight = status.attributedStringValue.boundingRect(with: NSSize(width: statusWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
        status.frame = NSRect(x: media.minX + 24, y: media.midY - ceil(statusHeight) / 2, width: statusWidth, height: ceil(statusHeight))
        let left = bounds.width * 0.04 + 1, right = bounds.width * 0.96 - 1
        let navigation: CGFloat = narrow ? 36 : 32, close: CGFloat = narrow ? 32 : 28
        let navY = narrow ? bounds.height * 0.96 - 1 - navigation : bounds.midY - navigation / 2
        previous.frame = NSRect(x: left, y: navY, width: navigation, height: navigation)
        next.frame = NSRect(x: right - navigation, y: navY, width: navigation, height: navigation)
        closeButton.frame = NSRect(x: right - close, y: bounds.height * 0.04 + 1, width: close, height: close)
        for button in [previous, next, closeButton] { button.narrow = narrow }
        closeButton.nextKeyView = previous.isHidden ? scroll : previous
        previous.nextKeyView = scroll
        scroll.nextKeyView = next.isHidden ? closeButton : next
        next.nextKeyView = closeButton
        needsDisplay = true
    }
}

@MainActor
private final class AgentMediaWindow: NSWindow {
    var onKey: ((UInt16) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           [53, 123, 124, 125, 126].contains(event.keyCode), onKey?(event.keyCode) == true { return }
        super.sendEvent(event)
    }
}
