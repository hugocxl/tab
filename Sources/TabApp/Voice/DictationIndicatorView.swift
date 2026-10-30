import AppKit
import QuartzCore

/// The floating dictation overlay, as in Codesh: a transcript chip, then a
/// panel with the recording dot, the clock, an input meter and Cancel,
/// Pause and Finish buttons, then key hints. While transcribing only Cancel
/// stays; a failure shows its message and a Close button.
@MainActor
final class DictationIndicatorView: ThemedView {
    static let width: CGFloat = 280
    static let bottomInset: CGFloat = 48

    var onCancel: (() -> Void)?
    var onPause: (() -> Void)?
    var onFinish: (() -> Void)?

    private let chip = ThemedBackground(color: { $0.surface })
    private let chipLabel = makeLabel("", font: AppFont.footnote)
    private let panel = DictationPanel()
    private let dot = NSView()
    private let clock = makeLabel("00:00", font: AppFont.mono(13, weight: .medium))
    private let meter = DictationMeter()
    private let cancelButton = DictationButton(symbol: "xmark", label: "Cancel")
    private let pauseButton = DictationButton(symbol: "pause.fill", label: "Pause")
    private let finishButton = DictationButton(symbol: "circle.fill", label: "Finish")
    private let hints = DictationHints()
    private let closeButton = PillButton("Close")
    private var state = DictationState()
    private var autoSend = false
    private var focused = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Dictation")

        chipLabel.lineBreakMode = .byWordWrapping
        chipLabel.maximumNumberOfLines = 4
        chipLabel.preferredMaxLayoutWidth = Self.width - 20
        chip.cornerRadius = Metrics.radiusMedium
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chipLabel)
        chipLabel.pinEdges(to: chip, insets: NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10))

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.translatesAutoresizingMaskIntoConstraints = false
        clock.alignment = .left
        cancelButton.onPress = { [weak self] in self?.onCancel?() }
        pauseButton.onPress = { [weak self] in self?.onPause?() }
        finishButton.onPress = { [weak self] in self?.onFinish?() }
        closeButton.onPress = { [weak self] in self?.onCancel?() }
        let buttons = NSStackView(views: [cancelButton, pauseButton, finishButton])
        buttons.spacing = 6
        let row = NSStackView(views: [dot, clock, meter, buttons])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        panel.addSubview(row)
        row.pinEdges(to: panel, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        meter.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let column = NSStackView(views: [chip, panel, hints, closeButton])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6
        addSubview(column)
        column.pinEdges(to: self, insets: NSEdgeInsets(top: 0, left: 0, bottom: Self.bottomInset, right: 0))
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12),
            clock.widthAnchor.constraint(equalToConstant: 48),
            meter.heightAnchor.constraint(equalToConstant: 24),
            chip.widthAnchor.constraint(equalToConstant: Self.width),
            panel.widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Showing state

    func show(_ state: DictationState, elapsed: TimeInterval, autoSend: Bool) {
        let phaseChanged = state.phase != self.state.phase || state.error != self.state.error
        self.state = state
        self.autoSend = autoSend
        clock.stringValue = DictationText.clock(elapsed)
        meter.level = state.phase == .recording ? state.level : 0
        chipLabel.stringValue = state.error ?? chipText
        guard phaseChanged else { return }
        let active = state.phase != .starting && state.phase != .failed && state.phase != .finished
        panel.isHidden = !active
        hints.isHidden = !active
        closeButton.isHidden = state.error == nil
        pauseButton.isHidden = state.phase == .transcribing
        finishButton.isHidden = state.phase == .transcribing
        pauseButton.symbol = state.phase == .paused ? "play.fill" : "pause.fill"
        pauseButton.setAccessibilityLabel(state.phase == .paused ? "Resume" : "Pause")
        hints.update(phase: state.phase, autoSend: autoSend)
        themeDidChange()
    }

    private var chipText: String {
        if state.phase == .transcribing { return "Transcribing on this computer…" }
        if state.transcript.isEmpty { return "Listening..." }
        return DictationText.tail(state.transcript)
    }

    override func themeDidChange() {
        chipLabel.textColor = state.error != nil ? theme.diffRemove : (state.transcript.isEmpty ? theme.fgDim : theme.fgMuted)
        clock.textColor = theme.fg
        cancelButton.contentTintColor = theme.fgMuted
        pauseButton.contentTintColor = theme.fg
        finishButton.contentTintColor = theme.diffRemove
        panel.focused = focused
        hints.alphaValue = focused ? 1 : 0.55
        let paused = state.phase == .paused
        dot.layer?.backgroundColor = (paused ? theme.warning : theme.diffRemove).cgColor
        updatePulse(running: state.phase == .recording)
        needsDisplay = true
    }

    /// The dot breathes while recording, as a layer animation, not redraws.
    private func updatePulse(running: Bool) {
        guard let layer = dot.layer else { return }
        let key = "pulse"
        guard running, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer.removeAnimation(forKey: key)
            layer.opacity = 1
            return
        }
        guard layer.animation(forKey: key) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.4
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer.add(pulse, forKey: key)
    }

    // MARK: Keys

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        focused = true
        themeDidChange()
        return true
    }

    override func resignFirstResponder() -> Bool {
        focused = false
        themeDidChange()
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: onFinish?()
        case 49: onPause?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    // MARK: Showing and hiding

    /// Pins the overlay to the bottom center of `container` and slides it in.
    func present(in container: NSView) {
        container.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        animate(showing: true, completion: nil)
    }

    func dismiss() {
        animate(showing: false) { [weak self] in self?.removeFromSuperview() }
    }

    private func animate(showing: Bool, completion: (() -> Void)?) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = showing ? 0 : 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.2
            animator().alphaValue = showing ? 1 : 0
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }
}

