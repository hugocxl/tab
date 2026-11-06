import UIKit

/// A column of comfortable reading width, centered in its view: the full
/// width on a phone, no wider than a long line of body text on an iPad.
enum ReadableColumn {
    static let maximumWidth: CGFloat = 720

    @discardableResult
    static func guide(in view: UIView, margin: CGFloat = 16) -> UILayoutGuide {
        let guide = UILayoutGuide()
        view.addLayoutGuide(guide)
        let fill = guide.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -2 * margin)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            guide.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guide.widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth),
            guide.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: margin),
            guide.topAnchor.constraint(equalTo: view.topAnchor),
            guide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            fill,
        ])
        return guide
    }
}
