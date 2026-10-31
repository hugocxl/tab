import AppKit

/// Native copy fixtures exercise the real responder action without replacing the user's clipboard.
@MainActor
func preserveAgentTestClipboard() -> () -> Void {
    let original = NSPasteboard.general.pasteboardItems?.map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    } ?? []
    return {
        let items = original.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items)
    }
}
