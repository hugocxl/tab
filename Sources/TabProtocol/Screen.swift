import Foundation

/// Terminal size in cells.
public struct Size: Hashable, Codable, Sendable {
    public var cols: UInt16
    public var rows: UInt16

    public init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }
}

/// Cell size in physical pixels, reported by the app for graphics placement.
public struct CellSize: Hashable, Codable, Sendable {
    public var width: UInt16
    public var height: UInt16

    public init(width: UInt16, height: UInt16) {
        self.width = width
        self.height = height
    }
}

public enum Color: Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public enum Underline: UInt8, Hashable, Codable, Sendable {
    case none = 0
    case single = 1
    case double = 2
    case curly = 3
    case dotted = 4
    case dashed = 5
}

public enum CursorShape: UInt8, Hashable, Codable, Sendable {
    case block = 0
    case bar = 1
    case underline = 2
    case hollow = 3
}

/// The style shared by one run of cells.
public struct Style: Hashable, Sendable {
    public var fg: Color = .default
    public var bg: Color = .default
    public var bold = false
    public var italic = false
    public var underline: Underline = .none
    public var underlineColor: Color = .default
    public var invisible = false
    public var overline = false
    public var inverse = false
    public var strikethrough = false
    public var faint = false
    /// A hyperlink id (OSC 8) scoped to the session, or 0.
    public var hyperlink: UInt32 = 0

    public init() {}
}

/// Text that shares one style. `width` is the number of cells it covers, so
/// clients need no Unicode width tables.
public struct Run: Hashable, Sendable {
    public var text: String
    public var width: UInt16
    public var style: Style

    public init(text: String, width: UInt16, style: Style = Style()) {
        self.text = text
        self.width = width
        self.style = style
    }
}

public struct Row: Hashable, Sendable {
    public var index: UInt16
    public var runs: [Run]

    public init(index: UInt16, runs: [Run]) {
        self.index = index
        self.runs = runs
    }
}

public struct Cursor: Hashable, Codable, Sendable {
    public var shape: CursorShape
    public var row: UInt16
    public var col: UInt16
    public var visible: Bool

    public init(shape: CursorShape = .block, row: UInt16 = 0, col: UInt16 = 0, visible: Bool = true) {
        self.shape = shape
        self.row = row
        self.col = col
        self.visible = visible
    }
}

/// Modes the app needs to encode input correctly.
public struct Modes: Hashable, Codable, Sendable {
    public var applicationCursorKeys = false
    public var bracketedPaste = false

    public init() {}
}

/// Modes that change how the app treats the mouse and focus.
public struct InputModes: Hashable, Codable, Sendable {
    public var mouseTracking = false
    public var alternateScroll = false
    public var focusEvents = false

    public init() {}
}

public struct GraphicImage: Hashable, Sendable {
    public var id: UInt32
    public var generation: UInt64
    public var width: UInt32
    public var height: UInt32
    /// Premultiplied RGBA8, `width * height * 4` bytes.
    public var rgba: Data