/// The panel behind the controls: the window color, a hairline that turns
/// accent while the overlay has focus, and a shadow.
@MainActor
private final class DictationPanel: ThemedView {
    var focused = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: Metrics.radiusLarge, yRadius: Metrics.radiusLarge)
        theme.bg.setFill()
        path.fill()
        (focused ? theme.accent.withAlphaComponent(0.6) : theme.border).setStroke()
        path.lineWidth = Metrics.border
        path.stroke()
    }
}

/// Eleven bars shaped like an arch that light up with the input level.
@MainActor
private final class DictationMeter: ThemedView {
    static let bars = 11
    var level: Float = 0 {
        didSet {
            if litBars(level) != litBars(oldValue) { needsDisplay = true }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func litBars(_ level: Float) -> Int {
        (0..<Self.bars).filter { level >= Float($0 + 1) / Float(Self.bars) }.count
    }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 3
        let width = max((bounds.width - gap * CGFloat(Self.bars - 1)) / CGFloat(Self.bars), 1)
        let lit = litBars(level)
        for index in 0..<Self.bars {
            let curve = 0.5 + 0.5 * sin(CGFloat(index) / CGFloat(Self.bars - 1) * .pi)
            let height = min(10 + 14 * curve, bounds.height)
            let rect = NSRect(x: CGFloat(index) * (width + gap), y: (bounds.height - height) / 2, width: width, height: height)
            (index < lit ? theme.accent : theme.surface).setFill()
            NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }
}

/// A native 24pt accessory-bar button with a tinted SF Symbol.
@MainActor
private final class DictationButton: NSButton {
    var onPress: (() -> Void)?
    var symbol: String { didSet { updateImage() } }

    init(symbol: String, label: String) {
        self.symbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .accessoryBarAction
        refusesFirstResponder = true
        imagePosition = .imageOnly
        title = ""
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(pressed)
        updateImage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }

    private func updateImage() {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    }

    @objc private func pressed() {
        onPress?()
    }
}

/// The key hints pill: ⎋ Cancel, Space Pause or Resume, ⏎ Insert or Send.
@MainActor
private final class DictationHints: ThemedView {
    private let label = makeLabel("", font: AppFont.caption)
    private var phase = DictationPhase.starting
    private var autoSend = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.pinEdges(to: self, insets: NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(phase: DictationPhase, autoSend: Bool) {
        self.phase = phase
        self.autoSend = autoSend
        themeDidChange()
    }

    override func themeDidChange() {
        var hints: [(String, String)] = [("⎋", "Cancel")]
        if phase != .transcribing {
            hints.append(("Space", phase == .paused ? "Resume" : "Pause"))
            hints.append(("⏎", autoSend ? "Send" : "Insert"))
        }
        let text = NSMutableAttributedString()
        for (index, hint) in hints.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "    ")) }
            text.append(NSAttributedString(string: hint.0 + " ", attributes: [
                .font: AppFont.mono(10, weight: .semibold), .foregroundColor: theme.fgMuted,
            ]))
            text.append(NSAttributedString(string: hint.1, attributes: [
                .font: AppFont.caption, .foregroundColor: theme.fgDim,
            ]))
        }
        label.attributedStringValue = text
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        theme.bg.withAlphaComponent(0.85).setFill()
        path.fill()
        theme.border.setStroke()
        path.lineWidth = Metrics.border
        path.stroke()
    }
}
