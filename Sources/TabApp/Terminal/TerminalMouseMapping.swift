import AppKit
import TabCore
import TabProtocol

/// Mouse decisions shared by AppKit event handling and offscreen tests.
public enum TerminalMouseMapping {
    public static func reports(flags: NSEvent.ModifierFlags, modes: InputModes, options: TerminalOptions,
                               live: Bool, wheel: Bool = false) -> Bool {
        guard live, options.mouseReporting, !flags.contains(.shift) else { return false }
        return modes.mouseTracking || wheel && modes.alternateScroll
    }

    public static func event(action: MouseAction, button: MouseButton?, scroll: ScrollDirection? = nil,
                             location: CGPoint, layout: TerminalLayout, flags: NSEvent.ModifierFlags) -> MouseEvent {
        let column = min(max(Int(floor((location.x - layout.grid.minX) / layout.cellWidth)), 0), Int(layout.viewport.cols) - 1)
        let row = min(max(Int(floor((location.y - layout.grid.minY) / layout.cellHeight)), 0), Int(layout.viewport.rows) - 1)
        var modifiers = KeyMapping.keyModifiers(flags)
        modifiers.remove([.super, .capsLock])
        return MouseEvent(action: action, button: button, scroll: scroll, col: UInt16(column), row: UInt16(row),
                          modifiers: modifiers)
    }

    public static func scrollRows(delta: CGFloat, precise: Bool, cellHeight: CGFloat, options: TerminalOptions) -> CGFloat {
        precise ? delta / max(cellHeight, 1) * CGFloat(options.scrollPrecision) : delta * CGFloat(options.scrollDiscrete)
    }
}

/// Fractional scroll input, with the same reversal and flood limits as Codesh.
struct TerminalScrollAccumulator {
    private(set) var remainder: CGFloat = 0

    mutating func reset() { remainder = 0 }

    mutating func consume(_ rows: CGFloat, reporting: Bool) -> Int {
        guard rows.isFinite else { return 0 }
        if reporting, rows.sign != remainder.sign { remainder = 0 }
        remainder += rows
        if reporting { remainder = min(max(remainder, -100), 100) }
        let whole = Int(remainder.rounded(.towardZero))
        remainder -= CGFloat(whole)
        return whole
    }
}
