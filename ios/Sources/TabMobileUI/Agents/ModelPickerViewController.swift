import TabMobileKit
import TabProtocol
import UIKit

/// The composer's model picker, in a sheet: each agent's models with the
/// chosen one checked, locked to the conversation's agent once it has
/// started, then the reasoning effort on a slider and plan mode.
final class ModelPickerViewController: UITableViewController {
    private let controller: AgentChatController
    private let effortCell = EffortCell()
    private let planSwitch = UISwitch()
    private var rows: [Row] = []
    private var showsEffort = false

    /// One row of the models section: a model, or a note while an agent's
    /// models are loading or missing.
    private struct Row: Hashable {
        var provider: AgentChatProvider
        var model: AgentModelDescriptor?
        var note: String?
        var locked: Bool
    }

    private enum Section: Int, CaseIterable { case models, options }

    init(controller: AgentChatController) {
        self.controller = controller
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The picker in a navigation controller, as a sheet that starts at half
    /// the screen.
    func inSheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Select Model"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "model")
        effortCell.slider.addAction(UIAction { [weak self] _ in self?.effortChanged() }, for: .valueChanged)
        planSwitch.addAction(UIAction { [weak self] _ in self?.controller.togglePlanMode() }, for: .valueChanged)
    }

    // MARK: Updates

    override func updateProperties() {
        super.updateProperties()
        let selection = controller.selection
        let current = controller.effectiveModel
        let next = AgentChatProvider.allCases.flatMap { provider -> [Row] in
            let locked = !controller.canChangeProvider && provider != controller.snapshot?.provider
            guard let models = controller.models[provider], !models.isEmpty else {
                let note = controller.models[provider] == nil ? "Loading models…" : "No models reported"
                return [Row(provider: provider, note: note, locked: locked)]
            }
            return models.map { Row(provider: provider, model: $0, locked: locked) }
        }
        let efforts = controller.selectedModel?.reasoningEfforts ?? []
        let sections = next != rows || showsEffort != !efforts.isEmpty
        rows = next
        showsEffort = !efforts.isEmpty

        effortCell.show(efforts: efforts, chosen: controller.effort, default: controller.selectedModel?.defaultReasoningEffort)
        let free = controller.status == .idle || controller.status == .failed
        planSwitch.isEnabled = free
        if planSwitch.isOn != controller.planMode { planSwitch.setOn(controller.planMode, animated: viewIfLoaded?.window != nil) }

        if sections {
            tableView.reloadData()
            return
        }
        // Only the check moved: the slider keeps tracking a finger mid-drag.
        let checked = tableView.indexPathsForVisibleRows?.filter { $0.section == Section.models.rawValue } ?? []
        for path in checked {
            let row = rows[path.row]
            let on = row.provider == selection.provider && row.model?.id == current
            tableView.cellForRow(at: path)?.accessoryType = on ? .checkmark : .none
        }
        if let plan = tableView.cellForRow(at: IndexPath(row: showsEffort ? 1 : 0, section: Section.options.rawValue)) {
            configurePlan(plan, free: free)
        }
    }

    private func effortChanged() {
        controller.select(effort: effortCell.effort)
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .models: rows.count
        case .options: showsEffort ? 2 : 1
        case nil: 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section) == .models, let locked = rows.first(where: \.locked) else { return nil }
        return "This conversation stays with \(controller.selection.provider.name). Open a new agent pane to use \(locked.provider.name)."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if Section(rawValue: indexPath.section) == .options {
            if showsEffort && indexPath.row == 0 { return effortCell }
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.accessoryView = planSwitch
            configurePlan(cell, free: planSwitch.isEnabled)
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "model", for: indexPath)
        let row = rows[indexPath.row]
        var content = UIListContentConfiguration.cell()
        content.image = AgentLogo.image(row.provider, side: 22, scale: TabIcon.inlineScale)
        content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
        content.text = row.model?.title ?? row.note
        let enabled = row.model != nil && !row.locked
        content.textProperties.color = row.model == nil ? .secondaryLabel : enabled ? .label : .tertiaryLabel
        content.imageProperties.tintColor = nil
        cell.contentConfiguration = content
        cell.contentView.alpha = row.locked ? 0.5 : 1
        let on = row.provider == controller.selection.provider && row.model?.id == controller.effectiveModel
        cell.accessoryType = on ? .checkmark : .none
        cell.selectionStyle = enabled ? .default : .none
        cell.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        return cell
    }

    private func configurePlan(_ cell: UITableViewCell, free: Bool) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = "Plan Mode"
        content.secondaryText = free ? "Plans before changing anything" : "Changes after the current response"
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard Section(rawValue: indexPath.section) == .models else { return false }
        let row = rows[indexPath.row]
        return row.model != nil && !row.locked
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows[indexPath.row]
        guard let model = row.model, !row.locked else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        controller.select(provider: row.provider, model: model.id)
    }
}

/// "Effort" and the chosen level above a slider with a stop per level, Auto
/// first.
private final class EffortCell: UITableViewCell {
    let slider = EffortSlider()
    private let valueLabel = UILabel()
    private var efforts: [AgentReasoningEffort] = []
    private var defaultEffort: AgentReasoningEffort?

