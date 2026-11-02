import AppKit
import TabProtocol

@MainActor
final class AgentFileAttachmentCard: ThemedView {
    let preview = PillButton("", style: .plain)
    let download = PillButton("", style: .plain)
    private let iconBackground = ThemedBackground(color: { $0.card.withAlphaComponent(0.6) })
    private let icon = NSImageView()
    private let name = makeLabel("", font: AppFont.system(14, weight: .medium))
    private let detail = makeLabel("", font: AppFont.system(12))
    private(set) var standalone = false
    private(set) var attachment: AgentChatAttachmentDescriptor?
    var onOpen: ((Bool) -> Void)?
    var preferredHeight: CGFloat { standalone ? 52 : 32 }
    var naturalWidth: CGFloat { standalone ? 256 : min(420, (name.stringValue as NSString).size(withAttributes: [.font: AppFont.system(14)]).width + 56) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        iconBackground.cornerRadius = 8
        name.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        for child in [iconBackground, icon, name, detail, preview, download] { child.translatesAutoresizingMaskIntoConstraints = true; addSubview(child) }
        preview.onPress = { [weak self] in self?.onOpen?(false) }
        download.onPress = { [weak self] in self?.onOpen?(true) }
        download.imagePosition = .imageOnly
        download.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ attachment: AgentChatAttachmentDescriptor, standalone: Bool, theme: AppTheme) {
        self.attachment = attachment; self.standalone = standalone; self.theme = theme
        name.stringValue = attachment.name
        name.font = AppFont.system(14, weight: standalone ? .medium : .regular)
        let suffix = attachment.name.range(of: #"\.[a-z0-9]{1,8}$"#, options: [.regularExpression, .caseInsensitive])
        let kind = suffix.map { String(attachment.name[$0].dropFirst()).uppercased() } ?? "File"
        detail.stringValue = "\(kind) · \(Self.formatBytes(attachment.byteCount))"
        detail.isHidden = !standalone; iconBackground.isHidden = !standalone
        preview.setAccessibilityLabel("Preview " + attachment.name)
        preview.toolTip = "Preview " + attachment.name
        download.setAccessibilityLabel("Download " + attachment.name)
        download.toolTip = "Download " + attachment.name
        themeDidChange(); needsLayout = true
    }
    static func formatBytes(_ bytes: Int) -> String {
        guard bytes >= 1024 else { return "\(bytes) B" }
        func scaled(_ value: Double) -> String {
            let digits = value >= 100 ? 0 : value >= 10 ? 1 : 2
            let scale = pow(10.0, Double(digits))
            let rounded = (value * scale).rounded(.toNearestOrAwayFromZero) / scale
            return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, rounded)
        }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024, unit = 0
        while (Double(scaled(value)) ?? value) >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        return scaled(value) + " " + units[unit]
    }

    override func themeDidChange() {
        layer?.backgroundColor = (standalone ? theme.fg.withAlphaComponent(0.055) : .clear).cgColor
        layer?.cornerRadius = standalone ? 16 : 0
        iconBackground.theme = theme
        // source user-message cards resolve the filename only (without the optional MIME fallback).
        icon.image = attachment.flatMap { FileIcon.image(for: $0.name, dark: !theme.palette.isLight, size: 16) }
        icon.setAccessibilityElement(false)
        name.textColor = theme.fg; detail.textColor = theme.fgMuted
        download.contentTintColor = theme.fgMuted
    }
    override func layout() {
        super.layout()
        let left: CGFloat = standalone ? 8 : 0
        let iconSize: CGFloat = standalone ? 36 : 16
        let textX = left + iconSize + (standalone ? 12 : 8)
        iconBackground.frame = NSRect(x: left, y: 8, width: 36, height: 36)
        icon.frame = NSRect(x: left + (standalone ? 10 : 0), y: (bounds.height - 16) / 2, width: 16, height: 16)
        name.frame = NSRect(x: textX, y: standalone ? 8 : 6, width: max(1, bounds.width - textX - 32), height: 20)
        detail.frame = NSRect(x: textX, y: 28, width: name.frame.width, height: 16)
        preview.frame = NSRect(x: 0, y: 0, width: max(1, bounds.width - 30), height: bounds.height)
        download.frame = NSRect(x: max(0, bounds.width - 28), y: (bounds.height - 24) / 2, width: 24, height: 24)
    }
}
