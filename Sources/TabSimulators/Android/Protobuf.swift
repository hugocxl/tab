import Foundation

/// Writes Protocol Buffers messages: just the field types the emulator's
/// control API uses. Fields equal to their default are left out, as proto3
/// does.
struct ProtobufWriter {
    private(set) var data = Data()

    mutating func varint(_ field: Int, _ value: UInt64) {
        guard value != 0 else { return }
        key(field, wireType: 0)
        Self.appendVarint(value, to: &data)
    }

    mutating func int32(_ field: Int, _ value: Int32) {
        varint(field, UInt64(bitPattern: Int64(value)))
    }

    mutating func string(_ field: Int, _ value: String) {
        guard !value.isEmpty else { return }
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: Int, _ value: ProtobufWriter) {
        bytes(field, value.data)
    }

    /// A packed repeated `float` field.
    mutating func floats(_ field: Int, _ values: [Float]) {
        var packed = Data()
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { packed.append(contentsOf: $0) }
        }
        bytes(field, packed)
    }

    private mutating func bytes(_ field: Int, _ value: Data) {
        key(field, wireType: 2)
        Self.appendVarint(UInt64(value.count), to: &data)
        data.append(value)
    }

    private mutating func key(_ field: Int, wireType: UInt64) {
        Self.appendVarint(UInt64(field) << 3 | wireType, to: &data)
    }

    static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }
}

/// Reads the fields of one Protocol Buffers message, skipping ones it
/// doesn't ask for.
struct ProtobufReader {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed(UInt64)
    }

    private let data: Data

    init(_ data: Data) {
        self.data = data
    }

    /// Every field, in order; stops at the first malformed one.
    var fields: [(field: Int, value: Value)] {
        var fields: [(Int, Value)] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard let key = Self.varint(data, &index) else { break }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = Self.varint(data, &index) else { return fields }
                fields.append((field, .varint(value)))
            case 1:
                guard let value = Self.fixed(data, &index, size: 8) else { return fields }
                fields.append((field, .fixed(value)))
            case 2:
                guard let length = Self.varint(data, &index), length <= UInt64(data.endIndex - index) else { return fields }
                let end = index + Int(length)
                fields.append((field, .bytes(data[index..<end])))
                index = end
            case 5:
                guard let value = Self.fixed(data, &index, size: 4) else { return fields }
                fields.append((field, .fixed(value)))
            default:
                return fields
            }
        }
        return fields
    }

    func uint(_ field: Int) -> UInt64? {
        for entry in fields where entry.field == field {
            if case .varint(let value) = entry.value { return value }
        }
        return nil
    }

    func bytes(_ field: Int) -> Data? {
        for entry in fields where entry.field == field {
            if case .bytes(let value) = entry.value { return value }
        }
        return nil
    }

    func message(_ field: Int) -> ProtobufReader? {
        bytes(field).map(ProtobufReader.init)
    }

    private static func varint(_ data: Data, _ index: inout Data.Index) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func fixed(_ data: Data, _ index: inout Data.Index, size: Int) -> UInt64? {
        guard data.endIndex - index >= size else { return nil }
        var value: UInt64 = 0
        for offset in 0..<size { value |= UInt64(data[index + offset]) << (8 * UInt64(offset)) }
        index += size
        return value
    }
}
