import AppKit
import PDFKit
import TabProtocol

struct AgentFilePreviewPayload: @unchecked Sendable {
    var text: String?
    var pdf: PDFDocument?
    var truncated = false
    static let textLimit = 1024 * 1024

    static func decode(_ data: Data, attachment: AgentChatAttachmentDescriptor) -> Self {
        if attachment.mimeType == "application/pdf" || (attachment.name as NSString).pathExtension.lowercased() == "pdf" {
            return Self(pdf: PDFDocument(data: data))
        }
        let prefix = data.prefix(textLimit)
        guard !prefix.contains(0) else { return Self() }
        // Like the source renderer's bounded TextDecoder preview, a cut UTF-8 sequence remains visible as a replacement character.
        let text = String(decoding: prefix, as: UTF8.self)
        let replacementCount = text.unicodeScalars.filter { $0.value == 0xfffd }.count
        guard replacementCount < max(4, text.count / 100) else { return Self() }
        return Self(text: text, truncated: data.count > textLimit)
    }
}

@MainActor
final class AgentFilePreviewWindow: NSWindowController, NSWindowDelegate {
    let content = AgentFilePreviewView(frame: .zero)
    private let item: String
    private let attachment: AgentChatAttachmentDescriptor
    private let fetch: AgentAttachmentCache.Fetch
    private var task: Task<Void, Never>?
    private var generation = 0
    private var data: Data?

