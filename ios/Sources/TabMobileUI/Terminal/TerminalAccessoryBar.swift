import TabProtocol
import UIKit

/// The keys a phone keyboard lacks, floating above it in Liquid Glass:
/// Escape, latching Control and Option, Tab, arrows that repeat while held,
/// the symbols shells use most, paste and hide.
final class TerminalAccessoryBar: UIInputView, TerminalKeysDisplay {
    private weak var terminal: TerminalView?
    private var controlButton: UIButton?
    private var optionButton: UIButton?
    private let repeater = KeyRepeater()

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 56), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 56) }

    private func build() {
        // Separate capsules: keys, arrows and the rest never morph into each other.
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        let scroll = FadingScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        container.addSubview(scroll)

        let control = modifierButton("ctrl", accessibility: "Control") { [weak self] in self?.terminal?.tap(.control) }
        let option = modifierButton("opt", accessibility: "Option") { [weak self] in self?.terminal?.tap(.alt) }
        controlButton = control
        optionButton = option

        let keys = group([
            textButton("esc", accessibility: "Escape") { [weak self] in self?.terminal?.sendKey("escape") },
            control, option,
            symbolButton("arrow.right.to.line", accessibility: "Tab") { [weak self] in self?.terminal?.sendKey("tab") },
        ])
        let arrows = group([
            repeatingButton("arrow.left", accessibility: "Left", key: "arrow_left"),
            repeatingButton("arrow.up", accessibility: "Up", key: "arrow_up"),
            repeatingButton("arrow.down", accessibility: "Down", key: "arrow_down"),
            repeatingButton("arrow.right", accessibility: "Right", key: "arrow_right"),
        ])
        let paste = group([
            symbolButton("doc.on.clipboard", accessibility: "Paste") { [weak self] in self?.terminal?.paste() },
        ])
        let symbols = group(["~", "/", "|", "-", "_", "*", "$", "&", ";", ":", "`", "\"", "'", "<", ">",
                             "{", "}", "[", "]", "(", ")", "#", "!", "\\", "="].map { symbol in
            textButton(symbol, accessibility: symbol) { [weak self] in self?.terminal?.insertText(symbol) }
        })
        let hide = group([
            symbolButton("keyboard.chevron.compact.down", accessibility: "Hide Keyboard") { [weak self] in
                self?.terminal?.resignFirstResponder()
            },
        ])

        let stack = UIStackView(arrangedSubviews: [keys, arrows, paste, symbols])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        hide.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hide)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),

            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 44),

            hide.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            hide.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    /// Buttons sharing one capsule of glass.
    private func group(_ buttons: [UIButton]) -> UIView {
        let glass = UIGlassEffect()
        glass.isInteractive = true
        let capsule = UIVisualEffectView(effect: glass)
        capsule.cornerConfiguration = .capsule()
        let stack = UIStackView(arrangedSubviews: buttons)
        stack.axis = .horizontal
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: capsule.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor),
            capsule.heightAnchor.constraint(equalToConstant: 44),
        ])
        return capsule
    }

    private func baseConfiguration() -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 7, bottom: 6, trailing: 7)
        return configuration
    }

    private func textButton(_ title: String, accessibility: String, action: @escaping () -> Void) -> UIButton {
        var configuration = baseConfiguration()
        var attributes = AttributeContainer()
        attributes.font = UIFont.monospacedSystemFont(ofSize: 16, weight: .medium)
        configuration.attributedTitle = AttributedString(title, attributes: attributes)
        return button(configuration, accessibility: accessibility, action: action)
    }

    private func modifierButton(_ title: String, accessibility: String, action: @escaping () -> Void) -> UIButton {
        let button = textButton(title, accessibility: accessibility, action: action)
        button.configurationUpdateHandler = { button in
            var configuration = button.configuration
            configuration?.background.backgroundColor = button.isSelected ? .tintColor : .clear
            configuration?.background.cornerRadius = 16
            configuration?.baseForegroundColor = button.isSelected ? .white : .label
            button.configuration = configuration
        }
        button.accessibilityTraits.insert(.button)
        return button
    }

    private func symbolButton(_ symbol: String, accessibility: String, action: @escaping () -> Void) -> UIButton {
        var configuration = baseConfiguration()
        configuration.image = UIImage(systemName: symbol,
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        return button(configuration, accessibility: accessibility, action: action)
    }

    private func repeatingButton(_ symbol: String, accessibility: String, key: String) -> UIButton {
        let button = symbolButton(symbol, accessibility: accessibility) {}
        button.addAction(UIAction { [weak self] _ in self?.startRepeating(key) }, for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            button.addAction(UIAction { [weak self] _ in self?.stopRepeating() }, for: event)
        }
        return button
    }

    private func button(_ configuration: UIButton.Configuration, accessibility: String,
                        action: @escaping () -> Void) -> UIButton {
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            UIDevice.current.playInputClick()
            action()
        })
        button.accessibilityLabel = accessibility
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        return button
    }

    // MARK: Modifiers and repeat

    func show(_ latch: TerminalKeyLatch) {
        for (button, modifier) in [(controlButton, KeyModifiers.control), (optionButton, .alt)] {
            button?.isSelected = latch.active.contains(modifier)
            button?.accessibilityValue = latch.locked.contains(modifier) ? "Locked" : nil
        }
    }

    private func startRepeating(_ key: String) {
        UIDevice.current.playInputClick()
        repeater.start { [weak self] in self?.terminal?.sendKey(key) }
    }

    private func stopRepeating() {
        repeater.stop()
    }
}

extension TerminalAccessoryBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// A scroll view whose content fades out at the edges it can scroll toward.
final class FadingScrollView: UIScrollView {
    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = fade
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        let width = max(bounds.width, 1)
        let edge = min(0.5, 24 / width)
        let canLeft = contentOffset.x > 1
        let canRight = contentOffset.x + bounds.width < contentSize.width - 1
        let clear = UIColor.clear.cgColor
        let solid = UIColor.black.cgColor
        fade.colors = [canLeft ? clear : solid, solid, solid, canRight ? clear : solid]
        fade.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        CATransaction.commit()
    }
}
