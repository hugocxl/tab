import TabMobileKit
import TabProtocol
import UIKit

/// A card's status glyph, as the desktop sidebar draws it: an accent dot for
/// attention, red for an error, orange when paused, and six pulsing dots
/// while work runs. The pulse is a render-server animation; it costs no redraws.
final class ActivityGlyphView: UIView {
    enum Style: Equatable {
        case none
        case dot(UIColor)
        case dots(UIColor)
    }

    var style: Style = .none {
        didSet { if style != oldValue { apply() } }
    }

    private var dots: [CAShapeLayer] = []
    private let dot = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(dot)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: 12, height: 12) }

    override func layoutSubviews() {
        super.layoutSubviews()
        apply()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        dots.forEach { $0.removeFromSuperlayer() }
        dots = []
        dot.path = nil
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        switch style {
        case .none:
            break
        case .dot(let color):
            dot.path = CGPath(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8), transform: nil)
            dot.fillColor = color.resolvedColor(with: traitCollection).cgColor
        case .dots(let color):
            let fill = color.resolvedColor(with: traitCollection).cgColor
            let diameter: CGFloat = 2.5
            for index in 0..<6 {
                let layer = CAShapeLayer()
                let x = center.x + (CGFloat(index % 2) - 0.5) * 4
                let y = center.y + (CGFloat(index / 2) - 1) * 4
                layer.path = CGPath(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter,
                                                      height: diameter), transform: nil)
                layer.fillColor = fill
                layer.opacity = 0.35
                self.layer.addSublayer(layer)
                dots.append(layer)
                guard window != nil, !UIAccessibility.isReduceMotionEnabled else { continue }
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values = [0.35, 1, 0.35]
                pulse.duration = 1
                pulse.beginTime = CACurrentMediaTime() + Double(index) / 6
                pulse.repeatCount = .infinity
                layer.add(pulse, forKey: "pulse")
            }
        }
    }
}

/// The PRIMARY badge of a repository's own checkout.
final class PrimaryBadge: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        attributedText = NSAttributedString(string: "PRIMARY", attributes: [
            .font: UIFont.systemFont(ofSize: 9, weight: .semibold), .kern: 0.6,
        ])
        textColor = .secondaryLabel
        textAlignment = .center
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 7
        layer.masksToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 12, height: 14)
    }
}

