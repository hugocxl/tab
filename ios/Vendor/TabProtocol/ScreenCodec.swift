import Foundation

/// Why bytes are not a screen encoding.
public enum ScreenCodecError: Error, Hashable, Sendable {
    /// The bytes end inside a value.
    case truncated
    /// A newer, incompatible format.
    case unsupportedVersion(UInt8)
    /// A value is out of range, such as an unknown color tag.
    case invalid(String)
    /// Bytes are left after the value.
    case trailingBytes
}

/// The compact binary form of screens and rows: little-endian fixed-width
/// numbers, LEB128 lengths and counts, UTF-8 text. Every top-level encoding
/// starts with `formatVersion`. Saved history on disk uses `encodeRows`.
///
/// Layout (version 1):
/// - frame: version u8, flags u8 (1 reset, 2 graphics, 4 cursor visible,
///   8 application cursor keys, 16 bracketed paste), cols u16, rows u16,
///   seq u64, historyRows u64, cursor shape u8, row u16, col u16, rows, graphics?
/// - rows: count, then each row: index u16, run count, runs
/// - run: text length, UTF-8 text, width u16, style
/// - style: flags u16 (bold, italic, invisible, overline, inverse,
///   strikethrough, faint, fg, bg, underline color, hyperlink, underline),
///   then present values in that order; a color is tag u8 (1 indexed, 2 RGB)
///   and its bytes
/// - graphics: cell width u16, height u16, images (id u32, generation u64,
///   width u32, height u32, RGBA length and bytes), placements (image u32,
///   id u32, column i32, row i32, offset 2×u32, size 2×u32, source 4×u32, z i32)
public enum ScreenCodec {
    public static let formatVersion: UInt8 = 1

    // MARK: Frames

    public static func encode(_ frame: ScreenFrame) -> Data {
        var writer = WireWriter(capacity: 64 + frame.rows.count * 96)
        writer.u8(formatVersion)
        var flags: UInt8 = 0
        if frame.reset { flags |= 1 }
        if frame.graphics != nil { flags |= 2 }
        if frame.cursor.visible { flags |= 4 }
        if frame.modes.applicationCursorKeys { flags |= 8 }
        if frame.modes.bracketedPaste { flags |= 16 }
        writer.u8(flags)
        writer.u16(frame.size.cols)
        writer.u16(frame.size.rows)
        writer.u64(frame.seq)
        writer.u64(frame.historyRows)
        writer.u8(frame.cursor.shape.rawValue)
        writer.u16(frame.cursor.row)
        writer.u16(frame.cursor.col)
        writer.rows(frame.rows)
        if let graphics = frame.graphics {
            writer.graphics(graphics)
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> ScreenFrame {
        try read(data) { reader in
            let flags = try reader.u8()
            let size = Size(cols: try reader.u16(), rows: try reader.u16())
            let seq = try reader.u64()
            let historyRows = try reader.u64()
            guard let shape = CursorShape(rawValue: try reader.u8()) else {
                throw ScreenCodecError.invalid("cursor shape")
            }
            let cursor = Cursor(shape: shape, row: try reader.u16(), col: try reader.u16(), visible: flags & 4 != 0)
            var modes = Modes()
            modes.applicationCursorKeys = flags & 8 != 0
            modes.bracketedPaste = flags & 16 != 0
            let rows = try reader.rows()
            let graphics = flags & 2 != 0 ? try reader.graphics() : nil
            return ScreenFrame(size: size, seq: seq, reset: flags & 1 != 0, rows: rows, cursor: cursor,
                               modes: modes, graphics: graphics, historyRows: historyRows)
        }
    }

    // MARK: Rows and runs

    public static func encodeRows(_ rows: [Row]) -> Data {
        var writer = WireWriter(capacity: 8 + rows.count * 96)
        writer.u8(formatVersion)
        writer.rows(rows)
        return writer.data
    }

    public static func decodeRows(_ data: Data) throws -> [Row] {
        try read(data) { try $0.rows() }
    }

    public static func encodeRow(_ row: Row) -> Data {
        var writer = WireWriter(capacity: 96)
        writer.u8(formatVersion)
        writer.row(row)
        return writer.data
    }

    public static func decodeRow(_ data: Data) throws -> Row {
        try read(data) { try $0.row() }
    }

    public static func encodeRuns(_ runs: [Run]) -> Data {
        var writer = WireWriter(capacity: 8 + runs.count * 32)
        writer.u8(formatVersion)
        writer.runs(runs)
        return writer.data
    }

    public static func decodeRuns(_ data: Data) throws -> [Run] {
        try read(data) { try $0.runs() }
    }

    // MARK: Graphics

    public static func encodeGraphics(_ graphics: Graphics) -> Data {
        var writer = WireWriter(capacity: 64 + graphics.images.reduce(0) { $0 + $1.rgba.count })
        writer.u8(formatVersion)
        writer.graphics(graphics)
        return writer.data
    }

    public static func decodeGraphics(_ data: Data) throws -> Graphics {
        try read(data) { try $0.graphics() }
    }

    private static func read<T>(_ data: Data, _ body: (inout WireReader) throws -> T) throws -> T {
        try data.withUnsafeBytes { buffer in
            var reader = WireReader(buffer)
            let version = try reader.u8()
            guard version == formatVersion else { throw ScreenCodecError.unsupportedVersion(version) }
            let value = try body(&reader)
            guard reader.isAtEnd else { throw ScreenCodecError.trailingBytes }
            return value
        }
    }
}

// MARK: - Writer

struct WireWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    var data: Data { Data(bytes) }

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }

