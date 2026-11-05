import AppKit
import TabCore
import TabProtocol

/// A device the picker offers: an iOS simulator or an Android emulator on
/// the tab's server.
struct DeviceChoice: Hashable, Sendable {
    var info: DeviceInfo

    var platform: DevicePlatform { info.device.platform }
    var name: String { info.name }
    /// The OS it runs, such as "iOS 27.0" or "Android API 35".
    var runtime: String { info.runtime }
    var isRunning: Bool { info.booted }
    var isTablet: Bool { info.isTablet }

    var pane: DevicePane {
        platform == .iOS ? DevicePane(udid: info.device.id, name: name) : DevicePane(avd: info.device.id, name: name)
    }
}

/// The devices to choose from: running ones first, then the most recently
/// used, each with its OS. It takes the keyboard: the arrows move the
/// selection and Return chooses it.
final class DevicePickerView: ThemedView {
    var onChoose: ((DeviceChoice) -> Void)?

    private let titleLabel = makeLabel("Choose a Device", font: AppFont.system(15, weight: .semibold))
    private let detailLabel = makeLabel("It starts if it isn't running.", font: AppFont.body)
    private let card = Card()
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var devices: [DeviceChoice] = []
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

    /// Shows the devices of the tab's server; `host` names it when it is
    /// another computer. The selection stays on the same device across reloads.
    func show(_ devices: [DeviceChoice], host: String?) {
        let kept = self.devices.indices.contains(selected) ? self.devices[selected].info.device : nil
        self.devices = devices
        rows.forEach { $0.removeFromSuperview() }
        rows = devices.enumerated().map { index, device in
            let row = Self.row(for: device)
            row.theme = theme
            row.onClick = { [weak self] in self?.choose(index) }
            list.addArrangedSubview(row)
            return row
        }
        titleLabel.stringValue = host.map { "Choose a Device on \($0)" } ?? "Choose a Device"
        let place = host ?? "this Mac"
        detailLabel.stringValue = devices.isEmpty
            ? "No simulators or emulators were found on \(place). Add iOS simulators in Xcode, or Android ones in Android Studio."
            : "It starts if it isn't running."
        card.isHidden = devices.isEmpty
        select(devices.firstIndex { $0.info.device == kept } ?? 0)
    }

    private static func row(for device: DeviceChoice) -> ListRow {
        let symbol = device.isTablet ? "ipad" : device.platform == .android ? "candybarphone" : "iphone"
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let row = ListRow(title: device.name, subtitle: device.runtime, icon: icon,
                          accessory: device.isRunning ? RunningBadge() : nil)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        row.setAccessibilityLabel(device.isRunning ? "\(device.name), \(device.runtime), Running" : "\(device.name), \(device.runtime)")
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
        guard devices.indices.contains(index) else { return }
        select(index)
        onChoose?(devices[index])
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

/// A running device's accent dot and "Running".
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

/// A centered message with an optional button, such as a device that is
/// shut down or a missing Xcode.
final class DeviceMessageView: ThemedView {
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
