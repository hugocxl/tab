import AppKit
import TabCore

/// The icons the chrome uses, drawn with SF Symbols where one matches and
/// with the bundled Lucide SVG otherwise. Images are templates, so they tint
/// with `contentTintColor` or the drawing color.
public enum AppIcon: String, CaseIterable, Sendable {
    case appWindow, arrowUpDown, chevronDown, chevronLeft, chevronRight, chevronUp, check, circleX
    case code, circleUser, columns, ellipsis, folder, gitBranch, globe, eye, keyboard, lightbulb
    case maximize, network, palette, panelBottom, panelLeft, panelRight, pin, pinOff, plus, puzzle
    case restore, refresh, rows, search, settings, terminal, terminalStack, close, externalLink
    case filter, filterCircle, history, sparkles, arrowDownCircle, arrowUpCircle, chevronsUpDown
    case circle, circleCheck, clock, file, gitMerge, gitPullRequest, octagonX, copy, pause, pencil
    case play, quote, stop, triangleAlert, phone, trash, minus, qrcode

    /// The SF Symbol drawn for the icon.
    public var symbolName: String? {
        switch self {
        case .appWindow: return "macwindow"
        case .arrowUpDown: return "arrow.up.arrow.down"
        case .chevronDown: return "chevron.down"
        case .chevronLeft: return "chevron.left"
        case .chevronRight: return "chevron.right"
        case .chevronUp: return "chevron.up"
        case .check: return "checkmark"
        case .circleX: return "xmark.circle"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .circleUser: return "person.crop.circle"
        case .columns: return "square.split.2x1"
        case .ellipsis: return "ellipsis"
        case .folder: return "folder"
        case .gitBranch: return "arrow.triangle.branch"
        case .globe: return "globe"
        case .eye: return "eye"
        case .keyboard: return "keyboard"
        case .lightbulb: return "lightbulb"
        case .maximize: return "arrow.up.left.and.arrow.down.right"
        case .network: return "network"
        case .palette: return "paintpalette"
        case .panelBottom: return "rectangle.bottomhalf.inset.filled"
        case .panelLeft: return "sidebar.left"
        case .panelRight: return "sidebar.right"
        case .pin: return "pin"
        case .pinOff: return "pin.slash"
        case .plus: return "plus"
        case .puzzle: return "puzzlepiece.extension"
        case .restore: return "arrow.down.right.and.arrow.up.left"
        case .refresh: return "arrow.clockwise"
        case .rows: return "square.split.1x2"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        case .terminal: return "terminal"
        case .terminalStack: return nil
        case .close: return "xmark"
        case .externalLink: return "arrow.up.forward.app"
        case .filter: return "line.3.horizontal.decrease"
        case .filterCircle: return "line.3.horizontal.decrease.circle"
        case .history: return "clock.arrow.circlepath"
        case .sparkles: return "sparkles"
        case .arrowDownCircle: return "arrow.down.circle"
        case .arrowUpCircle: return "arrow.up.circle"
        case .chevronsUpDown: return "chevron.up.chevron.down"
        case .circle: return "circle"
        case .circleCheck: return "checkmark.circle"
        case .clock: return "clock"
        case .file: return "doc"
        case .gitMerge: return "arrow.triangle.merge"
        case .gitPullRequest: return "arrow.triangle.pull"
        case .octagonX: return "xmark.octagon"
        case .copy: return "rectangle.on.rectangle"
        case .pause: return "pause"
        case .pencil: return "pencil"
        case .play: return "play"
        case .quote: return "text.quote"
        case .stop: return "stop"
        case .triangleAlert: return "exclamationmark.triangle"
        case .phone: return "iphone"
        case .trash: return "trash"
        case .minus: return "minus"
        case .qrcode: return "qrcode"
        }
    }

