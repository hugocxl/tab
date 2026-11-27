import TabProtocol
import UIKit

/// One key on the terminal's on-screen keys.
enum TerminalKeyboardKey: Equatable {
    /// Types its character, as the system keyboard would.
    case text(String)
    /// A named key the server encodes, like `f5` or `page_up`; arrows repeat while held.
    case key(String, label: String, accessibility: String, symbol: String? = nil, repeats: Bool = false)
    case modifier(KeyModifiers, label: String, accessibility: String)
    case paste
    case pages
    case hide
}

/// The full grid: symbols, arrows and modifiers on the first page; function
/// and navigation keys on the second.
enum TerminalKeyboardLayout {
    static let main: [[TerminalKeyboardKey]] = [
        [.key("escape", label: "esc", accessibility: "Escape"), .text("~"), .text("#"), .text("["), .text("]"),
         .text("|"), .text("*"), .hide],
        [.key("tab", label: "tab", accessibility: "Tab"), .text("$"), .text("&"), .text("{"), .text("}"),
         .text("/"), arrow("up"), .pages],
        [.modifier(.shift, label: "shift", accessibility: "Shift"),
         .modifier(.control, label: "ctrl", accessibility: "Control"),
         .modifier(.alt, label: "opt", accessibility: "Option"),
         .text("<"), .text(">"), arrow("left"), arrow("down"), arrow("right")],
    ]

    static let functions: [[TerminalKeyboardKey]] = [
        (1...7).map(function) + [.pages],
        (8...12).map(function) + [.key("home", label: "home", accessibility: "Home"),
                                  .key("end", label: "end", accessibility: "End"),
                                  .key("page_up", label: "pgup", accessibility: "Page Up", repeats: true)],
        [.key("page_down", label: "pgdn", accessibility: "Page Down", repeats: true),
         .key("delete", label: "del", accessibility: "Forward Delete", repeats: true),
         .paste, .text("-"), .text("_"), .text(":"), .text("\\"), .hide],
    ]

    private static func arrow(_ direction: String) -> TerminalKeyboardKey {
        .key("arrow_\(direction)", label: "", accessibility: direction.capitalized, symbol: "arrow.\(direction)",
             repeats: true)
    }

    private static func function(_ number: Int) -> TerminalKeyboardKey {
        .key("f\(number)", label: "F\(number)", accessibility: "F\(number)")
    }
}

/// The keys a phone keyboard lacks, as a grid of glass keys above it, with a
/// second page of function and navigation keys.
final class TerminalKeyboard: UIInputView, TerminalKeysDisplay {
    private weak var terminal: TerminalView?
    private let repeater = KeyRepeater()
    private var pages: [UIView] = []
    private var currentPage = 0
    private var modifierButtons: [(KeyModifiers, UIButton)] = []

