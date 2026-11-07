import CoreVideo
import GameController
import TabMobileKit
import TabProtocol
import UIKit

/// A simulator's screen, as large as fits, centered with rounded corners and
/// turned the way the simulator is held. Frames decode in hardware off the
/// main thread into surfaces the layer shows without copies. A finger is a touch on the
/// simulator, and keys type on its keyboard: a hardware keyboard's keys as
/// they are, the on-screen keyboard's text as key presses.
final class SimulatorScreenView: UIView, SimulatorDisplay, UIKeyInput {
    /// Input for the simulator, in order.
    var onInput: (([SimulatorInput]) -> Void)?
    /// The display took a frame; the next may come.
    var onFrameShown: (() -> Void)?
    /// A frame couldn't decode; a keyframe must come next.
    var onNeedsKeyframe: (() -> Void)?
    /// Joined or left a window, so the stream should run or stop.
    var onWindowChange: ((Bool) -> Void)?

    /// Which way up the simulator is; the stream keeps the panel's portrait.
    var orientation = SimulatorOrientation.portrait {
        didSet { if orientation != oldValue { setNeedsLayout() } }
    }

    private let video = CALayer()
    private let decoding = DispatchQueue(label: "com.hugocorta.tab.simulator.decode", qos: .userInteractive)
    private var decoder: SimulatorVideoDecoder?
    /// Counts streams, so a picture from the last one is dropped.
    private var generation = 0
    /// Holds the picture behind the layer, so its pool doesn't reuse it while shown.
    private var shown: CVPixelBuffer?
    /// The stream's size: the panel in portrait.
    private var panelSize = CGSize.zero
    private var touch: UITouch?
    private var heldKeys: Set<UInt32> = []
    private var wantsSoftwareKeyboard = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        video.contentsGravity = .resize
        video.backgroundColor = UIColor.black.cgColor
        video.masksToBounds = true
        video.cornerCurve = .continuous
        video.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull(),
                         "cornerRadius": NSNull()]
        video.isHidden = true
        layer.addSublayer(video)
        isAccessibilityElement = true
        accessibilityLabel = "Simulator screen"
        accessibilityTraits = [.image, .allowsDirectInteraction]
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The most simulator pixels the view shows at its size, at least a small phone's.
    var maxPixels: UInt32 {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let pixels = bounds.width * scale * bounds.height * scale
        return UInt32(min(max(pixels, 640 * 960), 4096 * 4096))
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window != nil)
    }

    // MARK: Showing

    func streamStarted() {
        generation += 1
        decoder = nil
    }

    /// Decodes off the main thread, shows the picture, then lets the next frame come.
    func show(_ frame: VideoFrame, codec: VideoCodec) -> Bool {
        guard window != nil else { return false }
        if decoder?.codec != codec { decoder = SimulatorVideoDecoder(codec: codec) }
        guard let decoder else { return false }
        let generation = generation
        decoding.async { [weak self] in
            let picture = try? decoder.decode(frame)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    if let picture {
                        self.display(picture, size: CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height)))
                    } else {
                        self.onNeedsKeyframe?()
                    }
                    self.onFrameShown?()
                }
            }
        }
        return true
    }

    private func display(_ picture: CVPixelBuffer, size: CGSize) {
        guard let surface = CVPixelBufferGetIOSurface(picture)?.takeUnretainedValue() else { return }
        if size != panelSize {
            panelSize = size
            setNeedsLayout()
            layoutIfNeeded()
        }
        shown = picture
        video.contents = surface
        video.isHidden = false
    }

    /// Hides the picture until the next stream.
    func clear() {
        generation += 1
        decoder = nil
        shown = nil
        video.contents = nil
        video.isHidden = true
    }

    private var uprightSize: CGSize {
        orientation.isLandscape ? CGSize(width: panelSize.height, height: panelSize.width) : panelSize
    }

    /// Where the screen is drawn as the user sees it.
    private var screenRect: CGRect { Self.screenRect(upright: uprightSize, in: bounds) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = screenRect
        let panel = orientation.isLandscape ? CGSize(width: rect.height, height: rect.width) : rect.size
        video.transform = CATransform3DIdentity
        video.bounds = CGRect(origin: .zero, size: panel)
        video.position = CGPoint(x: rect.midX, y: rect.midY)
        // The content is drawn turned against the simulator, so the layer
        // turns with it: counterclockwise, which is negative with y down.
        video.transform = CATransform3DMakeRotation(-CGFloat(orientation.quarterTurns) * .pi / 2, 0, 0, 1)
        // Phones round their displays more than tablets.
        let short = min(rect.width, rect.height)
        let long = max(rect.width, rect.height)
        video.cornerRadius = short * (long / max(short, 1) > 1.8 ? 0.12 : 0.04)
    }

    /// The largest rect of `upright`'s shape that fits `bounds`, centered.
    static func screenRect(upright: CGSize, in bounds: CGRect) -> CGRect {
        guard upright.width > 0, upright.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / upright.width, bounds.height / upright.height)
        let width = (upright.width * scale).rounded()
        let height = (upright.height * scale).rounded()
        return CGRect(x: bounds.minX + ((bounds.width - width) / 2).rounded(),
                      y: bounds.minY + ((bounds.height - height) / 2).rounded(), width: width, height: height)
    }

    /// A point in the view as a touch on the panel, clamped to the screen.
    static func panelPoint(_ point: CGPoint, screen rect: CGRect, orientation: SimulatorOrientation) -> SimulatorInput? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((point.y - rect.minY) / rect.height, 0), 1)
        let panel = orientation.panelPoint(x: Double(x), y: Double(y))
        return .touch(x: panel.x, y: panel.y, down: true)
    }

    // MARK: Touch

    private func input(_ touch: UITouch, down: Bool) -> SimulatorInput? {
        guard case .touch(let x, let y, _)? = Self.panelPoint(touch.location(in: self), screen: screenRect,
                                                              orientation: orientation) else { return nil }
        return .touch(x: x, y: y, down: down)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touch == nil, let first = touches.first, !video.isHidden,
              screenRect.contains(first.location(in: self)), let input = input(first, down: true) else {
            super.touchesBegan(touches, with: event)
            return
        }
        if !isFirstResponder, canBecomeFirstResponder { becomeFirstResponder() }
        touch = first
        onInput?([input])
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return super.touchesMoved(touches, with: event) }
        let moves = (event?.coalescedTouches(for: touch) ?? [touch]).compactMap { input($0, down: true) }
        onInput?(moves)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return super.touchesEnded(touches, with: event) }
        lift(touch)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return super.touchesCancelled(touches, with: event) }
        lift(touch)
    }

    private func lift(_ touch: UITouch) {
        self.touch = nil
        if let input = input(touch, down: false) { onInput?([input]) }
    }

    // MARK: Keyboard

    /// The screen takes keys only when asked to, or from a hardware
    /// keyboard, so a touch never brings up the on-screen keyboard.
    override var canBecomeFirstResponder: Bool { wantsSoftwareKeyboard || GCKeyboard.coalesced != nil }

    var showsSoftwareKeyboard: Bool { wantsSoftwareKeyboard && isFirstResponder }

    /// Shows or hides the on-screen keyboard.
    func setSoftwareKeyboard(_ shown: Bool) {
        if shown {
            wantsSoftwareKeyboard = true
            becomeFirstResponder()
        } else {
            _ = resignFirstResponder()
        }
    }

    override func resignFirstResponder() -> Bool {
        releaseKeys()
        wantsSoftwareKeyboard = false
        return super.resignFirstResponder()
    }

    /// A hardware keyboard's keys go to the simulator as they are, except
    /// Command, which stays with the app's shortcuts.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var others: Set<UIPress> = []
        var input: [SimulatorInput] = []
        for press in presses {
            guard let key = press.key, !key.modifierFlags.contains(.command), key.keyCode.rawValue > 0 else {
                others.insert(press)
                continue
            }
            let usage = UInt32(key.keyCode.rawValue)
            heldKeys.insert(usage)
            input.append(.key(usage: usage, down: true))
        }
        if !input.isEmpty { onInput?(input) }
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = lift(presses)
        if !others.isEmpty { super.pressesEnded(others, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = lift(presses)
        if !others.isEmpty { super.pressesCancelled(others, with: event) }
    }

    /// Releases the keys of `presses` that went to the simulator; returns the rest.
    private func lift(_ presses: Set<UIPress>) -> Set<UIPress> {
        var others: Set<UIPress> = []
        var input: [SimulatorInput] = []
        for press in presses {
            guard let usage = press.key.map({ UInt32($0.keyCode.rawValue) }), heldKeys.remove(usage) != nil else {
                others.insert(press)
                continue
            }
            input.append(.key(usage: usage, down: false))
        }
        if !input.isEmpty { onInput?(input) }
        return others
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Paste Text", action: #selector(pasteCommand), input: "v", modifierFlags: .command)]
    }

    @objc private func pasteCommand() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        onInput?(SimulatorKeyboard.input(typing: text))
    }

    /// Lifts held keys so none stays down on the simulator.
    private func releaseKeys() {
        guard !heldKeys.isEmpty else { return }
        onInput?(heldKeys.map { .key(usage: $0, down: false) })
        heldKeys = []
    }

    // The on-screen keyboard; a hardware key already went out as itself.

    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard heldKeys.isEmpty else { return }
        onInput?(SimulatorKeyboard.input(typing: text))
    }

    func deleteBackward() {
        guard heldKeys.isEmpty else { return }
        onInput?(SimulatorKeyboard.tap(SimulatorKeyboard.backspace))
    }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
}
