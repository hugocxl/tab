import Foundation
import TabProtocol

/// Prints what driving a simulator read back, compactly for agents.
public enum SimulatorOutput {
    /// One element: `@e3 [button] "General" #general = "On" disabled`.
    public static func line(_ element: SimulatorElement, screen: SimulatorScreen?, frames: Bool) -> String {
        var line = "@\(element.ref) [\(element.role)]"
        if let label = element.label { line += " \(quoted(label))" }
        if let identifier = element.identifier, identifier != element.label { line += " #\(identifier)" }
        if let value = element.value, value != element.label { line += " = \(quoted(value))" }
        if !element.enabled { line += " disabled" }
        if let screen, isOffscreen(element, screen) { line += " offscreen" }
        if frames {
            let n = SimulatorTarget.number
            line += " (\(n(element.x)),\(n(element.y)) \(n(element.width))x\(n(element.height)))"
        }
        return line
    }

    /// A snapshot, indented by depth unless it holds only interactive elements.
    public static func snapshot(_ elements: [SimulatorElement], screen: SimulatorScreen?, frames: Bool, flat: Bool) -> String {
        var lines: [String] = []
        if frames, let screen {
            let n = SimulatorTarget.number
            lines.append("screen \(n(screen.width))x\(n(screen.height)) points")
        }
        for element in elements {
            let indent = flat ? "" : String(repeating: "  ", count: min(element.depth, 40))
            lines.append(indent + line(element, screen: screen, frames: frames))
        }
        if elements.isEmpty { lines.append("no elements; the screen may still be loading") }
        return lines.joined(separator: "\n")
    }

    /// What changed after a settle: `+` new, `-` gone, `~` changed.
    public static func changes(_ result: SimulatorDriveResult, frames: Bool) -> String {
        var lines: [String] = []
        for element in result.removed ?? [] { lines.append("- " + line(element, screen: nil, frames: false)) }
        for element in result.added ?? [] { lines.append("+ " + line(element, screen: result.screen, frames: frames)) }
        for element in result.changed ?? [] { lines.append("~ " + line(element, screen: result.screen, frames: frames)) }
        let unchanged = result.unchanged ?? 0
        lines.append(lines.isEmpty ? "= no change (\(unchanged) elements)" : "= \(unchanged) unchanged")
        return lines.joined(separator: "\n")
    }

    /// Everything a result holds except an image, or `ok`.
    public static func text(_ result: SimulatorDriveResult, frames: Bool, flat: Bool) -> String {
        var parts: [String] = []
        if let elements = result.elements {
            parts.append(snapshot(elements, screen: result.screen, frames: frames, flat: flat))
        } else if result.added != nil || result.removed != nil || result.changed != nil {
            parts.append(changes(result, frames: frames))
        }
        if let apps = result.apps {
            parts.append(apps.map { app in app.name.map { "\(app.id)\t\($0)" } ?? app.id }.joined(separator: "\n"))
        }
        if let logs = result.logs { parts.append(logs.trimmingCharacters(in: .newlines)) }
        parts += result.notes.map { "note: \($0)" }
        return parts.isEmpty ? "ok" : parts.joined(separator: "\n")
    }

    static func isOffscreen(_ element: SimulatorElement, _ screen: SimulatorScreen) -> Bool {
        element.x + element.width <= 0 || element.y + element.height <= 0 || element.x >= screen.width || element.y >= screen.height
    }

    private static func quoted(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let short = flat.count > 200 ? String(flat.prefix(199)) + "…" : flat
        return "\"" + short.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