/// A tab card, as the desktop sidebar draws one in its Open Tabs layout:
///
///     [logo] task or command
///     name  branch  ← base  ↑3  PRIMARY    4m ⠿
///     [icon] project
final class TabCardCell: UICollectionViewListCell {
    private let lead = UIImageView()
    private let chip = UIView()
    private let chipSymbol = UIImageView()
    private let shellLabel = UILabel()
    private let headline = UILabel()
    private let nameLabel = UILabel()
    private let branchLabel = UILabel()
    private let baseLabel = UILabel()
    private let aheadLabel = UILabel()
    private let primary = PrimaryBadge()
    private let elapsed = UILabel()
    private let glyph = ActivityGlyphView()
    private let projectIcon = UIImageView()
    private let projectLabel = UILabel()
    private var workingSince: Date?
    private var elapsedTimer: Timer?
    private var shownIcon: Data?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let footnote = UIFont.preferredFont(forTextStyle: .footnote)
        for label in [nameLabel, branchLabel, baseLabel, aheadLabel, projectLabel] {
            label.font = footnote
            label.adjustsFontForContentSizeCategory = true
        }
        nameLabel.textColor = .secondaryLabel
        branchLabel.textColor = .tertiaryLabel
        baseLabel.textColor = .tertiaryLabel
        aheadLabel.textColor = .secondaryLabel
        projectLabel.textColor = .tertiaryLabel
        branchLabel.lineBreakMode = .byTruncatingMiddle
        elapsed.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular))
        elapsed.textColor = .tintColor
        elapsed.setContentHuggingPriority(.required, for: .horizontal)
        elapsed.setContentCompressionResistancePriority(.required, for: .horizontal)
        headline.font = .preferredFont(forTextStyle: .body)
        headline.adjustsFontForContentSizeCategory = true
        shellLabel.font = .preferredFont(forTextStyle: .body)
        shellLabel.textColor = .secondaryLabel
        shellLabel.setContentHuggingPriority(.required, for: .horizontal)
        shellLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for label in [nameLabel, aheadLabel] {
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }

        lead.contentMode = .scaleAspectFit
        chip.layer.cornerRadius = 6
        chip.layer.cornerCurve = .continuous
        chip.layer.borderWidth = 1
        chip.backgroundColor = .secondarySystemFill
        chipSymbol.contentMode = .center
        chipSymbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chipSymbol.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chipSymbol)
        projectIcon.contentMode = .scaleAspectFit
        projectIcon.tintColor = .tertiaryLabel
        projectIcon.layer.cornerRadius = 3
        projectIcon.layer.cornerCurve = .continuous
        projectIcon.clipsToBounds = true

        let leadBox = UIView()
        for view in [lead, chip] {
            view.translatesAutoresizingMaskIntoConstraints = false
            leadBox.addSubview(view)
        }
        let line1 = UIStackView(arrangedSubviews: [leadBox, shellLabel, headline])
        line1.spacing = 8
        line1.alignment = .center
        let line2 = UIStackView(arrangedSubviews: [nameLabel, branchLabel, baseLabel, aheadLabel, primary, UIView(), elapsed, glyph])
        line2.spacing = 6
        line2.alignment = .center
        line2.setCustomSpacing(5, after: elapsed)
        let line3 = UIStackView(arrangedSubviews: [projectIcon, projectLabel])
        line3.spacing = 8
        line3.alignment = .center
        let stack = UIStackView(arrangedSubviews: [line1, line2, line3])
        stack.axis = .vertical
        stack.spacing = 4
        stack.setCustomSpacing(6, after: line2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            leadBox.widthAnchor.constraint(equalToConstant: 22),
            leadBox.heightAnchor.constraint(equalToConstant: 22),
            lead.topAnchor.constraint(equalTo: leadBox.topAnchor, constant: 1),
            lead.bottomAnchor.constraint(equalTo: leadBox.bottomAnchor, constant: -1),
            lead.leadingAnchor.constraint(equalTo: leadBox.leadingAnchor, constant: 1),
            lead.trailingAnchor.constraint(equalTo: leadBox.trailingAnchor, constant: -1),
            chip.topAnchor.constraint(equalTo: leadBox.topAnchor),
            chip.bottomAnchor.constraint(equalTo: leadBox.bottomAnchor),
            chip.leadingAnchor.constraint(equalTo: leadBox.leadingAnchor),
            chip.trailingAnchor.constraint(equalTo: leadBox.trailingAnchor),
            chipSymbol.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            chipSymbol.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 12),
            glyph.heightAnchor.constraint(equalToConstant: 12),
            projectIcon.widthAnchor.constraint(equalToConstant: 16),
            projectIcon.heightAnchor.constraint(equalToConstant: 16),
            projectIcon.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 3),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
        line3.isLayoutMarginsRelativeArrangement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.chip.layer.borderColor = UIColor.separator.resolvedColor(with: self.traitCollection).cgColor
        }
    }

    func configure(_ card: TabCard, icon: UIImage?) {
        switch card.headline {
        case let .agent(provider, task):
            showLogo(provider)
            shellLabel.isHidden = true
            headline.text = task ?? provider.displayName
            headline.textColor = task == nil ? .secondaryLabel : .label
            headline.font = Self.font(task == nil ? .regular : .medium)
        case let .shell(name, directory):
            showChip("terminal", color: .systemGreen)
            shellLabel.isHidden = false
            shellLabel.text = name
            headline.text = directory ?? ""
            headline.textColor = .tertiaryLabel
            headline.font = Self.font(.regular)
        case .command(let command):
            showChip("terminal", color: .label)
            shellLabel.isHidden = true
            headline.text = command
            headline.textColor = .label
            headline.font = Self.font(.semibold)
        case .other(let title):
            showChip("macwindow", color: .label)
            shellLabel.isHidden = true
            headline.text = title
            headline.textColor = .label
            headline.font = Self.font(.semibold)
        case .empty:
            showChip("terminal", color: .tertiaryLabel)
            shellLabel.isHidden = true
            headline.text = "No terminal"
            headline.textColor = .tertiaryLabel
            headline.font = Self.font(.regular)
        }

        nameLabel.text = card.name
        branchLabel.text = card.branch
        branchLabel.isHidden = card.branch == nil
        baseLabel.text = card.base.map { "← \($0)" }
        baseLabel.isHidden = card.base == nil
        let ahead = card.baseAhead ?? 0
        aheadLabel.text = ahead > 0 ? "↑\(ahead)" : nil
        aheadLabel.isHidden = ahead == 0
        primary.isHidden = !card.primary

        switch card.status {
        case .idle: glyph.style = .none
        case .working: glyph.style = .dots(.tintColor)
        case .attention: glyph.style = .dot(.tintColor)
        case .error: glyph.style = .dot(.systemRed)
        case .paused: glyph.style = .dot(.systemOrange)
        }
        glyph.isHidden = card.status == .idle
        workingSince = card.status == .working ? card.workingSince : nil
        updateElapsed()

        projectLabel.text = card.header
        projectIcon.image = icon ?? UIImage(systemName: card.iconProject == nil ? "laptopcomputer" : "folder")
        projectIcon.layer.cornerRadius = icon == nil ? 0 : 3

        var parts = [card.name, card.branch, card.primary ? "primary" : nil, card.header]
        parts.insert(headline.text, at: 0)
        switch card.status {
        case .working: parts.append("working")
        case .attention: parts.append("needs attention")
        case .error: parts.append("failed")
        case .paused: parts.append("paused")
        case .idle: break
        }
        accessibilityLabel = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func font(_ weight: UIFont.Weight) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: weight))
    }

    private func showLogo(_ provider: AgentProvider) {
        let image: UIImage?
        switch provider {
        case .claude: image = AgentLogo.image(.claude)
        case .codex: image = AgentLogo.image(.codex)
        default: image = nil
        }
        lead.image = image ?? UIImage(systemName: "sparkles")
        lead.tintColor = .label
        lead.isHidden = false
        chip.isHidden = true
    }

    private func showChip(_ symbol: String, color: UIColor) {
        chipSymbol.image = UIImage(systemName: symbol)
        chipSymbol.tintColor = color
        chip.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        chip.isHidden = false
        lead.isHidden = true
    }

    /// Shows the turn's running time, with one timer for when the text next changes.
    private func updateElapsed() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        guard let since = workingSince, window != nil else {
            elapsed.isHidden = workingSince == nil
            return
        }
        let seconds = Date().timeIntervalSince(since)
        elapsed.isHidden = false
        elapsed.text = ServerModel.elapsedText(seconds)
        let timer = Timer(timeInterval: ServerModel.secondsUntilElapsedChanges(seconds) + 0.01, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateElapsed() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateElapsed()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    /// The selected card sits on glass, as on the desktop.
    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.clear()
        background.cornerRadius = 18
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
        if state.isSelected || state.isHighlighted {
            background.customView = GlassBackground.shared(for: self)
            background.backgroundColor = state.isHighlighted && !state.isSelected ? .systemFill : .clear
        }
        backgroundConfiguration = background
    }
}

/// A glass view per cell for its selected background.
@MainActor
enum GlassBackground {
    private static var views: [ObjectIdentifier: UIVisualEffectView] = [:]

    static func shared(for cell: UICollectionViewCell) -> UIVisualEffectView {
        let key = ObjectIdentifier(cell)
        if let view = views[key] { return view }
        let view = UIVisualEffectView(effect: UIGlassEffect())
        view.cornerConfiguration = .uniformCorners(radius: .fixed(18))
        views[key] = view
        return view
    }
}
