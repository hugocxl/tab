import UIKit

/// The first screen: what Tab on a phone is, and pairing with a Mac.
final class WelcomeViewController: UIViewController {
    var onScan: (() -> Void)?
    var onPaste: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let icon = UIImageView(image: UIImage(named: "Mascot"))
        icon.contentMode = .scaleAspectFill
        icon.layer.cornerRadius = 28
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.accessibilityIgnoresInvertColors = true
        let iconShadow = UIView()
        iconShadow.layer.shadowColor = UIColor.black.cgColor
        iconShadow.layer.shadowOpacity = 0.18
        iconShadow.layer.shadowRadius = 18
        iconShadow.layer.shadowOffset = CGSize(width: 0, height: 8)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconShadow.addSubview(icon)

        let title = UILabel()
        title.text = "Tab"
        title.font = UIFont.preferredFont(forTextStyle: .largeTitle).withTraits(.traitBold)
        title.adjustsFontForContentSizeCategory = true
        let subtitle = UILabel()
        subtitle.text = "Your Mac's terminals and agents, wherever you are."
        subtitle.font = .preferredFont(forTextStyle: .title3)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0
        subtitle.textAlignment = .center

        let steps = UIStackView(arrangedSubviews: [
            step("1", "On your Mac, open Tab, then Settings → Mobile."),
            step("2", "Turn on Allow mobile devices."),
            step("3", "Choose Show Pairing Code and scan it."),
        ])
        steps.axis = .vertical
        steps.spacing = 14
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        steps.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(steps)

        var scanConfiguration = UIButton.Configuration.prominentGlass()
        scanConfiguration.title = "Scan Pairing Code"
        scanConfiguration.image = UIImage(systemName: "qrcode.viewfinder")
        scanConfiguration.imagePadding = 8
        scanConfiguration.buttonSize = .large
        let scan = UIButton(configuration: scanConfiguration, primaryAction: UIAction { [weak self] _ in self?.onScan?() })
        var pasteConfiguration = UIButton.Configuration.glass()
        pasteConfiguration.title = "Paste Link"
        pasteConfiguration.buttonSize = .large
        let paste = UIButton(configuration: pasteConfiguration, primaryAction: UIAction { [weak self] _ in self?.onPaste?() })

        let header = UIStackView(arrangedSubviews: [iconShadow, title, subtitle])
        header.axis = .vertical
        header.alignment = .center
        header.spacing = 12
        header.setCustomSpacing(24, after: iconShadow)
        let buttons = UIStackView(arrangedSubviews: [scan, paste])
        buttons.axis = .vertical
        buttons.spacing = 12
        let content = UIStackView(arrangedSubviews: [header, card, buttons])
        content.axis = .vertical
        content.spacing = 32
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 112),
            icon.heightAnchor.constraint(equalToConstant: 112),
            icon.topAnchor.constraint(equalTo: iconShadow.topAnchor),
            icon.bottomAnchor.constraint(equalTo: iconShadow.bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: iconShadow.leadingAnchor),
            icon.trailingAnchor.constraint(equalTo: iconShadow.trailingAnchor),
            steps.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            steps.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            steps.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            steps.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            content.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor, constant: -8),
            content.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
        let preferredWidth = content.widthAnchor.constraint(equalToConstant: 440)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
    }

    private func step(_ number: String, _ text: String) -> UIView {
        let badge = UILabel()
        badge.text = number
        badge.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        badge.textAlignment = .center
        badge.textColor = .white
        badge.backgroundColor = .tintColor
        badge.layer.cornerRadius = 13
        badge.layer.masksToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
        ])
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [badge, label])
        row.spacing = 12
        row.alignment = .center
        return row
    }
}
