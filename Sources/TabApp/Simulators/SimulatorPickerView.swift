import AppKit
import TabCore
import TabProtocol

/// A simulator the picker offers: an iOS simulator or an Android emulator on
/// the tab's server.
struct SimulatorChoice: Hashable, Sendable {
    var info: SimulatorInfo

    var platform: SimulatorPlatform { info.simulator.platform }
    var name: String { info.name }
    /// The OS it runs, such as "iOS 27.0" or "Android API 35".
    var runtime: String { info.runtime }
    var isRunning: Bool { info.booted }
    var isTablet: Bool { info.isTablet }

    var pane: SimulatorPane {
        platform == .iOS ? SimulatorPane(udid: info.simulator.id, name: name) : SimulatorPane(avd: info.simulator.id, name: name)
    }
}

/// The simulators to choose from: running ones first, then the most recently
/// used, each with its OS. It takes the keyboard: the arrows move the
/// selection and Return chooses it.
final class SimulatorPickerView: ThemedView {
    var onChoose: ((SimulatorChoice) -> Void)?

    private let titleLabel = makeLabel("Choose a Simulator", font: AppFont.system(15, weight: .semibold))
    private let detailLabel = makeLabel("It starts if it isn't running.", font: AppFont.body)
    private let card = Card()
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var simulators: [SimulatorChoice] = []
    private var rows: [ListRow] = []
    private var selected = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        list.orientation = .vertical
        list.alignment = .width
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let inset = NSView()
        inset.translatesAutoresizingMaskIntoConstraints = false
        inset.addSubview(list)
        list.pinEdges(to: inset, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        card.addRow(inset)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(card)
        card.pinEdges(to: document, insets: NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8))
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [titleLabel, detailLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(scroll)
        let width = header.widthAnchor.constraint(equalToConstant: 360)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            header.centerXAnchor.constraint(equalTo: centerXAnchor),
            width,
            header.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: -8),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the simulators of the tab's server; `host` names it when it is
    /// another computer. The selection stays on the same simulator across reloads.
    func show(_ simulators: [SimulatorChoice], host: String?) {
        let kept = self.simulators.indices.contains(selected) ? self.simulators[selected].info.simulator : nil
        self.simulators = simulators
        rows.forEach { $0.removeFromSuperview() }
        rows = simulators.enumerated().map { index, simulator in
            let row = Self.row(for: simulator)
            row.theme = theme
            row.onClick = { [weak self] in self?.choose(index) }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            return row
        }
        titleLabel.stringValue = host.map { "Choose a Simulator on \($0)" } ?? "Choose a Simulator"
        let place = host ?? "this Mac"
        detailLabel.stringValue = simulators.isEmpty
            ? "No simulators or emulators were found on \(place). Add iOS simulators in Xcode, or Android ones in Android Studio."
            : "It starts if it isn't running."
        card.isHidden = simulators.isEmpty
        select(simulators.firstIndex { $0.info.simulator == kept } ?? 0)
    }

    private static func row(for simulator: SimulatorChoice) -> ListRow {
        let symbol = simulator.isTablet ? "ipad" : simulator.platform == .android ? "candybarphone" : "iphone"
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let row = ListRow(title: simulator.name, subtitle: simulator.runtime, icon: icon,
                          accessory: simulator.isRunning ? RunningBadge() : nil)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        row.setAccessibilityLabel(simulator.isRunning ? "\(simulator.name), \(simulator.runtime), Running" : "\(simulator.name), \(simulator.runtime)")
        return row
    }

    private func select(_ index: Int) {
        guard !rows.isEmpty else { return }
        selected = min(max(index, 0), rows.count - 1)
        for (offset, row) in rows.enumerated() { row.isSelected = offset == selected }
        let row = rows[selected]
        row.scrollToVisible(row.bounds)
    }

    private func choose(_ index: Int) {
        guard simulators.indices.contains(index) else { return }
        select(index)
        onChoose?(simulators[index])
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let page = max(Int(scroll.contentView.bounds.height / 40) - 1, 1)
        switch event.keyCode {
        case 125: select(selected + 1)
        case 126: select(selected - 1)
        case 121: select(selected + page)
        case 116: select(selected - page)
        case 115: select(0)
        case 119: select(rows.count - 1)
        case 36, 76, 49: choose(selected)
        default: super.keyDown(with: event)
        }
    }

    override func themeDidChange() {
        titleLabel.textColor = theme.fg
        detailLabel.textColor = theme.fgMuted
    }
}

/// A running simulator's accent dot and "Running".
private final class RunningBadge: NSStackView {
    private let dot = StatusDot()
    private let label = makeLabel("Running", font: AppFont.footnote)
    private let observer = PaletteObserver()

    init() {
        super.init(frame: .zero)
        dot.glyph = .connected
        orientation = .horizontal
        alignment = .centerY
        spacing = 5
        addArrangedSubview(dot)
        addArrangedSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observer.observe(self) { [weak self] in self?.label.textColor = AppTheme.shared.fgMuted }
    }
}

/// A centered message with an optional button, such as a simulator that is
/// shut down or a missing Xcode.
final class SimulatorMessageView: ThemedView {
    private let titleLabel = makeLabel("", font: AppFont.system(15, weight: .semibold))
    private let detailLabel = makeLabel("", font: AppFont.body)
    private let spinner = NSProgressIndicator()
    private let button = PillButton("")
    private let stack: NSStackView

    override init(frame frameRect: NSRect) {
        stack = NSStackView(views: [spinner, titleLabel, detailLabel, button])
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        titleLabel.alignment = .center
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byWordWrapping
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(14, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(title: String, detail: String = "", busy: Bool = false, button title2: String? = nil, action: (() -> Void)? = nil) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        spinner.isHidden = !busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        button.title = title2 ?? ""
        button.isHidden = title2 == nil
        button.onPress = action
    }

    override func themeDidChange() {
        titleLabel.textColor = theme.fgMuted
        detailLabel.textColor = theme.fgDim
    }
}
