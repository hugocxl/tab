import CGhosttyVT
import Foundation

/// Small helpers over the libghostty-vt C API.
enum Ghostty {
    static func check(_ result: GhosttyResult, _ step: TerminalStep) throws {
        guard result == GHOSTTY_SUCCESS else { throw TerminalError(step, .engine(result.rawValue)) }
    }

    static func point(_ tag: GhosttyPointTag, x: UInt16, y: UInt32) -> GhosttyPoint {
        GhosttyPoint(tag: tag, value: GhosttyPointValue(coordinate: GhosttyPointCoordinate(x: x, y: y)))
    }

    static func string(_ value: GhosttyString) -> String {
        guard let pointer = value.ptr, value.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: value.len), as: UTF8.self)
    }

    static func gridRef() -> GhosttyGridRef {
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        return ref
    }

    static func style() -> GhosttyStyle {
        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        return style
    }

    static func selection(_ start: GhosttyGridRef, _ end: GhosttyGridRef, rectangle: Bool) -> GhosttySelection {
        GhosttySelection(size: MemoryLayout<GhosttySelection>.size, start: start, end: end, rectangle: rectangle)
    }
}

/// DEC private modes the wrapper reads or sets (`ghostty_mode_new(value, false)`).
enum DECMode {
    static let cursorKeys: GhosttyMode = 1
    static let cursorBlinking: GhosttyMode = 12
    static let focusEvents: GhosttyMode = 1004
    static let alternateScroll: GhosttyMode = 1007
    static let bracketedPaste: GhosttyMode = 2004
    static let synchronizedOutput: GhosttyMode = 2026
    static let graphemeCluster: GhosttyMode = 2027
    static let colorSchemeReport: GhosttyMode = 2031
}

extension GhosttyColorRgb {
    init(_ rgb: ThemeColor) {
        self.init(r: rgb.r, g: rgb.g, b: rgb.b)
    }

    var rgb: ThemeColor { ThemeColor(r, g, b) }
}
