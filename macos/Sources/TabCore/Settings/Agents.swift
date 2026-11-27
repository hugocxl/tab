import Foundation

/// Whether agent conversations load images the assistant names by a web address.
/// Project files and images sent in the conversation always load.
public enum RemoteImagePolicy: String, Codable, Sendable, CaseIterable {
    case always
    /// A tile names the image's host and loads it when clicked.
    case clickToLoad
    /// Only the link shows; nothing is fetched, including link icons.
    case never

    public var title: String {
        switch self {
        case .always: return "Always"
        case .clickToLoad: return "Click to load"
        case .never: return "Never"
        }
    }

    /// A value this build doesn't know, from a newer one, reads as the default.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RemoteImagePolicy(rawValue: raw) ?? AgentSettings().remoteImages
    }
}

public struct AgentSettings: Codable, Equatable, Sendable {
    public var remoteImages: RemoteImagePolicy

    public init(remoteImages: RemoteImagePolicy = .clickToLoad) {
        self.remoteImages = remoteImages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remoteImages = try container.value(.remoteImages, AgentSettings().remoteImages)
    }
}
