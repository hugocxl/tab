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
}

/// Window arithmetic shared by the panel's cards, matching T3 Code's limits view.
enum UsageMath {
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
