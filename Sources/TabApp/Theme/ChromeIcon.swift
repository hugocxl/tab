import AppKit
import Icons

/// The stroke icons of the sidebar chrome and pane headers, from
/// @hugocxl/icons' stroke set.
public enum ChromeIcon: String, CaseIterable, Sendable {
    case panelLeft
    case panelRight
    case command
    case plusCircle
    case addProject
    case globeBadgePlus
    case filter
    case clearField
    case terminal
    case code
    case file
    case gitBranch
    case globe
    case phone
    case chevronLeft
    case home
    case rotate
    case keyboard
    case appearance
    case camera
    case ellipsis
    case network
    case columns
    case rows
    case maximize
    case restore
    case close

    var stroke: StrokeIcon {
        switch self {
        case .panelLeft: return .panelLeft
        case .panelRight: return .panelRight
        case .command: return .command
        case .plusCircle: return .circlePlus
        case .addProject: return .rectangleStackPlus
        case .globeBadgePlus: return .globePlus
        case .filter: return .circleListFilter
        case .clearField: return .circleX
        case .terminal: return .terminal
        case .code: return .code
        case .file: return .file
        case .gitBranch: return .gitBranch
        case .globe: return .globe
        case .phone: return .phone
        case .chevronLeft: return .chevronLeft
        case .home: return .home
        case .rotate: return .rotateLeft
        case .keyboard: return .keyboard
        case .appearance: return .contrast
        case .camera: return .camera
        case .ellipsis: return .ellipsis
        case .network: return .network
        case .columns: return .columns
        case .rows: return .rows
        case .maximize: return .maximize2
        case .restore: return .minimize2
        case .close: return .close
        }
    }

    /// A cached template image on a square canvas `size` points on a side.
    @MainActor
    public func image(size: CGFloat = Metrics.glyph) -> NSImage? {
        let key = "\(rawValue)-\(size)"
        if let cached = Self.images[key] { return cached }
        guard let source = stroke.nsImage, source.size.width > 0, source.size.height > 0 else { return nil }
        let fit = min(size / source.size.width, size / source.size.height)
        let fitted = NSSize(width: source.size.width * fit, height: source.size.height * fit)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: NSRect(x: (rect.width - fitted.width) / 2, y: (rect.height - fitted.height) / 2,
                                   width: fitted.width, height: fitted.height))
            return true
        }
        image.isTemplate = true
        Self.images[key] = image
        return image
    }

    @MainActor private static var images: [String: NSImage] = [:]
}
