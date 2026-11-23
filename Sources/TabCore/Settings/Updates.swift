import Foundation

/// How Tab checks for, downloads and installs app updates.
public struct UpdateSettings: Codable, Equatable, Sendable {
    /// Download updates in the background, except on a Low Data Mode or
    /// hotspot network, and ask before restarting.
    public var automaticDownloads: Bool
    /// Relaunch into a downloaded update once Tab's windows are out of sight,
    /// when the running local server stays compatible.
    public var automaticInstall: Bool

    public init(automaticDownloads: Bool = true, automaticInstall: Bool = false) {
        self.automaticDownloads = automaticDownloads
        self.automaticInstall = automaticInstall
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UpdateSettings()
        automaticDownloads = try container.value(.automaticDownloads, defaults.automaticDownloads)
        automaticInstall = try container.value(.automaticInstall, defaults.automaticInstall)
    }
}
