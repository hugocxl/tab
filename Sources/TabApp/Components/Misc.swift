import AppKit
import TabClient

/// A list row with hover and selection fills: optional icon, title,
/// subtitle and a trailing accessory.
public final class ListRow: HoverView {
    public let titleLabel: NSTextField
    public let subtitleLabel: NSTextField
    private let iconView = NSImageView()
    public var isSelected = false { didSet { needsDisplay = true } }
    public var onClick: (() -> Void)?

    public init(title: String, subtitle: String? = nil, icon: NSImage? = nil, accessory: NSView? = nil) {
        titleLabel = makeLabel(title, font: AppFont.body)
        subtitleLabel = makeLabel(subtitle ?? "", font: AppFont.footnote)
        subtitleLabel.isHidden = subtitle == nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = Metrics.controlGap
        row.alignment = .centerY
        if let icon {
            iconView.image = icon
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: Metrics.glyph).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: Metrics.glyph).isActive = true
            row.addArrangedSubview(iconView)
        }
        row.addArrangedSubview(text)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let accessory { row.addArrangedSubview(accessory) }
        addSubview(row)
        row.pinEdges(to: self, insets: NSEdgeInsets(top: 4, left: Metrics.gutter, bottom: 4, right: Metrics.gutter))
        heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func themeDidChange() {
        titleLabel.textColor = theme.fg
        subtitleLabel.textColor = theme.fgMuted
        iconView.contentTintColor = theme.fgMuted
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isHovered else { return }
        (isSelected ? theme.selection : theme.hover).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
    }

    public override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    public override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// A small spinning indicator; it animates only while in a window, and not
/// at all under Reduce Motion.
public final class Spinner: NSView {
    private let indicator = NSProgressIndicator()

    public init(size: NSControl.ControlSize = .small) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        indicator.style = .spinning
        indicator.controlSize = size
        indicator.isDisplayedWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)
        indicator.pinEdges(to: self)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Loading")
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            indicator.startAnimation(nil)
        } else {
            indicator.stopAnimation(nil)
        }
    }
}

/// Draws a QR code dark on white with its quiet zone, modules on whole
/// points so it stays sharp.
public final class QRCodeView: NSView {
    public var code: QRCode? { didSet { needsDisplay = true } }

    public init(code: QRCode?, label: String = "Pairing code") {
        self.code = code
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(label)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusLarge, yRadius: Metrics.radiusLarge).fill()
        guard let code else { return }
        let span = code.size + 2 * QRCode.quietZone
        let module = floor(min(bounds.width, bounds.height) / CGFloat(span))
        guard module > 0 else { return }
        let origin = NSPoint(
            x: ((bounds.width - module * CGFloat(span)) / 2).rounded() + module * CGFloat(QRCode.quietZone),
            y: ((bounds.height - module * CGFloat(span)) / 2).rounded() + module * CGFloat(QRCode.quietZone)
        )
        NSColor.black.setFill()
        let path = NSBezierPath()
        for y in 0..<code.size {
            for x in 0..<code.size where code.isDark(x: x, y: y) {
                path.appendRect(NSRect(x: origin.x + CGFloat(x) * module, y: origin.y + CGFloat(y) * module, width: module, height: module))
            }
        }
        path.fill()
    }
}

/// A flipped document view for scroll views, so content starts at the top.
public final class FlippedView: NSView {
    public override var isFlipped: Bool { true }
}

/// A scroll view with overlay scrollers and no background of its own, whose
/// document view fills its width.
public final class ScrollView: NSScrollView {
    public let content = FlippedView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        autohidesScrollers = true
        borderType = .noBorder
        content.translatesAutoresizingMaskIntoConstraints = false
        documentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentView.topAnchor),
        ])
    }

    public convenience init() { self.init(frame: .zero) }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The current scroll offset from the top.
    public var scrollOffset: CGFloat {
        get { contentView.bounds.origin.y }
        set {
            layoutSubtreeIfNeeded()
            let maximum = max(content.frame.height - contentView.bounds.height, 0)
            contentView.scroll(to: NSPoint(x: 0, y: min(max(newValue, 0), maximum)))
            reflectScrolledClipView(contentView)
        }
    }
}

/// Shows a view in a popover styled like the chrome.
@MainActor
public enum PopoverHost {
    /// Shows `content` next to `anchor`, closing when the user clicks
    /// elsewhere. Returns the popover so callers can close it.
    @discardableResult
    public static func show(
        _ content: NSView,
        size: NSSize,
        relativeTo anchor: NSView,
        edge: NSRectEdge = .maxY,
        theme: AppTheme? = nil
    ) -> NSPopover {
        let theme = theme ?? .shared
        let controller = NSViewController()
        let container = ThemedBackground(color: { $0.raised })
        container.theme = theme
        container.addSubview(content)
        content.pinEdges(to: container)
        controller.view = container
        controller.preferredContentSize = size
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.appearance = theme.nsAppearance
        popover.contentViewController = controller
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
        return popover
    }
}

/// A view filled with one theme color.
public final class ThemedBackground: ThemedView {
    private let color: (AppTheme) -> NSColor
    public var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }

    public init(color: @escaping (AppTheme) -> NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = color(theme).cgColor
        layer?.cornerRadius = cornerRadius
    }
}
