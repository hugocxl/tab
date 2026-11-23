import Foundation

/// Identifies a Tab plugin, such as `"explorer"` or `"diff"`.
public struct PluginId: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The Files explorer right-sidebar plugin.
    public static let explorer = PluginId("explorer")
    /// The Source Control and Diff View plugin.
    public static let diff = PluginId("diff")
    /// The AI Usage plugin: agent subscription limits in the right sidebar.
    public static let usage = PluginId("usage")
}

/// Catalog metadata for a plugin available to install in Tab.
public struct PluginDescriptor: Equatable, Identifiable, Sendable {
    public let id: PluginId
    public let name: String
    public let summary: String
    /// Raw name of an `AppIcon` in `TabApp`.
    public let iconName: String
    /// Executable / bundle name inside `<id>.bundle`.
    public let bundleName: String
    /// Fully qualified Objective-C / Swift class name of the bundle's `TabPluginFactory` subclass.
    public let principalClass: String
    /// Right-sidebar panel IDs this plugin provides.
    public let panelIds: [String]
    /// Release asset filename prefix: `TabPlugin-<id>-<version>-arm64.zip`.
    public var releaseAssetPrefix: String { "TabPlugin-\(id.rawValue)" }

    public init(
        id: PluginId,
        name: String,
        summary: String,
        iconName: String,
        bundleName: String,
        principalClass: String,
        panelIds: [String]
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.iconName = iconName
        self.bundleName = bundleName
        self.principalClass = principalClass
        self.panelIds = panelIds
    }
}

/// The plugins Tab knows how to install and load on demand.
public enum PluginCatalog {
    public static let explorer = PluginDescriptor(
        id: .explorer,
        name: "Explorer",
        summary: "Browse project files and folders in the right sidebar.",
        iconName: "folder",
        bundleName: "TabExplorerPlugin",
        principalClass: "TabExplorerPluginFactory",
        panelIds: ["files"]
    )

    public static let diff = PluginDescriptor(
        id: .diff,
        name: "Diff View",
        summary: "Inspect Git changes, stage hunks, commit and open file diffs from the right sidebar.",
        iconName: "git-branch",
        bundleName: "TabDiffPlugin",
        principalClass: "TabDiffPluginFactory",
        panelIds: ["sourceControl"]
    )

    public static let usage = PluginDescriptor(
        id: .usage,
        name: "AI Usage",
        summary: "See how much of your Claude and Codex plan limits is left in the right sidebar.",
        iconName: "chart-line",
        bundleName: "TabUsagePlugin",
        principalClass: "TabUsagePluginFactory",
        panelIds: ["usage"]
    )

    /// Every official plugin, in catalog order.
    public static let all: [PluginDescriptor] = [
        explorer,
        diff,
        usage,
    ]

    public static func descriptor(for id: PluginId) -> PluginDescriptor? {
        all.first { $0.id == id }
    }
}

/// Which plugins are installed in this profile. By default, none are installed.
public struct PluginSettings: Codable, Equatable, Sendable {
    public var installed: [PluginId]

    public init(installed: [PluginId] = []) {
        self.installed = installed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.value(.installed, [PluginId]())
        var seen: Set<PluginId> = []
        installed = raw.filter { seen.insert($0).inserted }
    }

    public func isInstalled(_ id: PluginId) -> Bool {
        installed.contains(id)
    }

    public mutating func markInstalled(_ id: PluginId) {
        if !installed.contains(id) {
            installed.append(id)
        }
    }

    public mutating func markUninstalled(_ id: PluginId) {
        installed.removeAll { $0 == id }
    }
}