    /// Unsigned LEB128.
    mutating func varint(_ value: Int) {
        var remaining = UInt64(value)
        while remaining >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: remaining) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
    }

    mutating func blob<C: Collection>(_ value: C) where C.Element == UInt8 {
        varint(value.count)
        bytes.append(contentsOf: value)
    }

    mutating func string(_ value: String) {
        var value = value
        value.withUTF8 { blob($0) }
    }

    mutating func color(_ color: Color) {
        switch color {
        case .default:
            break
        case .indexed(let index):
            u8(1)
            u8(index)
        case .rgb(let red, let green, let blue):
            u8(2)
            u8(red)
            u8(green)
            u8(blue)
        }
    }

    mutating func style(_ style: Style) {
        var flags: UInt16 = 0
        if style.bold { flags |= 1 << 0 }
        if style.italic { flags |= 1 << 1 }
        if style.invisible { flags |= 1 << 2 }
        if style.overline { flags |= 1 << 3 }
        if style.inverse { flags |= 1 << 4 }
        if style.strikethrough { flags |= 1 << 5 }
        if style.faint { flags |= 1 << 6 }
        if style.fg != .default { flags |= 1 << 7 }
        if style.bg != .default { flags |= 1 << 8 }
        if style.underlineColor != .default { flags |= 1 << 9 }
        if style.hyperlink != 0 { flags |= 1 << 10 }
        if style.underline != .none { flags |= 1 << 11 }
        u16(flags)
        color(style.fg)
        color(style.bg)
        color(style.underlineColor)
        if style.hyperlink != 0 { u32(style.hyperlink) }
        if style.underline != .none { u8(style.underline.rawValue) }
    }

    mutating func runs(_ runs: [Run]) {
        varint(runs.count)
        for run in runs {
            string(run.text)
            u16(run.width)
            style(run.style)
        }
    }

    mutating func row(_ row: Row) {
        u16(row.index)
        runs(row.runs)
    }

    mutating func rows(_ rows: [Row]) {
        varint(rows.count)
        for row in rows { self.row(row) }
    }

    mutating func graphics(_ graphics: Graphics) {
        u16(graphics.cell.width)
        u16(graphics.cell.height)
        varint(graphics.images.count)
        for image in graphics.images {
            u32(image.id)
            u64(image.generation)
            u32(image.width)
            u32(image.height)
            blob(image.rgba)
        }
        varint(graphics.placements.count)
        for placement in graphics.placements {
            u32(placement.image)
            u32(placement.id)
            i32(placement.column)
            i32(placement.row)
            u32(placement.offset.x)
            u32(placement.offset.y)
            u32(placement.size.cols)
            u32(placement.size.rows)
            u32(placement.source.x)
            u32(placement.source.y)
            u32(placement.source.width)
            u32(placement.source.height)
            i32(placement.z)
        }
    }
}

// MARK: - Reader

/// Bounds-checked reads over borrowed bytes. Never traps on bad input.
struct WireReader {
    private let buffer: UnsafeRawBufferPointer
    private var offset = 0

    init(_ buffer: UnsafeRawBufferPointer) {
        self.buffer = buffer
    }

    var isAtEnd: Bool { offset == buffer.count }
    var remaining: Int { buffer.count - offset }

