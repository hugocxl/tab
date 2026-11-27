import Foundation
import TabProtocol

extension PaneSummary {
    /// Short names for a tab's panes, for a segmented control: the agent's
    /// name, a terminal's command, otherwise the pane's title, cut to a few
    /// words; repeated names are numbered.
    public static func shortLabels(_ panes: [PaneSummary], limit: Int = 14) -> [String] {
        let names = panes.map { pane -> String in
            let name: String
            switch pane.kind {
            case .agent(let provider): name = provider == .claude ? "Claude" : "Codex"
            case .terminal: name = pane.title.split(separator: " ").first.map(String.init) ?? "Terminal"
            default: name = pane.title
            }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return "Pane" }
            return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
        }
        var seen: [String: Int] = [:]
        let totals = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        return names.map { name in
            guard totals[name, default: 0] > 1 else { return name }
            seen[name, default: 0] += 1
            return "\(name) \(seen[name] ?? 1)"
        }
    }
}