    public init(id: UInt32, generation: UInt64, width: UInt32, height: UInt32, rgba: Data) {
        self.id = id
        self.generation = generation
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

public struct GraphicPlacement: Hashable, Sendable {
    public var image: UInt32
    public var id: UInt32
    public var column: Int32
    public var row: Int32
    /// Pixel offset inside the first cell.
    public var offset: (x: UInt32, y: UInt32)
    /// Size in cells.
    public var size: (cols: UInt32, rows: UInt32)
    /// Source rectangle in the image, in pixels: x, y, width, height.
    public var source: (x: UInt32, y: UInt32, width: UInt32, height: UInt32)
    public var z: Int32

    public init(image: UInt32, id: UInt32, column: Int32, row: Int32,
                offset: (x: UInt32, y: UInt32), size: (cols: UInt32, rows: UInt32),
                source: (x: UInt32, y: UInt32, width: UInt32, height: UInt32), z: Int32) {
        self.image = image
        self.id = id
        self.column = column
        self.row = row
        self.offset = offset
        self.size = size
        self.source = source
        self.z = z
    }

    public static func == (lhs: GraphicPlacement, rhs: GraphicPlacement) -> Bool {
        lhs.image == rhs.image && lhs.id == rhs.id && lhs.column == rhs.column && lhs.row == rhs.row
            && lhs.offset == rhs.offset && lhs.size == rhs.size && lhs.source == rhs.source && lhs.z == rhs.z
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(image)
        hasher.combine(id)
        hasher.combine(column)
        hasher.combine(row)
        hasher.combine(z)
    }
}

/// Kitty graphics state of a screen: images referenced by placements.
public struct Graphics: Hashable, Sendable {
    public var cell: CellSize
    public var images: [GraphicImage]
    public var placements: [GraphicPlacement]

    public init(cell: CellSize, images: [GraphicImage] = [], placements: [GraphicPlacement] = []) {
        self.cell = cell
        self.images = images
        self.placements = placements
    }
}

/// One screen update: only the rows that changed, unless `reset`.
public struct ScreenFrame: Hashable, Sendable {
    public var size: Size
    public var seq: UInt64
    /// The whole screen follows: drop every cached row first.
    public var reset: Bool
    public var rows: [Row]
    public var cursor: Cursor
    public var modes: Modes
    public var graphics: Graphics?
    /// Rows of history above the screen, for the scrollbar.
    public var historyRows: UInt64

    public init(size: Size, seq: UInt64, reset: Bool, rows: [Row], cursor: Cursor,
                modes: Modes = Modes(), graphics: Graphics? = nil, historyRows: UInt64 = 0) {
        self.size = size
        self.seq = seq
        self.reset = reset
        self.rows = rows
        self.cursor = cursor
        self.modes = modes
        self.graphics = graphics
        self.historyRows = historyRows
    }
}

// MARK: - Input

public struct KeyModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let alt = KeyModifiers(rawValue: 1 << 2)
    public static let `super` = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
    public static let numLock = KeyModifiers(rawValue: 1 << 5)
}

public enum KeyAction: UInt8, Hashable, Codable, Sendable {
    case press = 0
    case release = 1
    case `repeat` = 2
}

/// A physical key event, encoded on the server by the engine so every
/// keyboard protocol (legacy, kitty) is handled in one place.
public struct KeyEvent: Hashable, Codable, Sendable {
    /// The key name in Ghostty's vocabulary, e.g. `a`, `enter`, `arrow_up`, `f1`.
    public var key: String
    public var action: KeyAction
    public var modifiers: KeyModifiers
    public var consumedModifiers: KeyModifiers
    /// Text the key produced after modifiers and the input method.
    public var text: String
    public var unshiftedCodepoint: UInt32
    public var optionAsAlt: Bool

    public init(key: String, action: KeyAction = .press, modifiers: KeyModifiers = [],
                consumedModifiers: KeyModifiers = [], text: String = "",
                unshiftedCodepoint: UInt32 = 0, optionAsAlt: Bool = false) {
        self.key = key
        self.action = action
        self.modifiers = modifiers
        self.consumedModifiers = consumedModifiers
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
        self.optionAsAlt = optionAsAlt
    }
}

public enum MouseAction: UInt8, Hashable, Codable, Sendable {
    case press = 0
    case release = 1
    case motion = 2
    case scroll = 3
}

public enum MouseButton: UInt8, Hashable, Codable, Sendable {
    case left = 0
    case middle = 1
    case right = 2
    case back = 3
    case forward = 4
}

public enum ScrollDirection: UInt8, Hashable, Codable, Sendable {
    case up = 0
    case down = 1
}

/// A mouse event in cell coordinates, encoded by the engine for programs
/// that track the mouse.
public struct MouseEvent: Hashable, Codable, Sendable {
    public var action: MouseAction
    public var button: MouseButton?
    public var scroll: ScrollDirection?
    public var col: UInt16
    public var row: UInt16
    public var modifiers: KeyModifiers

    public init(action: MouseAction, button: MouseButton? = nil, scroll: ScrollDirection? = nil,
                col: UInt16, row: UInt16, modifiers: KeyModifiers = []) {
        self.action = action
        self.button = button
        self.scroll = scroll
        self.col = col
        self.row = row
        self.modifiers = modifiers
    }
}

/// Input a client sends on a session channel.
public enum TerminalInput: Hashable, Codable, Sendable {
    /// Raw bytes, already encoded by the client (pastes, CLI `send`).
    case bytes(Data)
    /// Text typed or composed; the engine encodes it (bracketed paste aware).
    case text(String)
    case key(KeyEvent)
    case mouse(MouseEvent)
    case paste(String)
    case focus(Bool)
}
