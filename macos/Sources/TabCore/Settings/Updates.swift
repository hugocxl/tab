import Foundation

/// How Tab checks for, downloads and installs app updates.
public struct UpdateSettings: Codable, Equatable, Sendable {
    /// Download updates in the background, except on a Low Data Mode or
    /// hotspot network.
    public var automaticDownloads: Bool
    /// Relaunch into a downloaded update while the person is away or Tab is
    /// out of sight, and when Tab quits.
    public var automaticInstall: Bool
    /// Restart the local server on Tab's new version while the person is away
    /// and no program or agent works. Terminals reopen in their panes.
    public var automaticServerRestart: Bool

    public init(automaticDownloads: Bool = true, automaticInstall: Bool = true, automaticServerRestart: Bool = true) {
        self.automaticDownloads = automaticDownloads
        self.automaticInstall = automaticInstall
        self.automaticServerRestart = automaticServerRestart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UpdateSettings()
        automaticDownloads = try container.value(.automaticDownloads, defaults.automaticDownloads)
        automaticInstall = try container.value(.automaticInstall, defaults.automaticInstall)
        automaticServerRestart = try container.value(.automaticServerRestart, defaults.automaticServerRestart)
    }
}
