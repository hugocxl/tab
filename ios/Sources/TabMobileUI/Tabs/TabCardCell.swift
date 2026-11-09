import TabMobileKit
import TabProtocol
import UIKit

/// The colors and sizes the desktop sidebar's cards use, at the phone's scale.
enum CardStyle {
    /// Every leading icon's box: the panes' statuses and kinds, the
    /// location's and the project's icons.
    static let iconSide: CGFloat = 18
    /// Where text after a leading icon starts.
    static let textInset: CGFloat = iconSide + 8

    static func font(_ style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }

    /// One of Pierre's icons in its palette color: the deeper shade on light
    /// backgrounds, the lighter one on dark.
    enum Pierre: String {
        case bash = "PierreBash"
        case folder = "PierreFolder"
        case git = "PierreGit"

        var color: UIColor {
            let (light, dark): (UInt32, UInt32) = switch self {
            case .bash: (0x199f43, 0x5ecc71)
            case .folder: (0x1a85d4, 0x69b1ff)
            case .git: (0xd5512f, 0xff8c5b)
            }
            return UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
        }

        var image: UIImage? { UIImage(named: rawValue)?.withTintColor(color, renderingMode: .alwaysOriginal) }
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

/// A pane's status as an SF Symbol, as the desktop draws it: a spinner while
/// working, a filled circle when waiting for you, done, failed or paused, and
/// an empty one, or nothing, while idle.
final class PaneStatusView: UIImageView {
    var status: CardPane.Status = .idle {
        didSet { if status != oldValue { apply() } }
    }
    /// Draws an empty circle while idle.
    var showsIdle = false {
        didSet { if showsIdle != oldValue { apply() } }
    }
    /// Draws the spinner in muted gray rather than the accent.
    var grayWorking = false {
        didSet { if grayWorking != oldValue { apply() } }
    }
    var side = CardStyle.iconSide {
        didSet { if side != oldValue { apply() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .center
        isAccessibilityElement = false
        apply()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private func apply() {
        let (name, color): (String?, UIColor) = switch status {
        case .working, .progress: ("progress.indicator", grayWorking ? .secondaryLabel : .tintColor)
        case .blocked: ("exclamationmark.circle.fill", .tintColor)
        case .done: ("checkmark.circle.fill", .systemGreen)
        case .error: ("xmark.circle.fill", .systemRed)
        case .paused: ("pause.circle.fill", .systemOrange)
        case .idle: (showsIdle ? "circle" : nil, .tertiaryLabel)
        }
        removeAllSymbolEffects()
        preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: side * 0.8, weight: .semibold)
        image = name.flatMap { UIImage(systemName: $0) }
        tintColor = color
        guard name == "progress.indicator", window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        addSymbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
    }
}

/// One pane in a card's list: what it is doing, or its kind or agent while it
/// is idle, then its title, folder and how long it has worked. As a card's
/// title its icon is larger.
final class PaneRowView: UIView {
    /// The title's icon box, as tall as the title's text.
    static let titleIconSide: CGFloat = 22

    private(set) var row: CardPane?
    private let status = PaneStatusView(frame: .zero)
    private let icon = UIImageView()
    let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let elapsedLabel = UILabel()
    private var lineCenter: NSLayoutConstraint?
    private var iconConstraints: [NSLayoutConstraint] = []

    /// The running time of the pane's turn, which the card keeps current.
    var elapsed = "" {
        didSet {
            elapsedLabel.text = elapsed
            elapsedLabel.isHidden = elapsed.isEmpty
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        detailLabel.textColor = .tertiaryLabel
        elapsedLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular))
        elapsedLabel.textColor = .tertiaryLabel
        for label in [titleLabel, detailLabel, elapsedLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        // The folder follows the title, which gives up space first while the
        // folder keeps at least its share.
        titleLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(.defaultLow + 3, for: .horizontal)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        for view in [status, icon, titleLabel, detailLabel, elapsedLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let detailShare = detailLabel.widthAnchor.constraint(greaterThanOrEqualTo: widthAnchor, multiplier: 0.4)
        detailShare.priority = .defaultLow + 2
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: status.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            icon.widthAnchor.constraint(equalTo: status.widthAnchor),
            icon.heightAnchor.constraint(equalTo: status.heightAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardStyle.textInset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 5),
            detailLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            detailShare,
            elapsedLabel.leadingAnchor.constraint(greaterThanOrEqualTo: detailLabel.trailingAnchor, constant: 6),
            elapsedLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
            elapsedLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            elapsedLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `row`; `title` replaces its text when the row is its card's
    /// title. `idleCircle` shows an empty circle instead of the pane's icon
    /// while it is idle.
    func configure(_ row: CardPane, title: String? = nil, idleCircle: Bool = false) {
        self.row = row
        let isTitle = title != nil
        let font = isTitle ? CardStyle.font(.body, size: 17) : CardStyle.font(.subheadline, size: 15)
        titleLabel.text = title ?? row.title
        titleLabel.font = font
        titleLabel.textColor = isTitle ? .label : .secondaryLabel
        detailLabel.text = row.detail
        detailLabel.font = font
        detailLabel.isHidden = row.detail == nil
        // A folder after the title keeps it to one line.
        titleLabel.numberOfLines = isTitle && detailLabel.isHidden ? 2 : 1
        elapsed = ""

        // Centered on the list's icon column, so a larger title icon reaches
        // into the card's padding and the text still lines up.
        let side = isTitle ? Self.titleIconSide : CardStyle.iconSide
        NSLayoutConstraint.deactivate(iconConstraints)
        iconConstraints = [
            status.centerXAnchor.constraint(equalTo: leadingAnchor, constant: CardStyle.iconSide / 2),
            status.widthAnchor.constraint(equalToConstant: side),
            status.heightAnchor.constraint(equalToConstant: side),
        ]
        NSLayoutConstraint.activate(iconConstraints)
        status.side = side
        status.showsIdle = idleCircle
        // The list's spinners stay gray beside its colored icons.
        status.grayWorking = !isTitle
        status.status = row.status
        // A status takes the icon's place.
        icon.isHidden = row.status != .idle || idleCircle
        icon.image = Self.image(row.icon)
        icon.tintColor = .secondaryLabel
        icon.layer.cornerRadius = side * 3 / 14
        // Everything lines up with the first line when a title wraps.
        lineCenter?.isActive = false
        lineCenter = status.centerYAnchor.constraint(equalTo: titleLabel.topAnchor, constant: (font.lineHeight / 2).rounded())
        lineCenter?.isActive = true
    }

    private static func image(_ icon: CardPane.Icon) -> UIImage? {
        switch icon {
        case .terminal: CardStyle.Pierre.bash.image
        case .agent(let provider): AgentLogo.image(provider) ?? UIImage(systemName: "sparkles")
        case .simulator: UIImage(systemName: "iphone")
        case .browser: UIImage(systemName: "globe")
        case .file: UIImage(systemName: "doc.text")
        }
    }
}

/// A row of the card's footer: the location or the project, its icon in the
/// first column and its text in the second.
final class CardFooterRow: UIView {
    let icon = UIImageView()
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 3
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        label.font = CardStyle.font(.footnote, size: 13)
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byTruncatingTail
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: CardStyle.iconSide),
            icon.heightAnchor.constraint(equalToConstant: CardStyle.iconSide),
            icon.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardStyle.textInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A tab card, as the desktop sidebar draws one in its Open Tabs layout:
///
///     [lead] What the tab is about, on up to two lines
///     [icon] each pane ~/folder        3m
///     [git]  name · branch · ← base ↑3 · primary
///     [icon] project
///
/// The title row is led by the lead pane's icon or status; a card's only
/// pane is its title row instead of a list.
final class TabCardCell: UICollectionViewListCell {
    private let titleLabel = UILabel()
    private let titleRow = PaneRowView()
    private let paneStack = UIStackView()
    private let location = CardFooterRow()
    private let project = CardFooterRow()
    private let stack = UIStackView()
    private var elapsedTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        titleLabel.font = CardStyle.font(.body, size: 17)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        titleLabel.textColor = .label
        paneStack.axis = .vertical
        let footer = UIStackView(arrangedSubviews: [location, project])
        footer.axis = .vertical
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(titleRow)
        stack.addArrangedSubview(paneStack)
        stack.addArrangedSubview(footer)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
    }

    /// Shows `card`. The list applies its snapshots animated, but a card's
    /// rows change at once: a stack view's row hidden and shown again inside
    /// an animation can stay collapsed.
    func configure(_ card: TabCard, icon: UIImage?) {
        UIView.performWithoutAnimation { show(card, icon: icon) }
    }

    private func show(_ card: TabCard, icon: UIImage?) {
        let lead = card.lead
        titleLabel.text = card.title
        titleLabel.setShown(lead == nil)
        titleRow.setShown(lead != nil)
        // With several panes no one pane stands for the card while they idle.
        if let lead { titleRow.configure(lead, title: card.title, idleCircle: card.rows.count > 1) }

        // A lone pane is what the title row already describes.
        let rows = card.rows.count > 1 ? card.rows : []
        while paneStack.arrangedSubviews.count > rows.count {
            paneStack.arrangedSubviews.last?.removeFromSuperview()
        }
        while paneStack.arrangedSubviews.count < rows.count {
            paneStack.addArrangedSubview(PaneRowView())
        }
        for (view, row) in zip(paneStack.arrangedSubviews.compactMap { $0 as? PaneRowView }, rows) {
            view.configure(row)
        }
        paneStack.setShown(!rows.isEmpty)

        // Skip a name the title or the project row already shows.
        let name = card.location.flatMap { $0 == card.projectName || $0 == card.title ? nil : $0 }
        let parts = locationParts(card, name: name)
        location.setShown(parts.length > 0)
        location.label.attributedText = parts
        let git = card.branch != nil || card.base != nil || card.primary
        location.icon.image = (git ? CardStyle.Pierre.git : CardStyle.Pierre.folder).image

        project.setShown(card.projectName != nil)
        project.label.text = card.projectName
        project.label.textColor = .secondaryLabel
        project.icon.image = icon ?? CardStyle.Pierre.folder.image

        updateElapsed()
        let statuses = card.rows.map { "\($0.title) \(Self.describe($0.status))" }
        accessibilityLabel = ([card.title, name, card.branch, card.primary ? "primary" : nil, card.projectName] + statuses)
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// `name · branch · ← base ↑3 · primary`, names muted and the rest dimmer.
    private func locationParts(_ card: TabCard, name: String?) -> NSAttributedString {
        var parts: [(String, UIColor)] = []
        if let name { parts.append((name, .secondaryLabel)) }
        if let branch = card.branch { parts.append((branch, .secondaryLabel)) }
        if let base = card.base {
            let ahead = card.baseAhead.flatMap { $0 > 0 ? " ↑\($0)" : nil } ?? ""
            parts.append(("← \(base)\(ahead)", .tertiaryLabel))
        }
        if card.primary { parts.append(("primary", .tertiaryLabel)) }
        let text = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: UIColor.tertiaryLabel])) }
            text.append(NSAttributedString(string: part.0, attributes: [.foregroundColor: part.1]))
        }
        return text
    }

