import AppKit
import TabCore

/// The 24pt rounded-square tile at the start of a row: a white glyph over
/// a hue gradient, a monogram, theme swatches or an image.
final class PaletteTileView: ThemedView {
    var tile: PaletteTile = .none { didSet { if tile != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let radius = PaletteLayout.tileRadius
        switch tile.glyph {
        case .none:
            return
        case .image(let image):
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        case .swatches(let colors):
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            theme.raised.setFill()
            path.fill()
            theme.border.setStroke()
            path.stroke()
            let cell = (PaletteLayout.tile - 8) / 2
            for (index, color) in colors.prefix(4).enumerated() {
                let x = rect.minX + 3.5 + CGFloat(index % 2) * (cell + 1)
                let y = rect.minY + 3.5 + CGFloat(index / 2) * (cell + 1)
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: cell, height: cell), xRadius: 2, yRadius: 2).fill()
            }
            return
        default:
            break
        }
        let foreground: NSColor
        if let color = background {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            let gradient = NSGradient(starting: lighter(color), ending: color)
            gradient?.draw(in: path, angle: 90)
            NSColor(white: 1, alpha: 0.18).setStroke()
            path.stroke()
            foreground = tile.hue == .accent ? theme.accentForeground : .white
        } else {
            foreground = theme.fgMuted
        }
        switch tile.glyph {
        case .icon(let icon):
            guard let image = icon.image(size: PaletteLayout.tile * 0.6) else { return }
            let frame = NSRect(x: ((rect.width - image.size.width) / 2).rounded(), y: ((rect.height - image.size.height) / 2).rounded(),
                               width: image.size.width, height: image.size.height)
            image.tinted(foreground).draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .monogram(let text):
            let string = NSAttributedString(string: text, attributes: [.font: AppFont.system(12, weight: .semibold), .foregroundColor: foreground])
            let size = string.size()
            string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        default:
            break
        }
    }

    private var background: NSColor? {
        if tile.hue == .accent { return theme.accent }
        guard let (hue, saturation, lightness) = tile.hue.hsl else { return nil }
        return Self.color(hue: hue, saturation: saturation, lightness: lightness)
    }

    private func lighter(_ color: NSColor) -> NSColor {
        guard let (hue, saturation, lightness) = tile.hue.hsl else { return color.blended(withFraction: 0.12, of: .white) ?? color }
        return Self.color(hue: hue, saturation: saturation, lightness: min(lightness + 0.06, 1))
    }

    static func color(hue: Double, saturation: Double, lightness: Double) -> NSColor {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let segment = hue / 60
        let x = chroma * (1 - abs(segment.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch segment {
        case 0..<1: (r, g, b) = (chroma, x, 0)
        case 1..<2: (r, g, b) = (x, chroma, 0)
        case 2..<3: (r, g, b) = (0, chroma, x)
        case 3..<4: (r, g, b) = (0, x, chroma)
        case 4..<5: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        let m = lightness - chroma / 2
        return NSColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: 1)
    }
}

/// Keycaps for a chord: outlined rounded squares with muted symbols.
final class KeycapsView: ThemedView {
    var symbols: [String] = [] { didSet { if symbols != oldValue { needsDisplay = true; invalidateIntrinsicContentSize() } } }

    override var intrinsicContentSize: NSSize {
        guard !symbols.isEmpty else { return .zero }
        let widths = symbols.map { Self.capWidth($0) }
        return NSSize(width: widths.reduce(0, +) + CGFloat(symbols.count - 1) * 4, height: Metrics.keycap)
    }

    static func capWidth(_ symbol: String) -> CGFloat {
        let width = NSAttributedString(string: symbol, attributes: [.font: AppFont.small]).size().width
        return max(Metrics.keycap, ceil(width) + 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for symbol in symbols {
            let width = Self.capWidth(symbol)
            let rect = NSRect(x: x, y: (bounds.height - Metrics.keycap) / 2, width: width, height: Metrics.keycap)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium)
            theme.fg(alpha: 0.03).setFill()
            path.fill()
            theme.fg(alpha: 0.16).setStroke()
            path.stroke()
            let text = NSAttributedString(string: symbol, attributes: [.font: AppFont.small, .foregroundColor: theme.fgMuted])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            x += width + 4
        }
    }

    static func symbols(_ chord: KeyChord?) -> [String] {
        guard let chord else { return [] }
        return KeyCap.symbols(for: chord)
    }
}

/// One palette row: the 40pt item with its tile, title, subtitle and the
/// badge, keycaps, kind and chevron on the right.
final class PaletteItemView: NSView {
    private let tile = PaletteTileView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private let badge = BadgePill()
    private let keycaps = KeycapsView()
    private let kind = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var item: PaletteItem?
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private let theme = AppTheme.shared

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [title, subtitle, kind] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
        }
        subtitle.font = AppFont.system(14)
        kind.font = AppFont.system(13)
        chevron.image = AppIcon.chevronRight.image(size: 12)
        check.image = AppIcon.check.image(size: 12)
        for view in [tile, title, subtitle, check, badge, keycaps, kind, chevron] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(_ item: PaletteItem) {
        self.item = item
        tile.tile = item.tile
        title.attributedStringValue = highlighted(
            item.title, ranges: item.highlights,
            font: AppFont.system(14, weight: item.current ? .semibold : .regular),
            color: item.disabled ? theme.fgDim : theme.fg, accent: theme.accent
        )
        subtitle.stringValue = item.subtitle ?? ""
        subtitle.isHidden = item.subtitle == nil
        subtitle.textColor = theme.fgMuted
        check.isHidden = !item.current
        check.contentTintColor = theme.accent
        badge.text = item.badge
        badge.isHidden = item.badge == nil
        keycaps.symbols = KeycapsView.symbols(item.shortcut)
        kind.stringValue = item.kind ?? ""
        kind.isHidden = item.kind == nil
        kind.textColor = theme.fgMuted
        if case .page = item.target { chevron.isHidden = false } else { chevron.isHidden = true }
        chevron.contentTintColor = theme.fgMuted
        alphaValue = item.disabled ? 0.6 : 1
        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item, selected || (hovered && !item.disabled) else { return }
        let rect = bounds.insetBy(dx: PaletteLayout.rowInset, dy: 0)
        (selected ? theme.selection : theme.hover).setFill()
        NSBezierPath(roundedRect: rect, xRadius: PaletteLayout.rowRadius, yRadius: PaletteLayout.rowRadius).fill()
    }

    override func layout() {
        super.layout()
        let inset = PaletteLayout.rowInset + 8
        let middle = bounds.height / 2
        let tileSize = PaletteLayout.tile
        tile.frame = NSRect(x: inset, y: middle - tileSize / 2, width: tileSize, height: tileSize)
        var right = bounds.width - inset
        func place(_ view: NSView, width: CGFloat, height: CGFloat) {
            right -= width
            view.frame = NSRect(x: right, y: (middle - height / 2).rounded(), width: width, height: height)
            right -= 10
        }
        if !chevron.isHidden { place(chevron, width: 12, height: 12) }
        if !kind.isHidden { place(kind, width: kind.textWidth, height: kind.intrinsicContentSize.height) }
        if !keycaps.symbols.isEmpty { place(keycaps, width: keycaps.intrinsicContentSize.width, height: Metrics.keycap) }
        if !badge.isHidden { place(badge, width: badge.intrinsicContentSize.width, height: badge.intrinsicContentSize.height) }
        if !check.isHidden { place(check, width: 12, height: 12) }
        let left = tile.frame.maxX + 10
        let available = max(right - left, 0)
        let titleHeight = title.intrinsicContentSize.height
        var titleWidth = min(title.textWidth, available)
        if !subtitle.isHidden { titleWidth = min(titleWidth, available * 0.7) }
        title.frame = NSRect(x: left, y: (middle - titleHeight / 2).rounded(), width: titleWidth, height: titleHeight)
        if !subtitle.isHidden {
            let height = subtitle.intrinsicContentSize.height
            let x = left + titleWidth + 8
            subtitle.frame = NSRect(x: x, y: (middle - height / 2).rounded(), width: max(right - x, 0), height: height)
        }
    }
}

