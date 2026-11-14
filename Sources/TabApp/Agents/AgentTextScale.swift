import AppKit
import TabCore

extension Notification.Name {
    /// Posted when the agent text scale changes, so open conversations render again.
    static let agentTextScaleDidChange = Notification.Name("TabAgentTextScaleDidChange")
}

/// The size of agent conversation text, changed by the font-size shortcuts while an
/// agent pane is focused. One scale for every agent pane, kept for the app's session.
/// Changed only on the main thread; renderers read it while they draw.
enum AgentTextScale {
    static let steps: [CGFloat] = [0.8, 0.9, 1, 1.1, 1.2, 1.35, 1.5, 1.7]
    nonisolated(unsafe) private(set) static var factor: CGFloat = 1

    /// `base` points at the current scale, on a half-point grid.
    static func size(_ base: CGFloat) -> CGFloat {
        factor == 1 ? base : (base * factor * 2).rounded() / 2
    }

    /// Steps the scale up or down; false at either end.
    @MainActor @discardableResult
    static func step(larger: Bool) -> Bool {
        let index = steps.firstIndex(of: factor) ?? steps.firstIndex(of: 1) ?? 0
        let next = index + (larger ? 1 : -1)
        guard steps.indices.contains(next) else { return false }
        set(steps[next])
        return true
    }

    @MainActor
    static func set(_ value: CGFloat) {
        guard value != factor else { return }
        factor = value
        NotificationCenter.default.post(name: .agentTextScaleDidChange, object: nil)
    }
}

/// Agent conversation fonts at the current text scale.
enum AgentFont {
    static func system(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        AppFont.system(AgentTextScale.size(size), weight: weight)
    }

    static func mono(_ size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSFont {
        AppFont.mono(AgentTextScale.size(size), weight: weight)
    }
}

/// What each block of a message rendered to last time, so a streaming update renders
/// only the blocks that changed.
final class AgentMarkdownRenderCache {
    struct Context: Equatable {
        var palette: ChromePalette
        var scheme: ColorScheme
        var fileLinks: Bool
        var references: [String: String]
        var compact: Bool
        var lineBreaks: Bool
        var rawHTML: Bool
        var listIndents: [Int: CGFloat]
        var scale: CGFloat
    }

    struct Key: Equatable {
        var block: AgentMarkdown.Block
        var first: Bool
        var previous: AgentMarkdown.Block?
    }

    struct Part {
        var key: Key
        /// Nil when the block can't be reused.
        var text: NSAttributedString?
    }

    var context: Context?
    var parts: [Part] = []
    /// Blocks rendered rather than reused, for tests.
    var renderedBlocks = 0
}
