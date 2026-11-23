import AppKit
import TabCore

/// Installation state of a plugin shown in Settings → Plugins.
public enum PluginInstallState: Equatable, Sendable {
    case notInstalled
    case installing
    case installed
    case failed(String)

    public var isInstalled: Bool { self == .installed }
    public var isInstalling: Bool { self == .installing }
}

/// A right-sidebar tab contributed by a plugin.
@MainActor
public struct PluginSidebarPanel {
    public let id: String
    public let pluginId: PluginId
    public let title: String
    public let icon: AppIcon
    public let shortcut: ShortcutId?
    public let order: Int
    public let makeContent: @MainActor (AppModel) -> RightPanelContent

    public init(
        id: String,
        pluginId: PluginId,
        title: String,
        icon: AppIcon,
        shortcut: ShortcutId? = nil,
        order: Int = 100,
        makeContent: @escaping @MainActor (AppModel) -> RightPanelContent
    ) {
        self.id = id
        self.pluginId = pluginId
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.order = order
        self.makeContent = makeContent
    }

    public var descriptor: RightPanelDescriptor {
        RightPanelDescriptor(id: id, pluginId: pluginId, title: title, icon: icon, shortcut: shortcut, order: order)
    }
}

/// Entry point implemented by every Tab plugin.
@MainActor
public protocol TabPlugin: AnyObject {
    var id: PluginId { get }
    /// Called once when the plugin is loaded and enabled. Register right-sidebar
    /// panels, pane providers, and event hooks on `context`.
    func activate(context: PluginContext)
    /// Called before the plugin is removed; release any resources owned directly
    /// by the plugin. Registrations made on `context` are cleaned up automatically.
    func deactivate()
}

/// Objective-C principal class exported by every loadable plugin `.bundle`.
/// Subclass this in the plugin module and set `NSPrincipalClass` in the
/// bundle's `Info.plist` to `<ModuleName>.<SubclassName>`.
@objc(TabPluginFactory)
@MainActor
open class TabPluginFactory: NSObject {
    public required override init() {
        super.init()
    }

    open func makePlugin() -> any TabPlugin {
        fatalError("TabPluginFactory subclasses must override makePlugin()")
    }
}

/// Errors thrown while installing, loading, or uninstalling a plugin.
public enum PluginError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case unknownPlugin(PluginId)
    case bundleNotFound(String)
    case downloadFailed(String)
    case invalidBundle(String)
    case incompatibleVersion(String)
    case loadFailed(String)
    case installFailed(String)

    public var description: String {
        switch self {
        case .unknownPlugin(let id):
            return "Unknown plugin “\(id.rawValue)”."
        case .bundleNotFound(let detail):
            return detail
        case .downloadFailed(let detail):
            return "Could not download plugin: \(detail)"
        case .invalidBundle(let detail):
            return "Invalid plugin bundle: \(detail)"
        case .incompatibleVersion(let detail):
            return detail
        case .loadFailed(let detail):
            return "Could not load plugin: \(detail)"
        case .installFailed(let detail):
            return "Could not install plugin: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}
