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
    /// The commit graph plugin.
    public static let gitGraph = PluginId("git-graph")
    /// The QuickShot screenshot-to-clipboard plugin.
    public static let quickshot = PluginId("quickshot")
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

    public static let gitGraph = PluginDescriptor(
        id: .gitGraph,
        name: "Git Graph",
        summary: "Browse every branch's commits as a graph in the right sidebar, and check out, cherry-pick or revert them.",
        iconName: "git-graph",
        bundleName: "TabGitGraphPlugin",
        principalClass: "TabGitGraphPluginFactory",
        panelIds: ["gitGraph"]
    )

    public static let quickshot = PluginDescriptor(
        id: .quickshot,
        name: "QuickShot",
        summary: "Capture the screen under your pointer from any app with a shortcut, ready to paste into a terminal or agent.",
        iconName: "image",
        bundleName: "TabQuickShotPlugin",
        principalClass: "TabQuickShotPluginFactory",
        panelIds: []
    )

    /// Every official plugin, in catalog order.
    public static let all: [PluginDescriptor] = [
        explorer,
        diff,
        usage,
        gitGraph,
        quickshot,
    ]

    public static func descriptor(for id: PluginId) -> PluginDescriptor? {
        all.first { $0.id == id }
    }
}

/// Arbitrary JSON value used to persist per-plugin configuration in `settings.json`
/// without coupling `TabCore` to individual plugin modules.
public enum PluginConfigValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([PluginConfigValue])
    case object([String: PluginConfigValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PluginConfigValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PluginConfigValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Which plugins are installed in this profile and their saved configurations.
/// By default, none are installed.
public struct PluginSettings: Codable, Equatable, Sendable {
    public var installed: [PluginId]
    /// Per-plugin JSON configuration objects keyed by `PluginId.rawValue`.
    public var config: [String: PluginConfigValue]

    public init(installed: [PluginId] = [], config: [String: PluginConfigValue] = [:]) {
        self.installed = installed
        self.config = config
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.value(.installed, [PluginId]())
        var seen: Set<PluginId> = []
        installed = raw.filter { seen.insert($0).inserted }
        config = try container.value(.config, [String: PluginConfigValue]())
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

    /// Decodes a plugin's saved configuration as `type`, or `nil` when absent or unreadable.
    public func decodeConfig<T: Decodable>(_ type: T.Type, for id: PluginId) -> T? {
        guard let value = config[id.rawValue] else { return nil }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Encodes and stores `value` as `id`'s configuration.
    public mutating func encodeConfig<T: Encodable>(_ value: T, for id: PluginId) throws {
        let data = try JSONEncoder().encode(value)
        config[id.rawValue] = try JSONDecoder().decode(PluginConfigValue.self, from: data)
    }
}