    private mutating func take(_ count: Int) throws -> UnsafeRawBufferPointer {
        guard count >= 0, count <= remaining else { throw ScreenCodecError.truncated }
        let slice = UnsafeRawBufferPointer(rebasing: buffer[offset ..< offset + count])
        offset += count
        return slice
    }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ScreenCodecError.truncated }
        defer { offset += 1 }
        return buffer[offset]
    }

    mutating func u16() throws -> UInt16 {
        let bytes = try take(2)
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let bytes = try take(4)
        var value: UInt32 = 0
        for index in 0 ..< 4 { value |= UInt32(bytes[index]) << UInt32(index * 8) }
        return value
    }

    mutating func u64() throws -> UInt64 {
        let bytes = try take(8)
        var value: UInt64 = 0
        for index in 0 ..< 8 { value |= UInt64(bytes[index]) << UInt64(index * 8) }
        return value
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func varint() throws -> Int {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try u8()
            if shift == 63, byte > 1 { throw ScreenCodecError.invalid("varint overflow") }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 63 { throw ScreenCodecError.invalid("varint overflow") }
        }
        guard value <= UInt64(Int.max) else { throw ScreenCodecError.invalid("varint overflow") }
        return Int(value)
    }

    /// A count of items each at least `minimumSize` bytes, checked against the
    /// bytes left so a corrupt count never allocates.
    mutating func count(minimumSize: Int) throws -> Int {
        let count = try varint()
        guard count <= remaining / max(minimumSize, 1) else { throw ScreenCodecError.truncated }
        return count
    }

    mutating func blob() throws -> Data {
        let bytes = try take(try varint())
        return Data(bytes)
    }

    mutating func string() throws -> String {
        let bytes = try take(try varint())
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func color() throws -> Color {
        switch try u8() {
        case 1: return .indexed(try u8())
        case 2: return .rgb(try u8(), try u8(), try u8())
        case let tag: throw ScreenCodecError.invalid("color tag \(tag)")
        }
    }

    mutating func style() throws -> Style {
        let flags = try u16()
        var style = Style()
        style.bold = flags & (1 << 0) != 0
        style.italic = flags & (1 << 1) != 0
        style.invisible = flags & (1 << 2) != 0
        style.overline = flags & (1 << 3) != 0
        style.inverse = flags & (1 << 4) != 0
        style.strikethrough = flags & (1 << 5) != 0
        style.faint = flags & (1 << 6) != 0
        if flags & (1 << 7) != 0 { style.fg = try color() }
        if flags & (1 << 8) != 0 { style.bg = try color() }
        if flags & (1 << 9) != 0 { style.underlineColor = try color() }
        if flags & (1 << 10) != 0 { style.hyperlink = try u32() }
        if flags & (1 << 11) != 0 {
            guard let underline = Underline(rawValue: try u8()) else {
                throw ScreenCodecError.invalid("underline")
            }
            style.underline = underline
        }
        return style
    }

    mutating func runs() throws -> [Run] {
        // Text length, width and style flags: at least 5 bytes.
        let count = try count(minimumSize: 5)
        var runs: [Run] = []
        runs.reserveCapacity(count)
        for _ in 0 ..< count {
            let text = try string()
            let width = try u16()
            runs.append(Run(text: text, width: width, style: try style()))
        }
        return runs
    }

    mutating func row() throws -> Row {
        let index = try u16()
        return Row(index: index, runs: try runs())
    }

    mutating func rows() throws -> [Row] {
        let count = try count(minimumSize: 3)
        var rows: [Row] = []
        rows.reserveCapacity(count)
        for _ in 0 ..< count { rows.append(try row()) }
        return rows
    }

    mutating func graphics() throws -> Graphics {
        let cell = CellSize(width: try u16(), height: try u16())
        let imageCount = try count(minimumSize: 21)
        var images: [GraphicImage] = []
        images.reserveCapacity(imageCount)
        for _ in 0 ..< imageCount {
            images.append(GraphicImage(id: try u32(), generation: try u64(), width: try u32(),
                                       height: try u32(), rgba: try blob()))
        }
        let placementCount = try count(minimumSize: 52)
        var placements: [GraphicPlacement] = []
        placements.reserveCapacity(placementCount)
        for _ in 0 ..< placementCount {
            let image = try u32()
            let id = try u32()
            let column = try i32()
            let row = try i32()
            let offset = (x: try u32(), y: try u32())
            let size = (cols: try u32(), rows: try u32())
            let source = (x: try u32(), y: try u32(), width: try u32(), height: try u32())
            placements.append(GraphicPlacement(image: image, id: id, column: column, row: row, offset: offset,
                                               size: size, source: source, z: try i32()))
        }
        return Graphics(cell: cell, images: images, placements: placements)
    }
}