    /// The bundled SVG in `Resources/Icons`, the fallback when the symbol is
    /// missing.
    public var resourceName: String? {
        switch self {
        case .appWindow: return "app-window"
        case .arrowUpDown: return "arrow-up-down"
        case .chevronDown: return "chevron-down"
        case .chevronLeft: return "chevron-left"
        case .chevronRight: return "chevron-right"
        case .chevronUp: return "chevron-up"
        case .check: return "check"
        case .circleX: return "circle-x"
        case .code: return "code"
        case .circleUser: return "circle-user"
        case .columns: return "columns-2"
        case .ellipsis: return "ellipsis"
        case .folder: return "folder"
        case .gitBranch: return "git-branch"
        case .globe: return "globe"
        case .eye: return "eye"
        case .keyboard: return "keyboard"
        case .lightbulb: return "lightbulb"
        case .maximize: return "maximize"
        case .network: return "network"
        case .palette: return "palette"
        case .panelBottom: return "panel-bottom"
        case .panelLeft: return "panel-left"
        case .panelRight: return "panel-right"
        case .pin: return "pin"
        case .pinOff: return "pin-off"
        case .plus: return "plus"
        case .puzzle: return "puzzle"
        case .restore: return "restore"
        case .refresh: return "rotate-cw"
        case .rows: return "rows-2"
        case .search: return "search"
        case .settings: return "settings"
        case .terminal: return "terminal"
        case .terminalStack: return "terminal-stack"
        case .close: return "window-close"
        case .externalLink: return "square-arrow-out-up-right"
        case .filter: return "list-filter"
        case .filterCircle: return "filter-circle"
        case .history: return "history"
        case .sparkles: return "sparkles"
        case .arrowDownCircle: return "circle-arrow-down"
        case .arrowUpCircle: return "circle-arrow-up"
        case .chevronsUpDown: return "chevrons-up-down"
        case .circle: return "circle"
        case .circleCheck: return "circle-check"
        case .clock: return "clock"
        case .file: return "file"
        case .gitMerge: return "git-merge"
        case .gitPullRequest: return "git-pull-request"
        case .octagonX: return "octagon-x"
        case .copy: return "copy"
        case .pause: return "pause"
        case .pencil: return "pencil"
        case .play: return "play"
        case .quote: return "text-quote"
        case .stop: return "square"
        case .triangleAlert: return "triangle-alert"
        case .phone, .trash, .minus, .qrcode: return nil
        }
    }

    /// A template image `size` points tall.
    @MainActor
    public func image(size: CGFloat = Metrics.glyph, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(rawValue)-\(size)-\(weight.rawValue)"
        if let cached = IconCache.images[key] { return cached }
        var image: NSImage?
        if let symbolName, let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: weight, scale: .medium)
            image = symbol.withSymbolConfiguration(configuration)
        }
        if image == nil, let resourceName, let bundled = BundledImage.load(resourceName, extension: "svg") {
            bundled.size = NSSize(width: size, height: size)
            image = bundled
        }
        image?.isTemplate = true
        IconCache.images[key] = image
        return image
    }
}

@MainActor
private enum IconCache {
    static var images: [String: NSImage] = [:]
}

/// Images shipped in `Resources/Icons`.
public enum BundledImage {
    public static func url(_ name: String, extension fileExtension: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Icons")
    }

    public static func load(_ name: String, extension fileExtension: String) -> NSImage? {
        url(name, extension: fileExtension).flatMap(NSImage.init(contentsOf:))
    }
}

/// Agent logos, colored, with dark-on-light variants where the logo needs
/// one.
public enum AgentLogo {
    /// The logo for `provider`, or `nil` for an unknown provider.
    @MainActor
    public static func image(for provider: AgentProvider, lightBackground: Bool) -> NSImage? {
        guard let (name, hasLightVariant) = resource(provider) else { return nil }
        if name == "provider-xal" {
            let image = BundledImage.load(name, extension: "svg")
            image?.isTemplate = true
            return image
        }
        if lightBackground && hasLightVariant, let light = BundledImage.load("\(name)-light", extension: "png") {
            return light
        }
        return BundledImage.load(name, extension: "png")
    }

    private static func resource(_ provider: AgentProvider) -> (String, Bool)? {
        switch provider {
        case .claude: return ("agent-claude", false)
        case .codex: return ("agent-codex", true)
        case .openCode: return ("agent-opencode", false)
        case .cursor: return ("agent-cursor", false)
        case .copilot: return ("agent-copilot", false)
        case .droid: return ("agent-droid", false)
        case .pi: return ("agent-pi", false)
        case .grok: return ("agent-grok", true)
        case .kiro: return ("agent-kiro", false)
        case .xal: return ("provider-xal", false)
        case .antigravity: return ("agent-antigravity", false)
        case .ohMyPi: return ("agent-omp", false)
        case .unknown: return nil
        }
    }
}