    private static func describe(_ status: CardPane.Status) -> String {
        switch status {
        case .idle: ""
        case .working, .progress: "working"
        case .blocked: "needs attention"
        case .done: "done"
        case .error: "failed"
        case .paused: "paused"
        }
    }

    private var rowViews: [PaneRowView] {
        (titleRow.isHidden ? [] : [titleRow]) + paneStack.arrangedSubviews.compactMap { $0 as? PaneRowView }
    }

    /// Shows each working pane's running time, with one timer for when the
    /// next text changes.
    private func updateElapsed() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        guard window != nil else { return }
        let now = Date()
        var next: TimeInterval?
        for view in rowViews {
            guard let since = view.row?.workingSince else {
                view.elapsed = ""
                continue
            }
            let seconds = now.timeIntervalSince(since)
            view.elapsed = ServerModel.elapsedText(seconds)
            next = min(next ?? .infinity, ServerModel.secondsUntilElapsedChanges(seconds))
        }
        guard let next else { return }
        let timer = Timer(timeInterval: next + 0.01, repeats: false) { [weak self] _ in
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

    /// Cards sit flush with hairlines between them; the selected one is
    /// filled, as on the desktop.
    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.clear()
        background.cornerRadius = 12
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 0, leading: Self.cardInset, bottom: 0, trailing: Self.cardInset)
        if state.isSelected {
            background.backgroundColor = .secondarySystemFill
            background.strokeColor = .separator
            background.strokeWidth = 1 / max(traitCollection.displayScale, 1)
        } else if state.isHighlighted {
            background.backgroundColor = .tertiarySystemFill
        }
        backgroundConfiguration = background
    }

    /// The card's fill, and the hairlines between cards, keep this far from
    /// the list's edges.
    static let cardInset: CGFloat = 8
}

private extension UIView {
    /// Changes `isHidden` only when it differs: a stack view counts every
    /// change, so setting the same value again can leave an arranged view
    /// collapsed.
    func setShown(_ shown: Bool) {
        if isHidden == shown { isHidden = !shown }
    }
}

extension AgentLogo {
    /// The logo of an agent the activity reports, where the app has one.
    static func image(_ provider: AgentProvider) -> UIImage? {
        switch provider {
        case .claude: image(AgentChatProvider.claude)
        case .codex: image(AgentChatProvider.codex)
        default: nil
        }
    }
}
