import Foundation
import TabCore

/// QuickShot's settings, saved in `settings.json` → `plugins.config.quickshot`.
public struct QuickShotConfig: Codable, Equatable, Sendable {
    /// What starts a capture.
    public enum Trigger: String, Codable, CaseIterable, Sendable {
        /// Left and right Command pressed together, as in the Quickshot app.
        case commandKeys
        /// A recorded key chord, such as `ctrl-alt-cmd-s`.
        case shortcut
    }

    /// Where captures are saved.
    public enum Destination: String, Codable, CaseIterable, Sendable {
        case desktop
        /// A temporary folder whose captures are deleted after 24 hours.
        case temporary
    }

    /// What the clipboard receives.
    public enum Clipboard: String, Codable, CaseIterable, Sendable {
        /// The saved PNG's path, ready to paste into a terminal or agent.
        case path
        /// The image itself.
        case image
    }

    public var trigger: Trigger
    public var shortcut: KeyChord?
    public var destination: Destination
    public var clipboard: Clipboard
    public var playsSound: Bool
    public var showsPreview: Bool

    public init(
        trigger: Trigger = .commandKeys,
        shortcut: KeyChord? = nil,
        destination: Destination = .desktop,
        clipboard: Clipboard = .path,
        playsSound: Bool = true,
        showsPreview: Bool = true
    ) {
        self.trigger = trigger
        self.shortcut = shortcut
        self.destination = destination
        self.clipboard = clipboard
        self.playsSound = playsSound
        self.showsPreview = showsPreview
    }

    private enum CodingKeys: String, CodingKey {
        case trigger, shortcut, destination, clipboard, playsSound, showsPreview
    }

    /// Missing keys, unknown choices and unreadable chords fall back to the
    /// defaults, so newer or hand-edited files still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = QuickShotConfig()
        trigger = (try? container.decodeIfPresent(Trigger.self, forKey: .trigger)) ?? defaults.trigger
        shortcut = (try? container.decodeIfPresent(KeyChord.self, forKey: .shortcut)) ?? nil
        destination = (try? container.decodeIfPresent(Destination.self, forKey: .destination)) ?? defaults.destination
        clipboard = (try? container.decodeIfPresent(Clipboard.self, forKey: .clipboard)) ?? defaults.clipboard
        playsSound = (try? container.decodeIfPresent(Bool.self, forKey: .playsSound)) ?? defaults.playsSound
        showsPreview = (try? container.decodeIfPresent(Bool.self, forKey: .showsPreview)) ?? defaults.showsPreview
    }

    /// The saved configuration in `settings`, or the defaults.
    public static func current(in settings: Settings) -> QuickShotConfig {
        settings.plugins.decodeConfig(QuickShotConfig.self, for: .quickshot) ?? QuickShotConfig()
    }

    /// How the active trigger reads in Settings and messages.
    public var triggerDisplay: String {
        switch trigger {
        case .commandKeys: return "Left ⌘ + Right ⌘"
        case .shortcut: return shortcut?.display ?? "No shortcut"
        }
    }
}
