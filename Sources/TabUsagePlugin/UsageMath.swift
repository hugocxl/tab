import Foundation
import TabProtocol

/// How spending compares with the time gone in a window.
enum UsagePace: Equatable {
    /// Spending faster than the window elapses.
    case ahead
    case on
    /// Headroom left for the rest of the window.
    case under

    var label: String {
        switch self {
        case .ahead: return "Ahead of pace: spending faster than the window elapses"
        case .on: return "On pace with the window"
        case .under: return "Under pace: headroom left for the rest of the window"
        }
    }

    /// The words after the reset countdown: `ahead of pace`.
    var short: String {
        switch self {
        case .ahead: return "ahead of pace"
        case .on: return "on pace"
        case .under: return "under pace"
        }
    }
}

/// How close a window is to its limit, as Headroom words it.
enum UsageTone: Int, Comparable {
    /// Used up: nothing left until the reset.
    case over
    /// Under a tenth left.
    case almostOut
    /// Under the configured share left.
    case low
    case fine

    static func < (lhs: UsageTone, rhs: UsageTone) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The label beside the figure; nil while there is room.
    var label: String? {
        switch self {
        case .over: return "Limit reached"
        case .almostOut: return "Almost out"
        case .low: return "Running low"
        case .fine: return nil
        }
    }
}

/// Window arithmetic shared by the panel's cards, matching T3 Code's limits view.
enum UsageMath {
    static func tone(_ window: AgentUsageWindow, lowThreshold: Int) -> UsageTone {
        let left = 100 - window.usedPercent
        if left <= 0 { return .over }
        if left < 10 { return .almostOut }
        if left < Double(lowThreshold) { return .low }
        return .fine
    }

    /// The window an account's card leads with: the one closest to its limit, the
    /// longer one when two are as close, since it takes longer to come back.
    static func headline(_ limits: AgentUsageLimits) -> AgentUsageWindow? {
        headline(limits.windows)
    }

    static func headline(_ windows: [AgentUsageWindow]) -> AgentUsageWindow? {
        windows.max { a, b in
            a.usedPercent != b.usedPercent ? a.usedPercent < b.usedPercent
                : (a.windowDurationMinutes ?? 0) < (b.windowDurationMinutes ?? 0)
        }
    }

    /// Orders accounts closest to their limits first; accounts that could not be read go last.
    static func byUrgency(_ accounts: [AgentUsageLimits], lowThreshold: Int) -> [AgentUsageLimits] {
        func rank(_ limits: AgentUsageLimits) -> (Int, Double) {
            guard let window = headline(limits) else { return (Int.max, 0) }
            return (tone(window, lowThreshold: lowThreshold).rawValue, -window.usedPercent)
        }
        return accounts.enumerated().sorted { a, b in
            let (x, y) = (rank(a.element), rank(b.element))
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// `3 days 12 h`, `4 h 12 min` or `12 min`, as the reset line says it.
    static func spelledDuration(_ interval: TimeInterval) -> String {
        let minutesTotal = Int(max(interval, 0) / 60)
        let days = minutesTotal / (24 * 60)
        let hours = minutesTotal % (24 * 60) / 60
        let minutes = minutesTotal % 60
        if days > 0 { return hours > 0 ? "\(days) \(days == 1 ? "day" : "days") \(hours) h" : "\(days) \(days == 1 ? "day" : "days")" }
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        return minutes > 0 ? "\(minutes) min" : "under a minute"
    }

    /// `just now`, `7 min ago`, `2 h ago` or `3 days ago`.
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(max(now.timeIntervalSince(date), 0) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 24 * 60 { return "\(minutes / 60) h ago" }
        let days = minutes / (24 * 60)
        return "\(days) \(days == 1 ? "day" : "days") ago"
    }

    /// The whole percentage shown: what is used or what is left.
    static func figure(_ window: AgentUsageWindow, _ figure: UsageConfig.Figure) -> Int {
        figure == .left ? remainingPercent(window) : 100 - remainingPercent(window)
    }

    /// A date and time to hover over a relative one, such as "Thu, Nov 27, 14:00".
    static func exact(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d jj:mm")
        return formatter.string(from: date)
    }

    /// What the pace means for the rest of the window, for the expanded card.
    static func paceSentence(_ window: AgentUsageWindow, now: Date) -> String? {
        guard let elapsed = elapsedShare(window, now: now), elapsed > 0.02, let resetsAt = window.resetsAt else { return nil }
        switch pace(window, now: now) {
        case .ahead:
            // Spending at the rate so far, the rest lasts (left ÷ used) as long as the time gone.
            guard window.usedPercent > 0, let minutes = window.windowDurationMinutes else { return nil }
            let gone = Double(minutes) * 60 * elapsed
            let runsOut = gone * (100 - window.usedPercent) / window.usedPercent
            guard now.addingTimeInterval(runsOut) < resetsAt else { return "Ahead of pace" }
            return "At this pace it runs out in \(spelledDuration(runsOut))"
        case .on: return "On pace with the window"
        case .under: return "Under pace, with room to spare"
        case nil: return nil
        }
    }
    /// The whole percentage of the window left to spend.
    static func remainingPercent(_ window: AgentUsageWindow) -> Int {
        Int((100 - min(max(window.usedPercent, 0), 100)).rounded())
    }

    /// The share of the window's time gone, 0–1, when its length and reset are known.
    static func elapsedShare(_ window: AgentUsageWindow, now: Date) -> Double? {
        guard let resetsAt = window.resetsAt, let minutes = window.windowDurationMinutes, minutes > 0 else { return nil }
        let length = Double(minutes) * 60
        return min(max((length - resetsAt.timeIntervalSince(now)) / length, 0), 1)
    }

    /// Where even spending would leave the bar: the whole percentage of time left.
    static func paceRemainingPercent(_ window: AgentUsageWindow, now: Date) -> Int? {
        elapsedShare(window, now: now).map { Int(((1 - $0) * 100).rounded()) }
    }

    static func pace(_ window: AgentUsageWindow, now: Date) -> UsagePace? {
        guard let elapsed = elapsedShare(window, now: now) else { return nil }
        let gap = window.usedPercent - elapsed * 100
        if gap > 5 { return .ahead }
        if gap < -5 { return .under }
        return .on
    }

    /// `4d 22h`, `4h 53m` or `12m`.
    static func duration(_ interval: TimeInterval) -> String {
        let minutesTotal = Int(max(interval, 0) / 60)
        let days = minutesTotal / (24 * 60)
        let hours = minutesTotal % (24 * 60) / 60
        let minutes = minutesTotal % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// The countdown to the window's reset, or nil when the reset is unknown.
    static func resetsIn(_ window: AgentUsageWindow, now: Date) -> String? {
        guard let resetsAt = window.resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSince(now)
        return interval <= 0 ? "now" : duration(interval)
    }

    /// The bar's spoken and hover summary.
    static func summary(_ window: AgentUsageWindow, now: Date) -> String {
        var parts = ["\(remainingPercent(window))% left"]
        if let timeLeft = paceRemainingPercent(window, now: now) { parts.append("\(timeLeft)% of the window left") }
        var text = parts.joined(separator: " · ")
        if paceRemainingPercent(window, now: now) != nil { text += "\nThe line is where even spending would be." }
        if let resetsAt = window.resetsAt {
            let formatter = DateFormatter()
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            text += "\nResets \(formatter.string(from: resetsAt))"
            if let resetsIn = resetsIn(window, now: now) { text += " · in \(resetsIn)" }
        }
        return text
    }
}
