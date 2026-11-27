import AppKit
import QuartzCore
import TabCore

/// Full-card loading view shown in the workspace as soon as a new worktree
/// creation starts, until the server finishes creating it and its tab opens.
final class WorktreeCreatingView: ThemedView {
    private let glass = GlassView(style: .pane)
    /// The sidebar toggle at the header position while the sidebar is collapsed.
    var leadingView: NSView? {
        didSet {
            guard leadingView !== oldValue else { return }
            if let oldValue, oldValue.superview === self { oldValue.removeFromSuperview() }
            if let leadingView { addSubview(leadingView) }
            needsLayout = true
        }
    }
    /// The right sidebar's toggle, at the top right while it is collapsed.
    var trailingView: NSView? {
        didSet {
            guard trailingView !== oldValue else { return }
            if let oldValue, oldValue.superview === self { oldValue.removeFromSuperview() }
            if let trailingView { addSubview(trailingView) }
            needsLayout = true
        }
    }

    private let loader = WorktreeOrbitView()
    private let titleLabel = makeLabel("", font: AppFont.system(15, weight: .semibold))
    private let metaLabel = makeLabel("", font: AppFont.small)
    private let statusLabel = makeLabel("", font: AppFont.small)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(glass)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cardRadius
        layer?.borderWidth = Metrics.border
        layer?.cornerCurve = .continuous

        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.alignment = .center
        metaLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.preferredMaxLayoutWidth = 380

        let textStack = NSStackView(views: [titleLabel, metaLabel, statusLabel])
        textStack.orientation = .vertical
        textStack.alignment = .centerX
        textStack.spacing = 6

