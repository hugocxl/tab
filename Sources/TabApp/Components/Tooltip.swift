import AppKit
import TabCore

/// The chrome's tooltip: a glass capsule under the hovered button with its
/// label and, when the action has one, its shortcut in a key cap. One panel
/// serves the whole app; moving between buttons while it shows switches it
/// at once, as system tooltips do.
@MainActor
enum GlassTooltip {
    /// Looks up the chord bound to a shortcut, from the current keymap.
    static var chord: ((ShortcutId) -> KeyChord?)?

    private static let delay: TimeInterval = 0.6
    /// How long after one tooltip hides the next shows without the delay.
    private static let warmWindow: TimeInterval = 0.4
    private static var panel: TooltipPanel?
    private static var pending: DispatchWorkItem?
    private static weak var owner: NSView?
    private static var hiddenAt: Date = .distantPast

    /// Shows `text` under `view` after the hover delay.
    static func schedule(_ text: String, shortcut: ShortcutId?, for view: NSView) {
        cancel()
        owner = view
        let item = DispatchWorkItem { show(text, shortcut: shortcut, for: view) }
        pending = item
        let warm = Date().timeIntervalSince(hiddenAt) < warmWindow
        DispatchQueue.main.asyncAfter(deadline: .now() + (warm ? 0 : delay), execute: item)
    }

    /// Hides the tooltip of `view`, or any tooltip when `view` is nil.
    static func hide(for view: NSView? = nil) {
        guard view == nil || view === owner else { return }
        cancel()
        owner = nil
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        hiddenAt = Date()
    }

    private static func cancel() {
        pending?.cancel()
        pending = nil
    }

    private static func show(_ text: String, shortcut: ShortcutId?, for view: NSView) {
        guard let window = view.window, view === owner, !view.isHiddenOrHasHiddenAncestor else { return }
        let panel = self.panel ?? TooltipPanel()
        self.panel = panel
        panel.appearance = AppTheme.shared.nsAppearance
        let size = panel.content.update(text, chord: shortcut.flatMap { chord?($0) })
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 6 - size.height)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            if origin.y < screen.minY { origin.y = anchor.maxY + 6 }
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }
}

private final class TooltipPanel: NSPanel {
    let content = TooltipView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The tooltip's capsule: glass, a hairline edge, the label and the key cap.
private final class TooltipView: ThemedView {
    private let glass = GlassView(style: .tooltip)
    private let label = makeLabel("", font: AppFont.body)
    private let keys = makeLabel("", font: AppFont.system(12, weight: .medium))
    private let cap = NSView()

    private static let height: CGFloat = 30
    private static let padding: CGFloat = 12
    private static let capHeight: CGFloat = 20

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = GlassView.Style.tooltip.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Metrics.border
        cap.wantsLayer = true
        cap.layer?.cornerRadius = Metrics.radiusMedium
        cap.layer?.cornerCurve = .continuous
        cap.layer?.borderWidth = Metrics.border
        keys.alignment = .center
        for view in [glass, label, cap, keys] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sets the text and shortcut and returns the size the tooltip needs.
    func update(_ text: String, chord: KeyChord?) -> NSSize {
        label.stringValue = text
        keys.stringValue = chord.map { KeyCap.symbols(for: $0).joined() } ?? ""
        cap.isHidden = chord == nil
        keys.isHidden = chord == nil
        setAccessibilityLabel(chord.map { "\(text), \($0.display)" } ?? text)
        themeDidChange()
        var width = Self.padding * 2 + label.textWidth
        if chord != nil { width += 10 + capWidth }
        return NSSize(width: ceil(width), height: Self.height)
    }

    private var capWidth: CGFloat { max(keys.textWidth + 12, Self.capHeight + 8) }

    override func themeDidChange() {
        glass.appearance = theme.nsAppearance
        layer?.backgroundColor = theme.chrome.withAlphaComponent(0.55).cgColor
        layer?.borderColor = theme.cardBorder.cgColor
        label.textColor = theme.fgMuted
        keys.textColor = theme.fgMuted
        cap.layer?.borderColor = theme.fgDim.withAlphaComponent(0.6).cgColor
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let labelHeight = label.intrinsicContentSize.height
        label.frame = CGRect(x: Self.padding, y: ((bounds.height - labelHeight) / 2).rounded(), width: label.textWidth + 2, height: labelHeight)
        guard !cap.isHidden else { return }
        let capWidth = self.capWidth
        cap.frame = CGRect(x: bounds.width - Self.padding + 4 - capWidth, y: ((bounds.height - Self.capHeight) / 2).rounded(),
                           width: capWidth, height: Self.capHeight)
        let keysHeight = keys.intrinsicContentSize.height
        keys.frame = CGRect(x: cap.frame.minX, y: (cap.frame.midY - keysHeight / 2).rounded(), width: capWidth, height: keysHeight)
    }
}
