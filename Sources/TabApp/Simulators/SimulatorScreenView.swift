import AppKit
import IOSurface
import TabSimulators
import TabProtocol

/// A simulator's screen, scaled to fit and centered with rounded corners, turned
/// the way the simulator is held. The surface is the layer's contents, so the
/// simulator draws straight to the window without copies; a frame only marks
/// the contents changed. Clicks and drags are touches, trackpad scrolls are
/// drags and keys go to the simulator's keyboard.
final class SimulatorScreenView: ThemedView {
    /// Input for the simulator, in order.
    var onInput: (([SimulatorInput]) -> Void)?
    /// The view's size changed: the most pixels it can show now.
    var onResize: ((UInt32) -> Void)?

    /// The most simulator pixels the view shows at its size, at least a small phone's.
    var maxPixels: UInt32 {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixels = bounds.width * scale * bounds.height * scale
        return UInt32(min(max(pixels, 640 * 960), 4096 * 4096))
    }

    private var reportedPixels: UInt32 = 0

    /// Which way up the simulator is; the surface keeps the panel's portrait.
    var orientation = SimulatorOrientation.portrait {
        didSet { if orientation != oldValue { needsLayout = true } }
    }

    private let screen = CALayer()
    private var surface: IOSurface?
    private var pressed = false
    private var scrollStart: CGPoint?
    private var scrollOffset = CGSize.zero
    private var modifiers: NSEvent.ModifierFlags = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        screen.contentsGravity = .resize
        screen.masksToBounds = true
        screen.cornerCurve = .continuous
        screen.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(),
                          "transform": NSNull()]
        layer?.addSublayer(screen)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Simulator screen")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `surface`, or nothing.
    func show(_ surface: IOSurface?) {
        self.surface = surface
        screen.contents = surface
        screen.isHidden = surface == nil
        needsLayout = true
    }

    /// The surface has a new frame.
    func surfaceDidDraw() {
        guard let surface else { return }
        if screen.responds(to: Self.contentsChanged) {
            screen.perform(Self.contentsChanged)
        } else {
            screen.contents = nil
            screen.contents = surface
        }
    }

    private static let contentsChanged = NSSelectorFromString("setContentsChanged")

    /// The surface's size in pixels: the panel in portrait.
    private var panelSize: CGSize {
        guard let surface else { return .zero }
        return CGSize(width: surface.width, height: surface.height)
    }

    /// The screen's size as the user sees it.
    private var uprightSize: CGSize {
        let size = panelSize
        return orientation.isLandscape ? CGSize(width: size.height, height: size.width) : size
    }

    /// Where the screen is drawn as the user sees it: as large as fits,
    /// centered.
    private var screenRect: CGRect {
        let size = uprightSize
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = (size.width * scale).rounded()
        let height = (size.height * scale).rounded()
        return CGRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(),
                      width: width, height: height)
    }

    override func layout() {
        super.layout()
        let pixels = maxPixels
        if pixels != reportedPixels {
            reportedPixels = pixels
            onResize?(pixels)
        }
        let rect = screenRect
        let panel = orientation.isLandscape ? CGSize(width: rect.height, height: rect.width) : rect.size
        screen.transform = CATransform3DIdentity
        screen.bounds = CGRect(origin: .zero, size: panel)
        screen.position = CGPoint(x: rect.midX, y: rect.midY)
        screen.transform = CATransform3DMakeRotation(Self.rotation(orientation, flipped: layer?.contentsAreFlipped() ?? isFlipped), 0, 0, 1)
        // Phones round their displays more than tablets.
        let short = min(rect.width, rect.height)
        let long = max(rect.width, rect.height)
        screen.cornerRadius = short * (long / max(short, 1) > 1.8 ? 0.12 : 0.04)
    }

    /// The layer rotation that shows the panel upright: the content is drawn
    /// turned against the simulator, so the layer turns with it. A flipped
    /// layer's positive angles turn clockwise on screen.
    static func rotation(_ orientation: SimulatorOrientation, flipped: Bool) -> CGFloat {
        let counterclockwise = CGFloat(orientation.quarterTurns) * .pi / 2
        return flipped ? -counterclockwise : counterclockwise
    }

    override func themeDidChange() {
        screen.backgroundColor = NSColor.black.cgColor
    }

    // MARK: Touch

    /// A point in the view as a touch on the panel, clamped to the screen.
    private func panelPoint(_ point: CGPoint) -> CGPoint? {
        let rect = screenRect
        guard rect.width > 0 else { return nil }
        let upright = CGPoint(x: min(max((point.x - rect.minX) / rect.width, 0), 1),
                              y: min(max((point.y - rect.minY) / rect.height, 0), 1))
        return orientation.panelPoint(upright)
    }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = location(event)
        guard screenRect.contains(point), let panel = panelPoint(point) else { return }
        pressed = true
        onInput?([.touch(panel, down: true)])
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed, let panel = panelPoint(location(event)) else { return }
        onInput?([.touch(panel, down: true)])
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed, let panel = panelPoint(location(event)) else { return }
        pressed = false
        onInput?([.touch(panel, down: false)])
    }

    /// A trackpad scroll drags a finger the same way; the simulator adds its
    /// own momentum when it lifts. A mouse wheel notch is a short swipe.
    override func scrollWheel(with event: NSEvent) {
        let rect = screenRect
        guard rect.width > 0, !pressed, event.momentumPhase.isEmpty else { return }
        let point = location(event)
        guard scrollStart != nil || rect.contains(point) else { return }
        let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
        if event.phase.isEmpty {
            let line: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            let end = CGPoint(x: point.x + delta.width * line, y: point.y + delta.height * line)
            let middle = CGPoint(x: (point.x + end.x) / 2, y: (point.y + end.y) / 2)
            let path = [point, middle, end].compactMap { panelPoint($0) }
            guard let last = path.last else { return }
            onInput?(path.map { .touch($0, down: true) } + [.touch(last, down: false)])
            return
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            scrollStart = point
            scrollOffset = .zero
            if let panel = panelPoint(point) { onInput?([.touch(panel, down: true)]) }
        }
        guard let start = scrollStart else { return }
        scrollOffset.width += delta.width
        scrollOffset.height += delta.height
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        if ended { scrollStart = nil }
        guard let panel = panelPoint(CGPoint(x: start.x + scrollOffset.width, y: start.y + scrollOffset.height)) else { return }
        onInput?([.touch(panel, down: !ended)])
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat, let usage = SimulatorKeyboard.usage(keyCode: event.keyCode) else { return }
        onInput?([.key(usage: usage, down: true)])
    }

    override func keyUp(with event: NSEvent) {
        guard let usage = SimulatorKeyboard.usage(keyCode: event.keyCode) else { return }
        onInput?([.key(usage: usage, down: false)])
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var input: [SimulatorInput] = []
        for (flag, usage) in Self.modifierUsages where flags.contains(flag) != modifiers.contains(flag) {
            input.append(.key(usage: usage, down: flags.contains(flag)))
        }
        modifiers = flags
        if !input.isEmpty { onInput?(input) }
    }

    override func resignFirstResponder() -> Bool {
        releaseModifiers()
        return super.resignFirstResponder()
    }

    /// Lifts held modifiers so none stays down on the simulator.
    private func releaseModifiers() {
        let held = Self.modifierUsages.filter { modifiers.contains($0.0) }
        modifiers = []
        if !held.isEmpty { onInput?(held.map { .key(usage: $0.1, down: false) }) }
    }

    /// Types `text` on the simulator's keyboard.
    func type(_ text: String) {
        let input = SimulatorKeyboard.input(typing: text)
        if !input.isEmpty { onInput?(input) }
    }

    /// The modifier usages a flags change presses or releases.
    private static let modifierUsages: [(NSEvent.ModifierFlags, UInt32)] = [
        (.control, 0xE0), (.shift, 0xE1), (.option, 0xE2), (.command, 0xE3),
    ]
}
