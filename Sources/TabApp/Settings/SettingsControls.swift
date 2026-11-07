import AppKit
import TabClient
import TabCore

/// A control on a Settings row, described as data so the page renders it
/// with native SwiftUI controls and tests can drive it without a window.
indirect enum SettingControl {
    case toggle(ToggleSpec)
    case choice(ChoiceSpec)
    case segmented(SegmentedSpec)
    /// Where notifications stack, picked on a sketch of the window.
    case position(PositionSpec)
    case stepper(StepperSpec)
    case text(TextSpec)
    case button(ButtonSpec)
    case color(ColorSpec)
    case shortcut(ShortcutSpec)
    case label(String, LabelStyle = .body)
    case keys(KeyChord)
    case qrCode(QRCode)
    /// A picture, such as an agent's logo, `side` points square.
    case image(NSImage, side: CGFloat)
    /// A font family's name, drawn in that font.
    case fontName(family: String, style: String)
    /// A terminal sample drawn with the page's settings.
    case preview(PreviewSpec)
    /// An ellipsis menu of a list entry's actions, such as Rename and Delete.
    case actions(String, [ButtonSpec])
    /// A chevron: the row opens another page.
    case disclosure(() -> Void)
    /// Controls side by side.
    case row([SettingControl])
    /// Controls stacked, leading or trailing aligned.
    case column([SettingControl], trailing: Bool = false)

    enum LabelStyle {
        case body, secondary, note, error, monospaced, badge
    }

    /// Every control in the tree, depth first.
    var leaves: [SettingControl] {
        switch self {
        case .row(let children), .column(let children, _): return children.flatMap(\.leaves)
        default: return [self]
        }
    }
}

struct ToggleSpec {
    var isOn: Bool
    var label: String
    var enabled = true
    var change: (Bool) -> Void
}

/// One item of a pop-up menu.
struct Choice: Equatable {
    var id: String
    var title: String
    var separatorBefore = false
}

struct ChoiceSpec {
    var items: [Choice]
    var selected: String
    var label: String
    /// Shown, and selected, when nothing is chosen yet, such as "Add Font…".
    var placeholder: String?
    /// A button titled `placeholder` that shows the items as a menu,
    /// rather than a pop-up showing the selected item.
    var isMenu = false
    var change: (String) -> Void

    var selectedTitle: String {
        items.first { $0.id == selected }?.title ?? placeholder ?? ""
    }
}

struct PositionSpec {
    var selected: NotificationPosition
    var label: String
    var change: (NotificationPosition) -> Void
}

struct SegmentedSpec {
    var titles: [String]
    var selected: Int
    var label: String
    var change: (Int) -> Void
}

/// A number field with stepper arrows and its unit, saved on Return,
/// leaving it, or a step.
struct StepperSpec {
    var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var unit: String?
    var label: String
    var commit: (Double) -> Void

    var text: String { Self.format(value, step: step) }

    /// A whole number for whole steps, else up to two decimals without
    /// trailing zeros.
    static func format(_ value: Double, step: Double) -> String {
        if step >= 1 { return String(Int(value.rounded())) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The value typed, clamped to the range; `nil` when it isn't a number.
    func parse(_ text: String) -> Double? {
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }
        return min(max((number / step).rounded() * step, range.lowerBound), range.upperBound)
    }
}

/// A terminal sample: what it shows, and the settings and colors it is
/// drawn with.
struct PreviewSpec {
    var preview: TerminalPreview
    var settings: TerminalSettings
    var palette: TerminalPalette
}

/// A text field saved on Return, on leaving it, or when Settings closes.
struct TextSpec {
    var id: String
    var value: String
    var placeholder = ""
    var label: String
    var width: CGFloat? = Metrics.controlWidth
    var multiline = false
    var monospaced = false
    var enabled = true
    /// Called on every keystroke, for drafts that other controls read.
    var change: ((String) -> Void)?
    var commit: (String) -> Void
}

struct ButtonSpec {
    enum Style { case normal, primary, destructive }

    var title: String
    var style: Style = .normal
    var enabled = true
    /// Shows an SF Symbol instead of the title; the title stays its label.
    var symbol: String?
    var help: String?
    var action: () -> Void
}

struct ColorSpec {
    var color: TabCore.RGBColor?
    var label: String
    var pick: (TabCore.RGBColor) -> Void
}

/// A shortcut recorder for one keymap action.
struct ShortcutSpec {
    var chord: KeyChord?
    var placeholder: String
    var label: String
    /// Returns an error, such as a conflict, or `nil` when the chord was taken.
    var record: (KeyChord) -> String?
    var error: (String?) -> Void
}