        let stack = NSStackView(views: [loader, textStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            loader.widthAnchor.constraint(equalToConstant: WorktreeOrbitView.side),
            loader.heightAnchor.constraint(equalToConstant: WorktreeOrbitView.side),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ creation: WorktreeCreation, projectTitle: String?) {
        let heading = creation.name == WorktreeCreation.placeholderName
            ? "Creating worktree…"
            : "Creating “\(creation.name)”…"
        titleLabel.stringValue = heading

        var parts: [String] = []
        if let projectTitle, !projectTitle.isEmpty { parts.append(projectTitle) }
        if let pr = creation.pullRequest {
            parts.append("Pull Request #\(pr)")
        } else if let base = creation.base, !base.isEmpty {
            parts.append("from \(base)")
        } else if let branch = creation.branch, !branch.isEmpty, branch != creation.name {
            parts.append(branch)
        }
        metaLabel.stringValue = parts.joined(separator: " · ")
        metaLabel.isHidden = parts.isEmpty

        statusLabel.stringValue = creation.status
        statusLabel.isHidden = creation.status.isEmpty

        setAccessibilityLabel([heading, metaLabel.stringValue, creation.status].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    override var isHidden: Bool {
        didSet {
            if isHidden != oldValue { loader.active = !isHidden }
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override var redrawsOnKeyChange: Bool { true }

    override func updateLayer() {
        glass.isHidden = !theme.glassPanes
        glass.appearance = theme.nsAppearance
        glass.apply(theme.paneGlass(isKey: window?.isKeyWindow ?? true, isActive: true))
        layer?.backgroundColor = theme.paneBackground.cgColor
        layer?.borderWidth = theme.glassPanes ? 0 : Metrics.border
        layer?.borderColor = theme.cardBorder.cgColor
    }

    override func themeDidChange() {
        titleLabel.textColor = theme.fg
        metaLabel.textColor = theme.fgMuted
        statusLabel.textColor = theme.fgDim
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        if let leadingView {
            let size = leadingView.intrinsicContentSize
            leadingView.frame = CGRect(x: Metrics.gutter, y: ((Metrics.headerHeight - size.height) / 2).rounded(),
                                       width: size.width, height: size.height)
        }
        if let trailingView {
            let size = trailingView.intrinsicContentSize
            trailingView.frame = CGRect(x: bounds.width - Metrics.gutter - size.width,
                                        y: ((Metrics.headerHeight - size.height) / 2).rounded(),
                                        width: size.width, height: size.height)
        }
    }

    override func mouseDown(with event: NSEvent) {}
}

/// A GPU-animated orbital ring around a git-branch badge, costing zero CPU
/// redraws per frame and respecting Reduce Motion.
private final class WorktreeOrbitView: ThemedView {
    static let side: CGFloat = 76

    var active = true {
        didSet { if active != oldValue { updateAnimations() } }
    }

    private let halo = CAShapeLayer()
    private let badge = CAShapeLayer()
    private let track = CAShapeLayer()
    private let primaryOrbit = CALayer()
    private let primaryArc = CAShapeLayer()
    private let secondaryOrbit = CALayer()
    private let secondaryArc = CAShapeLayer()
    private let iconLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let root = layer else { return }

        root.addSublayer(halo)
        root.addSublayer(track)
        root.addSublayer(secondaryOrbit)
        secondaryOrbit.addSublayer(secondaryArc)
        root.addSublayer(primaryOrbit)
        primaryOrbit.addSublayer(primaryArc)
        root.addSublayer(badge)
        root.addSublayer(iconLayer)

        track.fillColor = nil
        track.lineWidth = 2

        primaryArc.fillColor = nil
        primaryArc.lineWidth = 2.25
        primaryArc.lineCap = .round

        secondaryArc.fillColor = nil
        secondaryArc.lineWidth = 1.5
        secondaryArc.lineCap = .round
        secondaryArc.strokeStart = 0
        secondaryArc.strokeEnd = 0.16

        badge.lineWidth = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyGeometry()
        applyColors()
        updateAnimations()
    }

    override func layout() {
        super.layout()
        applyGeometry()
    }

    override func themeDidChange() {
        applyColors()
    }

    private func applyGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let ringSide: CGFloat = 60
        let ringRect = CGRect(x: 0, y: 0, width: ringSide, height: ringSide)
        let ringPath = CGPath(ellipseIn: ringRect.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        let ringFrame = CGRect(x: center.x - ringSide / 2, y: center.y - ringSide / 2, width: ringSide, height: ringSide)

        halo.frame = bounds
        halo.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)

        track.frame = ringFrame
        track.path = ringPath

        primaryOrbit.frame = ringFrame
        primaryArc.frame = ringRect
        primaryArc.path = ringPath

        secondaryOrbit.frame = ringFrame
        secondaryArc.frame = ringRect
        secondaryArc.path = ringPath

        let badgeSide: CGFloat = 44
        let badgeRect = CGRect(x: center.x - badgeSide / 2, y: center.y - badgeSide / 2, width: badgeSide, height: badgeSide)
        badge.frame = badgeRect
        badge.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: badgeSide, height: badgeSide), transform: nil)

        let iconSide: CGFloat = 22
        iconLayer.frame = CGRect(x: center.x - iconSide / 2, y: center.y - iconSide / 2, width: iconSide, height: iconSide)
        iconLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        halo.fillColor = theme.accent.withAlphaComponent(0.08).cgColor
        badge.fillColor = theme.accent.withAlphaComponent(0.11).cgColor
        badge.strokeColor = theme.accent.withAlphaComponent(0.18).cgColor
        track.strokeColor = theme.fg(alpha: 0.08).cgColor
        primaryArc.strokeColor = theme.accent.cgColor
        secondaryArc.strokeColor = theme.accent.withAlphaComponent(0.32).cgColor
        iconLayer.contentsScale = window?.backingScaleFactor ?? 2
        iconLayer.contents = AppIcon.gitBranch.image(size: 22, color: theme.accent)
    }

    private func updateAnimations() {
        halo.removeAllAnimations()
        primaryOrbit.removeAllAnimations()
        primaryArc.removeAllAnimations()
        secondaryOrbit.removeAllAnimations()

        let shouldAnimate = active && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate else {
            primaryArc.strokeStart = 0
            primaryArc.strokeEnd = 0.34
            halo.opacity = 0.7
            return
        }

        // Smooth continuous rotation for the primary orbital arc.
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1.5
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        primaryOrbit.add(spin, forKey: "orbit")

        // Graceful breathing stretch-and-contract along the ring.
        let sweepEnd = CAKeyframeAnimation(keyPath: "strokeEnd")
        sweepEnd.values = [0.18, 0.62, 0.18]
        sweepEnd.keyTimes = [0, 0.5, 1]
        sweepEnd.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        sweepEnd.duration = 2.0
        sweepEnd.repeatCount = .infinity
        sweepEnd.isRemovedOnCompletion = false
        primaryArc.strokeStart = 0
        primaryArc.strokeEnd = 0.18
        primaryArc.add(sweepEnd, forKey: "sweep")

        // Slower counter-harmonic trailing arc for depth.
        let counterSpin = CABasicAnimation(keyPath: "transform.rotation.z")
        counterSpin.fromValue = Double.pi * 0.65
        counterSpin.toValue = Double.pi * 0.65 + 2 * Double.pi
        counterSpin.duration = 3.2
        counterSpin.repeatCount = .infinity
        counterSpin.isRemovedOnCompletion = false
        secondaryOrbit.add(counterSpin, forKey: "counterOrbit")

        // Soft ambient halo pulse behind the badge.
        let pulseOpacity = CAKeyframeAnimation(keyPath: "opacity")
        pulseOpacity.values = [0.35, 1.0, 0.35]
        pulseOpacity.keyTimes = [0, 0.5, 1]

        let pulseScale = CAKeyframeAnimation(keyPath: "transform.scale")
        pulseScale.values = [0.92, 1.05, 0.92]
        pulseScale.keyTimes = [0, 0.5, 1]

        let haloGroup = CAAnimationGroup()
        haloGroup.animations = [pulseOpacity, pulseScale]
        haloGroup.duration = 2.4
        haloGroup.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        haloGroup.repeatCount = .infinity
        haloGroup.isRemovedOnCompletion = false
        halo.add(haloGroup, forKey: "haloPulse")
    }
}