    private static let keyHeight: CGFloat = 40
    private static let spacing: CGFloat = 6
    private static let inset: CGFloat = 6
    private static let height = keyHeight * 3 + spacing * 2 + inset * 2

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: Self.height), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        for (index, rows) in [TerminalKeyboardLayout.main, TerminalKeyboardLayout.functions].enumerated() {
            let page = grid(rows)
            page.isHidden = index != currentPage
            addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: Self.inset),
                page.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -Self.inset),
                page.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
                // Above the home indicator when no software keyboard is up.
                page.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -Self.inset),
            ])
            pages.append(page)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    func show(_ latch: TerminalKeyLatch) {
        for (modifier, button) in modifierButtons {
            let locked = latch.locked.contains(modifier)
            button.isSelected = latch.active.contains(modifier)
            button.accessibilityValue = locked ? "Locked" : button.isSelected ? "On" : nil
            button.configuration = modifierConfiguration(button.configuration, selected: button.isSelected,
                                                         locked: locked)
        }
    }

    private func grid(_ rows: [[TerminalKeyboardKey]]) -> UIView {
        let stack = UIStackView(arrangedSubviews: rows.map { row in
            let rowStack = UIStackView(arrangedSubviews: row.map(button))
            rowStack.axis = .horizontal
            rowStack.spacing = Self.spacing
            rowStack.distribution = .fillEqually
            return rowStack
        })
        stack.axis = .vertical
        stack.spacing = Self.spacing
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: Keys

    private func button(_ key: TerminalKeyboardKey) -> UIButton {
        switch key {
        case .text(let character):
            return keyButton(title: character, monospaced: true, accessibility: character) { [weak self] in
                self?.terminal?.insertText(character)
            }
        case .key(let name, let label, let accessibility, let symbol, let repeats):
            guard repeats else {
                return keyButton(title: label, symbol: symbol, accessibility: accessibility) { [weak self] in
                    self?.terminal?.sendKey(name)
                }
            }
            let button = keyButton(title: label, symbol: symbol, accessibility: accessibility, action: nil)
            makeRepeating(button, key: name)
            return button
        case .modifier(let modifier, let label, let accessibility):
            let button = keyButton(title: label, accessibility: accessibility) { [weak self] in
                self?.terminal?.tap(modifier)
            }
            modifierButtons.append((modifier, button))
            return button
        case .paste:
            return keyButton(symbol: "doc.on.clipboard", accessibility: "Paste") { [weak self] in
                self?.terminal?.paste()
            }
        case .pages:
            let onMain = pages.isEmpty
            return keyButton(symbol: onMain ? "function" : "keyboard",
                             accessibility: onMain ? "Function Keys" : "Symbol Keys") { [weak self] in
                self?.turnPage()
            }
        case .hide:
            return keyButton(symbol: "keyboard.chevron.compact.down", accessibility: "Hide Keyboard") { [weak self] in
                self?.terminal?.resignFirstResponder()
            }
        }
    }

    private func keyButton(title: String = "", symbol: String? = nil, monospaced: Bool = false,
                           accessibility: String, action: (() -> Void)?) -> UIButton {
        var configuration = UIButton.Configuration.glass()
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        configuration.titleLineBreakMode = .byClipping
        if let symbol {
            configuration.image = UIImage(systemName: symbol,
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        } else {
            var attributes = AttributeContainer()
            attributes.font = monospaced
                ? UIFont.monospacedSystemFont(ofSize: 18, weight: .medium)
                : UIFont.systemFont(ofSize: 14, weight: .medium)
            configuration.attributedTitle = AttributedString(title, attributes: attributes)
        }
        let button = UIButton(configuration: configuration)
        if let action {
            button.addAction(UIAction { _ in
                UIDevice.current.playInputClick()
                action()
            }, for: .primaryActionTriggered)
        }
        button.accessibilityLabel = accessibility
        button.accessibilityTraits.insert(.keyboardKey)
        return button
    }

    private func modifierConfiguration(_ current: UIButton.Configuration?, selected: Bool,
                                       locked: Bool) -> UIButton.Configuration? {
        guard let current else { return nil }
        var configuration = selected ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
        configuration.cornerStyle = current.cornerStyle
        configuration.contentInsets = current.contentInsets
        configuration.titleLineBreakMode = current.titleLineBreakMode
        configuration.baseForegroundColor = selected ? .white : .label
        var title = current.attributedTitle ?? AttributedString()
        title.font = UIFont.systemFont(ofSize: 14, weight: selected ? .bold : .medium)
        title.underlineStyle = locked ? .single : nil
        configuration.attributedTitle = title
        return configuration
    }

    /// Sends the key at once, then again and again while held.
    private func makeRepeating(_ button: UIButton, key: String) {
        button.addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.repeater.start { [weak self] in self?.terminal?.sendKey(key) }
        }, for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            button.addAction(UIAction { [weak self] _ in self?.repeater.stop() }, for: event)
        }
    }

    private func turnPage() {
        let from = pages[currentPage]
        currentPage = (currentPage + 1) % pages.count
        let to = pages[currentPage]
        to.alpha = 0
        to.isHidden = false
        UIView.animate(withDuration: 0.15) {
            from.alpha = 0
            to.alpha = 1
        } completion: { _ in
            from.isHidden = true
            from.alpha = 1
        }
    }
}

extension TerminalKeyboard: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// The on-screen keys above the system keyboard, either layout.
@MainActor
protocol TerminalKeysDisplay: UIInputView {
    func show(_ latch: TerminalKeyLatch)
}

/// Runs a key's action once, then repeatedly while it stays held.
@MainActor
final class KeyRepeater {
    private var timer: Timer?
    private var action: (() -> Void)?

    func start(_ action: @escaping () -> Void) {
        self.action = action
        action()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.action?() }
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        action = nil
    }
}