    init(item: String, attachment: AgentChatAttachmentDescriptor, fetch: @escaping AgentAttachmentCache.Fetch, theme: AppTheme) {
        self.item = item; self.attachment = attachment; self.fetch = fetch
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = attachment.name; window.isReleasedWhenClosed = false
        super.init(window: window)
        content.theme = theme; content.themeDidChange()
        window.contentView = content; window.delegate = self
        window.minSize = NSSize(width: 360, height: 240); window.center()
        content.retry.onPress = { [weak self] in self?.load() }
        content.save.onPress = { [weak self] in
            guard let self, let data = self.data else { return }
            Self.save(data, name: self.attachment.name, window: self.window) { [weak self] error in self?.content.notice.stringValue = error.localizedDescription }
        }
        content.copy.onPress = { [weak self] in
            guard let self, let data = self.data else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
        }
        load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { task?.cancel() }
    func windowWillClose(_ notification: Notification) { task?.cancel(); generation += 1; data = nil; content.pdf.document = nil }
    private func load() {
        task?.cancel(); generation += 1
        let token = generation, fetch = fetch, item = item, attachment = attachment
        content.setLoading()
        task = Task { [weak self] in
            do {
                let data = try await fetch(item, attachment)
                let worker = Task.detached(priority: .userInitiated) { AgentFilePreviewPayload.decode(data, attachment: attachment) }
                let payload = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.data = data
                self.content.show(payload, attachment: attachment)
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.content.notice.stringValue = error.localizedDescription
                self.content.retry.isHidden = false
            }
        }
    }
    static func save(_ data: Data, name: String, window: NSWindow?, failure: @escaping (Error) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (name as NSString).lastPathComponent
        let completion: (NSApplication.ModalResponse) -> Void = { result in
            guard result == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) } catch { failure(error) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

@MainActor
final class AgentFilePreviewView: ThemedView {
    let pdf = PDFView()
    let scroll = NSScrollView()
    let text = AgentRichTextView(frame: .zero)
    let markdown = AgentResponseView(frame: .zero)
    let notice = makeLabel("", font: AppFont.small)
    let save = PillButton("Save…", style: .plain)
    let copy = PillButton("Copy contents", style: .plain)
    let wrap = PillButton("Disable line wrap", style: .plain)
    let rendered = PillButton("Show source", style: .plain)
    let retry = PillButton("Retry", style: .normal)
    private var unwrappedWidth: CGFloat?
    private var source: String?
    private var markdownEnabled = false
    private var wrapped = true
    private var showingMarkdown = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        pdf.autoScales = true; pdf.displayMode = .singlePageContinuous
        notice.lineBreakMode = .byTruncatingMiddle
        for child in [pdf, scroll, notice, save, copy, wrap, rendered, retry] { child.translatesAutoresizingMaskIntoConstraints = true; addSubview(child) }
        wrap.onPress = { [weak self] in
            guard let self else { return }; self.wrapped.toggle()
            self.wrap.title = self.wrapped ? "Disable line wrap" : "Wrap lines"; self.needsLayout = true
        }
        rendered.onPress = { [weak self] in self?.showingMarkdown.toggle(); self?.updateMode() }
        markdown.onHeightChanged = { [weak self] in self?.needsLayout = true; self?.layoutSubtreeIfNeeded() }
        setLoading()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func setLoading() {
        source = nil; pdf.document = nil; pdf.isHidden = true; scroll.isHidden = true
        notice.stringValue = "Loading attachment…"
        save.isEnabled = false; copy.isEnabled = false; wrap.isHidden = true; rendered.isHidden = true; retry.isHidden = true
    }
    func show(_ payload: AgentFilePreviewPayload, attachment: AgentChatAttachmentDescriptor) {
        save.isEnabled = true; retry.isHidden = true
        if let document = payload.pdf {
            pdf.document = document; pdf.isHidden = false; notice.stringValue = ""; needsLayout = true; return
        }
        guard let source = payload.text else {
            notice.stringValue = "No preview is available for \(attachment.name). Save the file to open it in another app."
            return
        }
        self.source = source
        unwrappedWidth = nil
        copy.isEnabled = true; scroll.isHidden = false
        markdownEnabled = ["md", "markdown", "mdx"].contains((attachment.name as NSString).pathExtension.lowercased()) || attachment.mimeType == "text/markdown"
        showingMarkdown = markdownEnabled
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
        text.setContent(NSAttributedString(string: source, attributes: [.font: AppFont.mono(12), .foregroundColor: theme.fg, .paragraphStyle: paragraph]))
        if markdownEnabled { markdown.setContent(source, theme: theme) }
        notice.stringValue = payload.truncated ? "Preview limited to 1 MiB. Copy or save to get the complete file." : ""
        updateMode()
    }
    private func updateMode() {
        rendered.isHidden = !markdownEnabled
        rendered.title = showingMarkdown ? "Show source" : "Show rendered Markdown"
        wrap.isHidden = showingMarkdown || source == nil
        scroll.documentView = showingMarkdown ? markdown : text
        needsLayout = true
    }
    override func themeDidChange() {
        wantsLayer = true; layer?.backgroundColor = theme.card.cgColor
        notice.textColor = theme.fgMuted
        for button in [save, copy, wrap, rendered] { button.setTitleColor(theme.fgMuted) }
        pdf.backgroundColor = theme.card
        if let source {
            text.textStorage?.addAttribute(.foregroundColor, value: theme.fg,
                                           range: NSRange(location: 0, length: text.string.utf16.count))
            if markdownEnabled { markdown.setContent(source, theme: theme) }
        }
    }
    override func layout() {
        super.layout()
        save.frame = NSRect(x: bounds.width - 74, y: 8, width: 62, height: 26)
        copy.frame = NSRect(x: bounds.width - 190, y: 8, width: 110, height: 26)
        rendered.frame = NSRect(x: 12, y: 8, width: min(176, max(1, bounds.width - 208)), height: 26)
        wrap.frame = NSRect(x: 12, y: 8, width: 130, height: 26)
        if !rendered.isHidden && !wrap.isHidden { wrap.frame.origin = NSPoint(x: 12, y: 38) }
        let top: CGFloat = !rendered.isHidden && !wrap.isHidden ? 72 : 44
        let bottom: CGFloat = notice.stringValue.isEmpty ? 12 : 38
        let rect = NSRect(x: 12, y: top, width: max(1, bounds.width - 24), height: max(1, bounds.height - top - bottom))
        scroll.frame = rect; pdf.frame = rect
        notice.frame = NSRect(x: 12, y: bounds.height - 30, width: max(1, bounds.width - 24), height: 22)
        retry.frame = NSRect(x: bounds.midX - 35, y: bounds.midY - 14, width: 70, height: 28)
        if showingMarkdown {
            markdown.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: markdown.height(for: scroll.contentSize.width))
            markdown.layoutSubtreeIfNeeded()
        } else if let source {
            if !wrapped && unwrappedWidth == nil {
                unwrappedWidth = source.components(separatedBy: "\n").map { ($0 as NSString).size(withAttributes: [.font: AppFont.mono(12)]).width + 8 }.max() ?? 0
            }
            let width = wrapped ? scroll.contentSize.width : max(scroll.contentSize.width, unwrappedWidth ?? 0)
            text.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, text.height(for: width)))
        }
    }
}