    /// The chosen level; nil is Auto, the model's default.
    var effort: AgentReasoningEffort? {
        slider.value == 0 ? nil : efforts[slider.value - 1]
    }

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        let title = UILabel()
        title.text = "Effort"
        title.font = .preferredFont(forTextStyle: .body)
        title.adjustsFontForContentSizeCategory = true
        valueLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = .secondaryLabel
        valueLabel.textAlignment = .right
        let top = UIStackView(arrangedSubviews: [title, valueLabel])
        top.spacing = 8
        let stack = UIStackView(arrangedSubviews: [top, slider])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            slider.heightAnchor.constraint(equalToConstant: EffortSlider.height),
        ])
        slider.addAction(UIAction { [weak self] _ in self?.refreshValue() }, for: .valueChanged)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(efforts: [AgentReasoningEffort], chosen: AgentReasoningEffort?, default: AgentReasoningEffort?) {
        self.efforts = efforts
        defaultEffort = `default`
        slider.labels = ["Auto"] + efforts.map(\.title)
        if !slider.isTracking {
            slider.value = chosen.flatMap { efforts.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        }
        refreshValue()
    }

    private func refreshValue() {
        // Auto names the level it stands for.
        valueLabel.text = effort?.title ?? defaultEffort.map { "Auto · \($0.title)" } ?? "Auto"
    }
}

/// A slider that stops at each of its labels: a capsule track whose filled
/// part runs from warm to cool as the level rises, a dot per stop and a
/// white thumb.
private final class EffortSlider: UIControl {
    static let height: CGFloat = 32
    private static let thumbInset: CGFloat = 2

    var labels: [String] = [] {
        didSet {
            guard labels != oldValue else { return }
            value = min(value, max(labels.count - 1, 0))
            setNeedsLayout()
        }
    }
    var value = 0 {
        didSet {
            guard value != oldValue else { return }
            setNeedsLayout()
            accessibilityValue = labels.indices.contains(value) ? labels[value] : nil
        }
    }

    private let track = UIView()
    /// Clips the gradient to the filled part, so the fill follows the thumb
    /// in the same animation.
    private let fill = UIView()
    private let gradient = GradientView()
    private var dots: [CALayer] = []
    private let thumb = UIView()
    private var dragging = false

    override var isTracking: Bool { dragging }

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.backgroundColor = .tertiarySystemFill
        track.isUserInteractionEnabled = false
        track.layer.cornerCurve = .continuous
        addSubview(track)
        fill.clipsToBounds = true
        fill.layer.cornerCurve = .continuous
        fill.addSubview(gradient)
        track.addSubview(fill)
        thumb.backgroundColor = .white
        thumb.isUserInteractionEnabled = false
        thumb.layer.shadowColor = UIColor.black.cgColor
        thumb.layer.shadowOpacity = 0.2
        thumb.layer.shadowRadius = 3
        thumb.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(thumb)
        isAccessibilityElement = true
        accessibilityLabel = "Effort"
        accessibilityTraits = .adjustable
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged)))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.setNeedsLayout() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var thumbSide: CGFloat { bounds.height - 2 * Self.thumbInset }

    /// The thumb's center at each stop, from the first to the last.
    private func center(of stop: Int) -> CGFloat {
        let first = Self.thumbInset + thumbSide / 2
        let last = bounds.width - first
        guard labels.count > 1 else { return first }
        return first + (last - first) * CGFloat(stop) / CGFloat(labels.count - 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.layer.cornerRadius = bounds.height / 2
        gradient.frame = track.bounds
        gradient.colors = [UIColor(white: 0.95, alpha: 1), .systemYellow, .systemGreen, .systemBlue, .systemPurple, .systemPink]
            .map { $0.resolvedColor(with: traitCollection).cgColor }
        let thumbCenter = center(of: value)

        while dots.count < labels.count {
            let dot = CALayer()
            track.layer.addSublayer(dot)
            dots.append(dot)
        }
        while dots.count > labels.count { dots.removeLast().removeFromSuperlayer() }
        for (stop, dot) in dots.enumerated() {
            let side: CGFloat = 4
            dot.frame = CGRect(x: center(of: stop) - side / 2, y: (bounds.height - side) / 2, width: side, height: side)
            dot.cornerRadius = side / 2
            let color: UIColor = stop <= value ? .black.withAlphaComponent(0.25) : .tertiaryLabel
            dot.backgroundColor = color.resolvedColor(with: traitCollection).cgColor
        }
        CATransaction.commit()
        fill.frame = CGRect(x: 0, y: 0, width: thumbCenter + thumbSide / 2 + Self.thumbInset, height: bounds.height)
        fill.layer.cornerRadius = bounds.height / 2
        thumb.bounds = CGRect(x: 0, y: 0, width: thumbSide, height: thumbSide)
        thumb.layer.cornerRadius = thumbSide / 2
        thumb.center = CGPoint(x: thumbCenter, y: bounds.midY)
    }

    /// The stop nearest `x`.
    private func stop(at x: CGFloat) -> Int {
        guard labels.count > 1 else { return 0 }
        let first = center(of: 0)
        let step = (center(of: labels.count - 1) - first) / CGFloat(labels.count - 1)
        return min(max(Int(((x - first) / step).rounded()), 0), labels.count - 1)
    }

    private func move(to stop: Int, animated: Bool) {
        guard stop != value else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        value = stop
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                self.layoutIfNeeded()
            }
        } else {
            layoutIfNeeded()
        }
        sendActions(for: .valueChanged)
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            dragging = true
            move(to: stop(at: gesture.location(in: self).x), animated: true)
        default:
            dragging = false
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        move(to: stop(at: gesture.location(in: self).x), animated: true)
    }

    override func accessibilityIncrement() { move(to: min(value + 1, labels.count - 1), animated: true) }
    override func accessibilityDecrement() { move(to: max(value - 1, 0), animated: true) }
}

/// A left-to-right gradient as a view's own layer.
private final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    var colors: [CGColor] {
        get { (layer as? CAGradientLayer)?.colors as? [CGColor] ?? [] }
        set { (layer as? CAGradientLayer)?.colors = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        (layer as? CAGradientLayer)?.startPoint = CGPoint(x: 0, y: 0.5)
        (layer as? CAGradientLayer)?.endPoint = CGPoint(x: 1, y: 0.5)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
