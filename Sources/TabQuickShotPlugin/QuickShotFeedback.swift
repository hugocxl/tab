import AppKit
import QuartzCore
import TabApp

/// Where the thumbnail sits: the lower right of the visible screen.
struct QuickShotPreviewLayout {
    let frame: CGRect

    init(screen: CGRect, visible: CGRect, imageSize: CGSize) {
        let usable = visible.intersection(screen)
        let margin: CGFloat = 24
        let maxWidth = min(300, max(120, usable.width * 0.23))
        let maxHeight = min(200, max(80, usable.height - 2 * margin))
        let scale = min(maxWidth / max(imageSize.width, 1), maxHeight / max(imageSize.height, 1))
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        frame = CGRect(x: usable.maxX - margin - size.width, y: usable.minY + margin, width: size.width, height: size.height)
    }
}

/// The shutter sound, the capture flying into a corner, and a thumbnail that
/// opens the PNG when clicked and fades away on its own.
@MainActor
final class QuickShotFeedback: NSObject {
    private let theme: AppTheme
    private var panel: NSPanel?
    private var presentation: Task<Void, Never>?
    private lazy var sound: NSSound? = {
        let folder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
        let sound = ["Screen Capture.aif", "Grab.aif"].lazy
            .compactMap { NSSound(contentsOfFile: folder + $0, byReference: true) }.first ?? NSSound(named: "Tink")
        sound?.volume = 0.55
        return sound
    }()

    init(theme: AppTheme) {
        self.theme = theme
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(dismiss), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(dismiss), name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    func invalidate() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        dismiss()
    }

    @objc func dismiss() {
        presentation?.cancel()
        presentation = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    func playSound() {
        sound?.stop()
        sound?.play()
    }

    func show(_ shot: QuickShot) {
        dismiss()
        let layout = QuickShotPreviewLayout(
            screen: shot.screen.frame, visible: shot.screen.visibleFrame,
            imageSize: CGSize(width: shot.image.width, height: shot.image.height)
        )
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reducedMotion { showFlight(image: shot.image, screen: shot.screen, target: layout.frame) }
        presentation = Task { @MainActor [weak self] in
            do {
                if !reducedMotion { try await Task.sleep(nanoseconds: 720_000_000) }
                guard let self, !Task.isCancelled else { return }
                panel?.orderOut(nil)
                panel?.close()
                showPreview(shot, frame: layout.frame, fadeIn: reducedMotion)
                scheduleFadeOut()
            } catch {
                // Replaced by a newer capture, or dismissed.
            }
        }
    }

    /// Fades the thumbnail after a few seconds, or once the pointer leaves it.
    private func scheduleFadeOut(after delay: UInt64 = 3_000_000_000) {
        presentation?.cancel()
        presentation = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled else { return }
                if (panel?.contentView as? QuickShotPreviewView)?.isHovered == true { return }
                let panel = panel
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.22
                    panel?.animator().alphaValue = 0
                }, completionHandler: nil)
                try await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                dismiss()
            } catch {
                // Replaced by a newer capture, or dismissed.
            }
        }
    }

    private func makePanel(frame: CGRect, interactive: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setFrame(frame, display: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = interactive
        panel.ignoresMouseEvents = !interactive
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    private func showFlight(image: CGImage, screen: NSScreen, target: CGRect) {
        let panel = makePanel(frame: screen.frame, interactive: false)
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        guard let root = view.layer else { return }
        panel.contentView = view
        self.panel = panel

        let bounds = view.bounds
        let scale = target.width / bounds.width
        let start = CGPoint(x: bounds.midX, y: bounds.midY)
        let end = CGPoint(x: target.midX - screen.frame.minX, y: target.midY - screen.frame.minY)
        let card = CALayer()
        card.bounds = bounds
        card.position = start
        card.backgroundColor = theme.floating.cgColor
        card.shadowColor = NSColor.black.cgColor
        card.shadowOffset = CGSize(width: 0, height: -5 / scale)
        card.shadowOpacity = 0.24
        card.shadowRadius = 18 / scale
        card.cornerRadius = 14 / scale
        let photo = CALayer()
        photo.frame = bounds
        photo.contents = image
        photo.contentsGravity = .resize
        photo.masksToBounds = true
        photo.cornerRadius = 14 / scale
        photo.borderColor = theme.border.cgColor
        photo.borderWidth = 1 / scale
        card.addSublayer(photo)
        root.addSublayer(card)

        // Commit the final state first, so the animation never snaps back.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.position = end
        card.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
        let times: [NSNumber] = [0, 0.10, 0.28, 1]
        let ease = CAMediaTimingFunction(controlPoints: 0.22, 0.85, 0.25, 1)
        func keyframes(_ key: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values
            animation.keyTimes = times
            animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut), ease, ease]
            animation.duration = 0.72
            return animation
        }
        card.add(keyframes("position", [
            NSValue(point: start), NSValue(point: start), NSValue(point: CGPoint(x: start.x, y: start.y + 6)), NSValue(point: end),
        ]), forKey: "flight")
        card.add(keyframes("transform.scale", [1, 1, 0.96, scale]), forKey: "scale")
        card.add(keyframes("cornerRadius", [0, 0, 14, 14 / scale]), forKey: "corners")
        card.add(keyframes("shadowOpacity", [0, 0, 0.16, 0.24]), forKey: "shadow")
        photo.add(keyframes("cornerRadius", [0, 0, 14, 14 / scale]), forKey: "corners")
        photo.add(keyframes("borderWidth", [0, 0, 1, 1 / scale]), forKey: "border")

        let exposure = CALayer()
        exposure.frame = bounds
        exposure.backgroundColor = NSColor.white.cgColor
        exposure.opacity = 0
        root.addSublayer(exposure)
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0.0, 0.22, 0.0]
        flash.keyTimes = [0, 0.15, 1]
        flash.duration = 0.22
        exposure.add(flash, forKey: "exposure")
        panel.orderFrontRegardless()
    }

    private func showPreview(_ shot: QuickShot, frame: CGRect, fadeIn: Bool) {
        let panel = makePanel(frame: frame, interactive: true)
        let view = QuickShotPreviewView(image: shot.image, size: frame.size, fileURL: shot.url, background: theme.floating)
        view.onOpen = { [weak self] in self?.dismiss() }
        view.onExit = { [weak self] in self?.scheduleFadeOut(after: 800_000_000) }
        panel.contentView = view
        self.panel = panel
        panel.alphaValue = fadeIn ? 0 : 1
        panel.orderFrontRegardless()
        if fadeIn {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: "Screenshot saved and copied.",
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }
}

@MainActor
private final class QuickShotPreviewView: NSView {
    private let fileURL: URL
    var onOpen: (() -> Void)?
    var onExit: (() -> Void)?
    private(set) var isHovered = false

    init(image: CGImage, size: CGSize, fileURL: URL, background: NSColor) {
        self.fileURL = fileURL
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.backgroundColor = background.cgColor
        let photo = NSButton(frame: bounds)
        photo.isBordered = false
        photo.image = NSImage(cgImage: image, size: size)
        photo.imageScaling = .scaleAxesIndependently
        photo.imagePosition = .imageOnly
        photo.target = self
        photo.action = #selector(openImage)
        photo.toolTip = "Open screenshot"
        photo.setAccessibilityLabel("Open captured screenshot")
        addSubview(photo)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onExit?()
    }

    @objc private func openImage() {
        NSWorkspace.shared.open(fileURL)
        onOpen?()
    }
}
