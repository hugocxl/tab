import AppKit
import Combine

/// A layer-backed view that redraws when its theme's palette changes. Only
/// views in a window listen, so detached views cost nothing.
open class ThemedView: NSView {
    /// The theme the view draws with.
    public var theme: AppTheme = .shared {
        didSet { subscribe() }
    }

    private var paletteObservation: AnyCancellable?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    open override var isFlipped: Bool { true }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        subscribe()
    }

    private func subscribe() {
        guard window != nil else {
            paletteObservation = nil
            return
        }
        // @Published emits before storing the new palette. Renderers read the
        // theme's color properties, so deliver after that mutation has completed.
        paletteObservation = theme.$palette.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.themeDidChange() }
        themeDidChange()
    }

    /// Called when the palette changes while the view is in a window.
    /// Subclasses update colors here; the default asks for a redraw.
    open func themeDidChange() {
        needsDisplay = true
    }
}

/// Calls `update` now and whenever the shared theme's palette changes, while
/// the view is in a window; for native controls tinted with theme colors.
@MainActor
final class PaletteObserver {
    private var observation: AnyCancellable?

    func observe(_ view: NSView, update: @escaping () -> Void) {
        guard view.window != nil else {
            observation = nil
            return
        }
        observation = AppTheme.shared.$palette.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in update() }
        update()
    }
}

/// A view tracking whether the pointer is inside it.
open class HoverView: ThemedView {
    public private(set) var isHovered = false {
        didSet { if oldValue != isHovered { hoverDidChange() } }
    }

    private var hoverArea: NSTrackingArea?

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
        syncHover()
    }

    /// Clears a stale hover: moving or resizing the view away from a still
    /// pointer sends no exited event.
    public func syncHover() {
        guard isHovered else { return }
        guard let window, !isHiddenOrHasHiddenAncestor, NSApp.isActive else {
            isHovered = false
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !visibleRect.contains(point) { isHovered = false }
    }

    open override func mouseEntered(with event: NSEvent) { isHovered = true }
    open override func mouseExited(with event: NSEvent) { isHovered = false }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovered = false }
    }

    /// Called when `isHovered` changes; redraws by default.
    open func hoverDidChange() {
        needsDisplay = true
    }
}

extension NSView {
    /// Pins the view's edges to `other`'s with `insets`.
    func pinEdges(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

/// A label configured like the chrome's text: no bezel, no background, not
/// editable.
@MainActor
func makeLabel(_ text: String, font: NSFont = AppFont.body, color: NSColor? = nil) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = color ?? AppTheme.shared.fg
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}
