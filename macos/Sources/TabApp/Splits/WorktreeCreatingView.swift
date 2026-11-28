import AppKit
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

    private let loader = ActivityGlyph()
    private static let loaderSide: CGFloat = 32
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
            loader.widthAnchor.constraint(equalToConstant: Self.loaderSide),
            loader.heightAnchor.constraint(equalToConstant: Self.loaderSide),
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
        loader.style = .spinner(theme.fgDim)
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
