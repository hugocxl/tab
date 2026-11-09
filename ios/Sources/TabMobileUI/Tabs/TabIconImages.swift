import TabMobileKit
import UIKit

extension TabIcon.Hue {
    /// The hue as Tab's themes draw icons: shade 600 on light backgrounds,
    /// 400 on dark, with gray at 800 on light.
    var color: UIColor {
        let (light, dark) = hexes
        return UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }

    private var hexes: (UInt32, UInt32) {
        switch self {
        case .gray: (0x6c6c71, 0xadadb1)
        case .red: (0xd52c36, 0xff6762)
        case .vermilion: (0xd5512f, 0xff8c5b)
        case .orange: (0xd47628, 0xffa359)
        case .yellow: (0xd5a910, 0xffd452)
        case .green: (0x199f43, 0x5ecc71)
        case .mint: (0x16a994, 0x61d5c0)
        case .teal: (0x17a5af, 0x64d1db)
        case .cyan: (0x1ca1c7, 0x68cdf2)
        case .blue: (0x1a85d4, 0x69b1ff)
        case .indigo: (0x693acf, 0x9d6afb)
        case .purple: (0xa631be, 0xd568ea)
        case .pink: (0xd32a61, 0xff678d)
        case .brown: (0x956b4f, 0xc3987b)
        }
    }
}

extension TabIcon {
    /// The SVG as a template image at its own aspect ratio, for an image view
    /// to tint and fit.
    var template: UIImage? { UIImage(named: "TabIcons/" + rawValue) }

    /// The mark's color: its signature hue, else `plain`.
    func color(plain: UIColor = .secondaryLabel) -> UIColor {
        signatureHue?.color ?? plain
    }

    /// How large a mark beside text or in a control is drawn on its square,
    /// as Tab draws them.
    static let inlineScale: CGFloat = 0.78

    /// The mark fitted to `side * scale` and centered on a square `side`
    /// points wide, in its signature hue or `plain`, for light and dark: for
    /// menus and other places that take a finished image.
    @MainActor
    func image(side: CGFloat, scale: CGFloat = 1, plain: UIColor = .secondaryLabel) -> UIImage? {
        guard let template, template.size.width > 0, template.size.height > 0 else { return nil }
        let color = color(plain: plain)
        let fit = min(side * scale / template.size.width, side * scale / template.size.height)
        let size = CGSize(width: template.size.width * fit, height: template.size.height * fit)
        let rect = CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
        // Each appearance is registered at the screen's scale, so the asset
        // hands back points, not pixels.
        let current = UITraitCollection.current
        let displayScale = current.displayScale > 0 ? current.displayScale : 3
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = displayScale
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection { traits in
                traits.userInterfaceStyle = style
                traits.displayScale = displayScale
            }
            let tinted = template.withTintColor(color.resolvedColor(with: traits), renderingMode: .alwaysOriginal)
            let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                tinted.draw(in: rect)
            }
            asset.register(image, with: traits)
        }
        let style = current.userInterfaceStyle == .dark ? UIUserInterfaceStyle.dark : .light
        return asset.image(with: UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.displayScale = displayScale
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
