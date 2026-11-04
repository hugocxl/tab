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
/// used, each with its OS.
final class DevicePickerView: ThemedView {
    var onChoose: ((DeviceChoice) -> Void)?

    private let titleLabel = makeLabel("Choose a Device", font: AppFont.system(15, weight: .semibold))
    private let detailLabel = makeLabel("It starts if it isn't running.", font: AppFont.body)
    private let list = NSStackView()
    private let scroll = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        list.orientation = .vertical
        list.alignment = .width
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        list.pinEdges(to: document)
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

    /// Shows the devices of the tab's server; `host` names it when it is another computer.
    func show(_ devices: [DeviceChoice], host: String?) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        titleLabel.stringValue = host.map { "Choose a Device on \($0)" } ?? "Choose a Device"
        let place = host ?? "this Mac"
        detailLabel.stringValue = devices.isEmpty
            ? "No simulators or emulators were found on \(place). Add iOS simulators in Xcode, or Android ones in Android Studio."
            : "It starts if it isn't running."
        for device in devices {
            let row = DevicePickerRow(device: device)
            row.theme = theme
            row.onClick = { [weak self] in self?.onChoose?(device) }
            list.addArrangedSubview(row)
        }
    }

    override func themeDidChange() {
        titleLabel.textColor = theme.fg
        detailLabel.textColor = theme.fgMuted
    }
}

/// One simulator: its icon, name, OS and whether it runs.
private final class DevicePickerRow: HoverView {
    var onClick: (() -> Void)?

    private let icon = NSImageView()
    private let nameLabel: NSTextField
    private let detailLabel: NSTextField

    init(device: DeviceChoice) {
        nameLabel = makeLabel(device.name, font: AppFont.system(13, weight: .medium))
        let detail = device.isRunning ? "\(device.runtime) · Running" : device.runtime
        detailLabel = makeLabel(detail, font: AppFont.footnote)
        super.init(frame: .zero)
        let symbol = device.isTablet ? "ipad" : device.platform == .android ? "candybarphone" : "iphone"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        icon.translatesAutoresizingMaskIntoConstraints = false
        let text = NSStackView(views: [nameLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(text)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(device.name), \(detail)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func hoverDidChange() { themeDidChange() }

    override func themeDidChange() {
        layer?.cornerRadius = Metrics.radiusLarge
        layer?.backgroundColor = isHovered ? theme.hover.cgColor : NSColor.clear.cgColor
        icon.contentTintColor = theme.fgMuted
        nameLabel.textColor = theme.fg
        detailLabel.textColor = theme.fgMuted
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
