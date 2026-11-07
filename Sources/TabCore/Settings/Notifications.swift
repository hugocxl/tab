import Foundation

/// What a program or agent in a pane is doing, as tabs, notifications, the
/// Dock badge and sounds report it.
public enum ActivityStatus: String, Codable, Sendable, CaseIterable {
    /// A program is busy or reports progress, or an agent is working.
    case working
    /// An agent is waiting for you.
    case blocked
    /// A program reported an error.
    case error
    /// A program or agent finished, or a program sent a notification.
    case done

    public var title: String {
        switch self {
        case .working: return "Working"
        case .blocked: return "Blocked"
        case .error: return "Error"
        case .done: return "Done"
        }
    }

    /// When the status shows, for its page.
    public var summary: String {
        switch self {
        case .working: return "Shown when a program is busy or reports progress"
        case .blocked: return "Shown when an agent is waiting for you"
        case .error: return "Shown when a program reports an error"
        case .done: return "Shown when a program finishes a task"
        }
    }
}

/// The corner or edge of the window in-app notifications stack at.
public enum NotificationPosition: String, Codable, Sendable, CaseIterable {
    case topLeft, top, topRight, bottomLeft, bottom, bottomRight

    public var title: String {
        switch self {
        case .topLeft: return "top left"
        case .top: return "top center"
        case .topRight: return "top right"
        case .bottomLeft: return "bottom left"
        case .bottom: return "bottom center"
        case .bottomRight: return "bottom right"
        }
    }

    public var isTop: Bool { [.topLeft, .top, .topRight].contains(self) }

    /// -1 for the left edge, 0 for the center, 1 for the right edge.
    public var column: Int {
        switch self {
        case .topLeft, .bottomLeft: return -1
        case .top, .bottom: return 0
        case .topRight, .bottomRight: return 1
        }
    }

    /// Positions from newer builds read as bottom right.
    public init(from decoder: Decoder) throws {
        self = NotificationPosition(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .bottomRight
    }
}

/// A sound a status plays, from the bubble family.
public enum NotificationSound: String, Codable, Sendable, CaseIterable {
    case success, ready, attention, warning, error, open, close, navigate, toggle, select, tap

    public var title: String {
        switch self {
        case .success: return "Success"
        case .ready: return "Ready"
        case .attention: return "Attention"
        case .warning: return "Warning"
        case .error: return "Error"
        case .open: return "Open"
        case .close: return "Close"
        case .navigate: return "Navigate"
        case .toggle: return "Toggle"
        case .select: return "Select"
        case .tap: return "Tap"
        }
    }

    /// Sounds from newer builds read as Success.
    public init(from decoder: Decoder) throws {
        self = NotificationSound(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .success
    }
}

/// How one status is reported.
public struct StatusNotifications: Codable, Equatable, Sendable {
    /// Off, the status is never reported.
    public var enabled: Bool
    public var showInTabs: Bool
    public var systemNotifications: Bool
    public var dockBadge: Bool
    public var playSound: Bool
    public var sound: NotificationSound

    public init(enabled: Bool = true, showInTabs: Bool = true, systemNotifications: Bool = true, dockBadge: Bool = true,
                playSound: Bool = true, sound: NotificationSound) {
        self.enabled = enabled
        self.showInTabs = showInTabs
        self.systemNotifications = systemNotifications
        self.dockBadge = dockBadge
        self.playSound = playSound
        self.sound = sound
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = StatusNotifications(sound: .success)
        enabled = try container.value(.enabled, d.enabled)
        showInTabs = try container.value(.showInTabs, d.showInTabs)
        systemNotifications = try container.value(.systemNotifications, d.systemNotifications)
        dockBadge = try container.value(.dockBadge, d.dockBadge)
        playSound = try container.value(.playSound, d.playSound)
        sound = try container.value(.sound, d.sound)
    }
}

/// Where in-app notifications show, and how each status is reported. The
/// switches outside the statuses turn a channel off for every status.
public struct NotificationSettings: Codable, Equatable, Sendable {
    public var position: NotificationPosition
    public var showActivityInTabs: Bool
    public var systemNotifications: Bool
    public var dockBadge: Bool
    public var playSounds: Bool
    /// Programs may ask for notifications with OSC 9 or OSC 777.
    public var terminalNotifications: Bool
    public var working: StatusNotifications
    public var blocked: StatusNotifications
    public var error: StatusNotifications
    public var done: StatusNotifications

    public init() {
        position = .bottomRight
        showActivityInTabs = true
        systemNotifications = true
        dockBadge = true
        playSounds = true
        terminalNotifications = true
        working = StatusNotifications(systemNotifications: false, dockBadge: false, playSound: false, sound: .ready)
        blocked = StatusNotifications(sound: .attention)
        error = StatusNotifications(sound: .error)
        done = StatusNotifications(sound: .success)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationSettings()
        position = try container.value(.position, d.position)
        showActivityInTabs = try container.value(.showActivityInTabs, d.showActivityInTabs)
        systemNotifications = try container.value(.systemNotifications, d.systemNotifications)
        dockBadge = try container.value(.dockBadge, d.dockBadge)
        playSounds = try container.value(.playSounds, d.playSounds)
        terminalNotifications = try container.value(.terminalNotifications, d.terminalNotifications)
        working = try container.value(.working, d.working)
        blocked = try container.value(.blocked, d.blocked)
        error = try container.value(.error, d.error)
        done = try container.value(.done, d.done)
    }

    public subscript(status: ActivityStatus) -> StatusNotifications {
        get {
            switch status {
            case .working: return working
            case .blocked: return blocked
            case .error: return error
            case .done: return done
            }
        }
        set {
            switch status {
            case .working: working = newValue
            case .blocked: blocked = newValue
            case .error: error = newValue
            case .done: done = newValue
            }
        }
    }

    /// Whether tabs and pane headers show `status`.
    public func showsInTabs(_ status: ActivityStatus) -> Bool {
        showActivityInTabs && self[status].enabled && self[status].showInTabs
    }

    /// Whether `status` posts a macOS notification.
    public func notifies(_ status: ActivityStatus) -> Bool {
        systemNotifications && self[status].enabled && self[status].systemNotifications
    }

    /// Whether `status` counts toward the Dock badge.
    public func badges(_ status: ActivityStatus) -> Bool {
        dockBadge && self[status].enabled && self[status].dockBadge
    }

    /// The sound `status` plays, if any.
    public func sound(_ status: ActivityStatus) -> NotificationSound? {
        playSounds && self[status].enabled && self[status].playSound ? self[status].sound : nil
    }

    /// The channels `status` uses, for its row: "Tabs, Notifications".
    public func channels(_ status: ActivityStatus) -> String {
        guard self[status].enabled else { return "Off" }
        let names = [(showsInTabs(status), "Tabs"), (notifies(status), "Notifications"),
                     (badges(status), "Dock Badge"), (sound(status) != nil, "Sound")]
            .filter(\.0).map(\.1)
        return names.isEmpty ? "On" : names.joined(separator: ", ")
    }
}