/// A small muted pill, such as "current" or a count.
final class BadgePill: ThemedView {
    var text: String? { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }

    override var intrinsicContentSize: NSSize {
        let size = NSAttributedString(string: text ?? "", attributes: [.font: AppFont.system(10, weight: .medium)]).size()
        return NSSize(width: ceil(size.width) + 12, height: ceil(size.height) + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.fg(alpha: 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let string = NSAttributedString(string: text ?? "", attributes: [.font: AppFont.system(10, weight: .medium), .foregroundColor: theme.fgMuted])
        let size = string.size()
        string.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// A section header: 28pt, the title at its bottom.
final class PaletteSectionView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = AppFont.system(12)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(_ title: String) {
        label.stringValue = title
        label.textColor = AppTheme.shared.fgMuted
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: PaletteLayout.rowInset * 2, y: bounds.height - 6 - height, width: bounds.width - 32, height: height)
    }
}

/// A footer button: a label and its keycaps.
final class FooterButton: HoverView {
    let label = makeLabel("", font: AppFont.system(13, weight: .medium))
    let caps = KeycapsView()
    var action: (() -> Void)?
    var isEnabled = true { didSet { themeDidChange() } }
    /// A secondary button, such as Actions: its label is muted.
    var muted = false { didSet { themeDidChange() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
        addSubview(caps)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 12 + label.textWidth + 8 + caps.intrinsicContentSize.width + 6, height: 28)
    }

    override func themeDidChange() {
        label.textColor = !isEnabled ? theme.fgDim : muted ? theme.fgMuted : theme.fg
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isEnabled, isHovered else { return }
        theme.fg(alpha: 0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func layout() {
        super.layout()
        let width = label.textWidth
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 12, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        let capsSize = caps.intrinsicContentSize
        caps.frame = NSRect(x: 12 + width + 8, y: (bounds.height - capsSize.height) / 2, width: capsSize.width, height: capsSize.height)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}

/// The back chip on pushed pages: ‹ and the page's name.
final class BackChip: HoverView {
    var title = "" { didSet { label.stringValue = title; invalidateIntrinsicContentSize(); needsLayout = true } }
    var action: (() -> Void)?
    private let label = makeLabel("", font: AppFont.system(12, weight: .medium))
    private let chevron = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chevron.image = AppIcon.chevronLeft.image(size: 12)
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(chevron)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 8 + 12 + 4 + label.textWidth + 8, height: 26) }

    override func themeDidChange() {
        label.textColor = theme.fgMuted
        chevron.contentTintColor = theme.fgMuted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.fg(alpha: isHovered ? 0.12 : 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
    }

    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: 8, y: (bounds.height - 12) / 2, width: 12, height: 12)
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 24, y: ((bounds.height - height) / 2).rounded(), width: label.textWidth, height: height)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}

/// A toggle pill beside the search field, such as Aa or .*.
final class AccessoryPill: HoverView {
    let id: String
    var active: Bool { didSet { needsDisplay = true; themeDidChange() } }
    var action: (() -> Void)?
    private let label: NSTextField

    init(id: String, title: String, active: Bool) {
        self.id = id
        self.active = active
        label = makeLabel(title, font: AppFont.system(12, weight: .medium))
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: label.textWidth + 16, height: 24) }

    override func themeDidChange() {
        label.textColor = active ? theme.accent : theme.fgMuted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if active {
            theme.accentSoft.setFill()
            path.fill()
        } else {
            if isHovered {
                theme.hover.setFill()
                path.fill()
            }
            theme.border.setStroke()
            path.stroke()
        }
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 8, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 16, height: height)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}
