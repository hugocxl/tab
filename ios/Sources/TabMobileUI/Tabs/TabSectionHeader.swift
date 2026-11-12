import UIKit

/// A section's header in the tab list: a Mac's name, or a project's, which
/// collapses its tabs when tapped and opens new tabs there from its menu, as
/// the desktop sidebar's project header does.
final class TabSectionHeader: UICollectionViewListCell, UIGestureRecognizerDelegate {
    private let menuButton = UIButton(configuration: .plain())
    private let disclosureButton = UIButton(configuration: .plain())
    private var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggle))
        tap.delegate = self
        addGestureRecognizer(tap)
        disclosureButton.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .primaryActionTriggered)
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.configuration?.image = UIImage(systemName: "ellipsis")
        for button in [menuButton, disclosureButton] {
            button.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
            button.configuration?.baseForegroundColor = .secondaryLabel
            button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A Mac's header, which neither collapses nor has a menu.
    func showMac() {
        onToggle = nil
        accessories = []
    }

    /// A project's header: its tabs `collapsed` or shown, `menu` behind the
    /// ellipsis, and `onToggle` for a tap anywhere else.
    func showProject(_ name: String, collapsed: Bool, menu: UIMenu, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        menuButton.menu = menu
        menuButton.accessibilityLabel = "\(name) Actions"
        disclosureButton.configuration?.image = UIImage(systemName: collapsed ? "chevron.right" : "chevron.down")
        disclosureButton.accessibilityLabel = collapsed ? "Show \(name) Tabs" : "Hide \(name) Tabs"
        guard accessories.isEmpty else { return }
        accessories = [menuButton, disclosureButton].map { button in
            .customView(configuration: UICellAccessory.CustomViewConfiguration(
                customView: button, placement: .trailing(displayed: .always)))
        }
    }

    @objc private func toggle() { onToggle?() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        onToggle != nil && !(touch.view is UIControl)
    }
}
