import AppKit

/// A nonblocking multiline editor. Cancelling never mutates the underlying draft.
@MainActor
final class AgentTextEditorSheet {
    let alert = NSAlert()
    let editor = NSTextView()
    let settings = NSButton(checkboxWithTitle: "Use current model, reasoning effort and plan mode", target: nil, action: nil)

    init(title: String, detail: String, text: String, theme: AppTheme, showsSettings: Bool = false, allowsDelete: Bool = false) {
        alert.messageText = title
        alert.informativeText = detail
        alert.window.appearance = theme.nsAppearance
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: showsSettings ? 230 : 194))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: showsSettings ? 36 : 0, width: 440, height: 194))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        editor.isRichText = false
        editor.font = AppFont.body
        editor.textColor = theme.fg
        editor.backgroundColor = theme.card
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.frame = NSRect(x: 0, y: 0, width: 438, height: 192)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.string = text
        editor.setAccessibilityLabel(title)
        scroll.documentView = editor
        content.addSubview(scroll)
        if showsSettings {
            settings.frame = NSRect(x: 0, y: 0, width: 440, height: 28)
            content.addSubview(settings)
        }
        alert.accessoryView = content
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if allowsDelete { alert.addButton(withTitle: "Delete") }
    }

    func present(in window: NSWindow, completion: @escaping (NSApplication.ModalResponse, String, Bool) -> Void) {
        alert.beginSheetModal(for: window) { [self] response in
            completion(response, editor.string, settings.state == .on)
        }
        alert.window.makeFirstResponder(editor)
    }

    func close() {
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
    }
}
