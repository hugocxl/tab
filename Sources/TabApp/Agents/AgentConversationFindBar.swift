import AppKit

/// The conversation's find bar: the terminal's find bar, themed for the agent pane and
/// without the case toggle, since conversation search always ignores case and accents.
@MainActor
final class AgentConversationFindBar: ThemedView, FindBarDelegate {
    static let height = FindBar.height

    /// The query after each edit.
    var onQueryChange: ((String) -> Void)?
    /// Return, Shift-Return or the arrow buttons; true steps backwards.
    var onStep: ((Bool) -> Void)?
    /// Escape or the close button.
    var onClose: (() -> Void)?

    let bar = FindBar()

    var query: String {
        get { bar.query }
        set { bar.query = newValue }
    }

    /// The match count shown beside the field.
    var counter: String {
        get { bar.counter }
        set {
            bar.counter = newValue
            bar.setAccessibilityValue(newValue)
        }
    }

    /// True while the field has the keyboard.
    var isEditing: Bool { bar.isEditing }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bar.placeholder = "Find in conversation…"
        bar.showsCaseToggle = false
        bar.delegate = self
        addSubview(bar)
        themeDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Puts the keyboard in the field with its text selected.
    func focus() { bar.focus() }

    override func layout() {
        bar.frame = bounds
        super.layout()
    }

    override func themeDidChange() {
        bar.style = FindBar.Style(background: theme.card, border: theme.fg.withAlphaComponent(0.08),
                                  fieldBackground: theme.fg.withAlphaComponent(0.05),
                                  fieldBorder: theme.fg.withAlphaComponent(0.10), text: theme.fg,
                                  muted: theme.fgDim, accent: theme.accent)
    }

    func findBar(_ bar: FindBar, didChangeQuery query: String) { onQueryChange?(query) }
    func findBarDidToggleCase(_ bar: FindBar) {}
    func findBar(_ bar: FindBar, step previous: Bool) { onStep?(previous) }
    func findBarDidClose(_ bar: FindBar) { onClose?() }
}
