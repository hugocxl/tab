import AppKit
import TabProtocol

/// A file sent with a message, drawn like the composer's chip: an icon box, the name,
/// its kind and size, and a download button. A click previews it.
@MainActor
final class AgentFileAttachmentCard: ThemedView {
    static let size = NSSize(width: 256, height: 52)
    let preview = PillButton("", style: .plain)
    let download = PillButton("", style: .plain)
    private let iconBackground = ThemedBackground(color: { AgentMediaStyle.iconFill($0) })
    private let icon = NSImageView()
    private let name = makeLabel("", font: AppFont.system(14, weight: .medium))
    private let detail = makeLabel("", font: AppFont.system(12))
    private(set) var attachment: AgentChatAttachmentDescriptor?
    var onOpen: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        iconBackground.cornerRadius = 8
        name.lineBreakMode = .byTruncatingMiddle
        detail.lineBreakMode = .byTruncatingTail
        for child in [iconBackground, icon, name, detail, preview, download] { child.translatesAutoresizingMaskIntoConstraints = true; addSubview(child) }
        preview.onPress = { [weak self] in self?.onOpen?(false) }
        download.onPress = { [weak self] in self?.onOpen?(true) }
        download.imagePosition = .imageOnly
        // Preserve the former explicit 12pt symbol's height without a second inset.
        download.image = AppIcon.download.image(size: 12, scale: 1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ attachment: AgentChatAttachmentDescriptor, theme: AppTheme) {
        self.attachment = attachment; self.theme = theme
        name.stringValue = attachment.name
        detail.stringValue = Self.detail(name: attachment.name, byteCount: attachment.byteCount)
        preview.setAccessibilityLabel("Preview " + attachment.name)
        preview.toolTip = "Preview " + attachment.name
        download.setAccessibilityLabel("Download " + attachment.name)
        download.toolTip = "Download " + attachment.name
        themeDidChange(); needsLayout = true
    }
    /// The kind and size under a file's name, such as "PDF · 46.9 KB".
    static func detail(name: String, byteCount: Int) -> String {
        let suffix = name.range(of: #"\.[a-z0-9]{1,8}$"#, options: [.regularExpression, .caseInsensitive])
        let kind = suffix.map { String(name[$0].dropFirst()).uppercased() } ?? "File"
        return "\(kind) · \(formatBytes(byteCount))"
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
        AgentMediaStyle.applyCard(to: self, theme: theme)
        iconBackground.theme = theme
        // source user-message cards resolve the filename only (without the optional MIME fallback).
        icon.image = attachment.flatMap { FileIcon.image(for: $0.name, dark: !theme.palette.isLight, size: 16) }
        icon.setAccessibilityElement(false)
        name.textColor = theme.fg; detail.textColor = theme.fgMuted
        download.contentTintColor = theme.fgMuted
    }
    override func layout() {
        super.layout()
        let box = AgentMediaStyle.iconBox
        iconBackground.frame = NSRect(x: 8, y: (bounds.height - box) / 2, width: box, height: box)
        icon.frame = NSRect(x: 8 + (box - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let textX = 8 + box + 12
        name.frame = NSRect(x: textX, y: bounds.midY - 18, width: max(1, bounds.width - textX - 32), height: 20)
        detail.frame = NSRect(x: textX, y: bounds.midY + 2, width: name.frame.width, height: 16)
        preview.frame = NSRect(x: 0, y: 0, width: max(1, bounds.width - 30), height: bounds.height)
        download.frame = NSRect(x: max(0, bounds.width - 30), y: (bounds.height - 24) / 2, width: 24, height: 24)
    }
}
