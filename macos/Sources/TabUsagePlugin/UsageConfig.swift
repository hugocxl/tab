import Foundation
import TabCore

/// AI Usage's settings, saved in `settings.json` → `plugins.config.usage`.
public struct UsageConfig: Codable, Equatable, Sendable {
    /// How often the panel reads the limits again while it shows.
    public static let refreshChoices = [0, 1, 2, 5, 10, 15, 30, 60]

    /// How the panel orders the accounts.
    public enum Order: String, Codable, CaseIterable, Sendable {
        /// The account closest to its limit first.
        case urgency
        /// In the order the server lists its providers.
        case provider
    }

    /// Whether figures count what is used or what is left.
    public enum Figure: String, Codable, CaseIterable, Sendable {
        case used
        case left
    }

    /// Minutes between readings while the panel shows; 0 reads only on request.
    public var refreshMinutes: Int
    public var order: Order
    public var figure: Figure
    /// The share left, in percent, under which an account reads as running low.
    public var lowThreshold: Int

    public init(refreshMinutes: Int = 5, order: Order = .urgency, figure: Figure = .used, lowThreshold: Int = 30) {
        self.refreshMinutes = refreshMinutes
        self.order = order
        self.figure = figure
        self.lowThreshold = lowThreshold
    }

    private enum CodingKeys: String, CodingKey { case refreshMinutes, order, figure, lowThreshold }

    /// Missing keys and unknown choices fall back to the defaults, so newer or
    /// hand-edited files still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UsageConfig()
        refreshMinutes = max((try? container.decodeIfPresent(Int.self, forKey: .refreshMinutes)) ?? nil ?? defaults.refreshMinutes, 0)
        order = (try? container.decodeIfPresent(Order.self, forKey: .order)) ?? nil ?? defaults.order
        figure = (try? container.decodeIfPresent(Figure.self, forKey: .figure)) ?? nil ?? defaults.figure
        let threshold = (try? container.decodeIfPresent(Int.self, forKey: .lowThreshold)) ?? nil ?? defaults.lowThreshold
        lowThreshold = min(max(threshold, 10), 90)
    }

    /// The saved configuration in `settings`, or the defaults.
    public static func current(in settings: Settings) -> UsageConfig {
        settings.plugins.decodeConfig(UsageConfig.self, for: .usage) ?? UsageConfig()
    }

    /// How a refresh interval reads in Settings.
    public static func refreshTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Only when I refresh"
        case 1: return "Every minute"
        case 60: return "Every hour"
        default: return "Every \(minutes) minutes"
        }
    }
}
