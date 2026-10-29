import Foundation

/// JSON for every protocol message and persisted protocol type.
///
/// Decoding is tolerant: unknown keys are ignored, and a missing key whose type
/// has a natural empty value (`WireDefaultable`: false, 0, "", [], [:], nil)
/// decodes as that value, so builds can add fields without breaking each other.
public enum WireJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(TolerantBox<T>.self, from: data).value
    }
}

/// A type with a value that stands in for a missing key.
public protocol WireDefaultable {
    static var wireDefault: Self { get }
}

extension Bool: WireDefaultable { public static var wireDefault: Bool { false } }
extension String: WireDefaultable { public static var wireDefault: String { "" } }
extension Int: WireDefaultable { public static var wireDefault: Int { 0 } }
extension Int8: WireDefaultable { public static var wireDefault: Int8 { 0 } }
extension Int16: WireDefaultable { public static var wireDefault: Int16 { 0 } }
extension Int32: WireDefaultable { public static var wireDefault: Int32 { 0 } }
extension Int64: WireDefaultable { public static var wireDefault: Int64 { 0 } }
extension UInt: WireDefaultable { public static var wireDefault: UInt { 0 } }
extension UInt8: WireDefaultable { public static var wireDefault: UInt8 { 0 } }
extension UInt16: WireDefaultable { public static var wireDefault: UInt16 { 0 } }
extension UInt32: WireDefaultable { public static var wireDefault: UInt32 { 0 } }
extension UInt64: WireDefaultable { public static var wireDefault: UInt64 { 0 } }
extension Double: WireDefaultable { public static var wireDefault: Double { 0 } }
extension Data: WireDefaultable { public static var wireDefault: Data { Data() } }
extension Array: WireDefaultable { public static var wireDefault: [Element] { [] } }
extension Dictionary: WireDefaultable { public static var wireDefault: [Key: Value] { [:] } }
extension Optional: WireDefaultable { public static var wireDefault: Wrapped? { nil } }

/// An enum of strings that keeps values from newer builds as `unknown`.
public protocol OpenEnum: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    static var knownCases: [Self] { get }
    static func unknown(_ rawValue: String) -> Self
}

extension OpenEnum {
    public init(rawValue: String) {
        self = Self.resolve(rawValue)
    }

    public init(from decoder: Decoder) throws {
        self = Self.resolve(try decoder.singleValueContainer().decode(String.self))
    }

    private static func resolve(_ rawValue: String) -> Self {
        knownCases.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Whether this build knows the value.
    public var isKnown: Bool { Self.knownCases.contains(self) }
}

// MARK: - Type-discriminated enums

struct TagKey: CodingKey, ExpressibleByStringLiteral {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(stringLiteral value: String) { stringValue = value }
}

/// Reads an enum encoded as `{"type": "...", ...fields}`.
struct TaggedDecoding {
    let container: KeyedDecodingContainer<TagKey>
    let type: String

    init(_ decoder: Decoder) throws {
        container = try decoder.container(keyedBy: TagKey.self)
        type = try container.decode(String.self, forKey: "type")
    }

    /// Reads the fields of a struct written without a `type`.
    init(fields decoder: Decoder) throws {
        container = try decoder.container(keyedBy: TagKey.self)
        type = ""
    }

    /// A field; a missing defaultable one reads as its default.
    func callAsFunction<T: Decodable>(_ key: String) throws -> T {
        let key = TagKey(key)
        if !container.contains(key), let fallback = (T.self as? WireDefaultable.Type)?.wireDefault as? T {
            return fallback
        }
        return try container.decode(T.self, forKey: key)
    }

    func callAsFunction<T: Decodable>(_ key: String, default fallback: T) throws -> T {
        try container.decodeIfPresent(T.self, forKey: TagKey(key)) ?? fallback
    }
}

/// Writes an enum as `{"type": "...", ...fields}`; `nil` fields are left out.
struct TaggedEncoding {
    var container: KeyedEncodingContainer<TagKey>

    @discardableResult
    init(_ encoder: Encoder, _ type: String) throws {
        container = encoder.container(keyedBy: TagKey.self)
        try container.encode(type, forKey: "type")
    }

    /// Writes the fields of a struct, without a `type`.
    init(fields encoder: Encoder) {
        container = encoder.container(keyedBy: TagKey.self)
    }

    mutating func callAsFunction<T: Encodable>(_ value: T, _ key: String) throws {
        try container.encode(value, forKey: TagKey(key))
    }

    mutating func callAsFunction<T: Encodable>(_ value: T?, _ key: String) throws {
        try container.encodeIfPresent(value, forKey: TagKey(key))
    }
}

// MARK: - Tolerant decoder

private struct TolerantBox<T: Decodable>: Decodable {
    let value: T
    init(from decoder: Decoder) throws {
        value = try tolerantValue(T.self, from: decoder)
    }
}

/// Types JSONDecoder reads in its own way (Data as base64, for instance), so
/// they must go through its containers rather than their own `init(from:)`.
private func isLeaf(_ type: Any.Type) -> Bool {
    type == Data.self || type == Date.self || type == URL.self || type == Decimal.self
}

private func tolerantValue<T: Decodable>(_ type: T.Type, from decoder: Decoder) throws -> T {
    if isLeaf(T.self) {
        return try decoder.singleValueContainer().decode(T.self)
    }
    return try T(from: TolerantDecoder(base: decoder))
}

private protocol TolerantPrimitive {}
extension Bool: TolerantPrimitive {}
extension String: TolerantPrimitive {}
extension Int: TolerantPrimitive {}
extension Int8: TolerantPrimitive {}
extension Int16: TolerantPrimitive {}
extension Int32: TolerantPrimitive {}
extension Int64: TolerantPrimitive {}
extension UInt: TolerantPrimitive {}
extension UInt8: TolerantPrimitive {}
extension UInt16: TolerantPrimitive {}
extension UInt32: TolerantPrimitive {}
extension UInt64: TolerantPrimitive {}
extension Double: TolerantPrimitive {}
extension Float: TolerantPrimitive {}

private func fallback<T>(_ type: T.Type) -> T? {
    (T.self as? WireDefaultable.Type)?.wireDefault as? T
}

private struct TolerantDecoder: Decoder {
    let base: Decoder
    var codingPath: [CodingKey] { base.codingPath }
    var userInfo: [CodingUserInfoKey: Any] { base.userInfo }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(TolerantKeyed(base: try base.container(keyedBy: Key.self)))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        TolerantUnkeyed(base: try base.unkeyedContainer())
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        TolerantSingle(base: try base.singleValueContainer(), decoder: base)
    }
}

private struct TolerantSingle: SingleValueDecodingContainer {
    let base: SingleValueDecodingContainer
    let decoder: Decoder
    var codingPath: [CodingKey] { base.codingPath }

    func decodeNil() -> Bool { base.decodeNil() }
    func decode(_ type: Bool.Type) throws -> Bool { try base.decode(type) }
    func decode(_ type: String.Type) throws -> String { try base.decode(type) }
    func decode(_ type: Double.Type) throws -> Double { try base.decode(type) }
    func decode(_ type: Float.Type) throws -> Float { try base.decode(type) }
    func decode(_ type: Int.Type) throws -> Int { try base.decode(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try base.decode(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try base.decode(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try base.decode(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try base.decode(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try base.decode(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try base.decode(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try base.decode(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try base.decode(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try base.decode(type) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if isLeaf(T.self) { return try base.decode(type) }
        return try T(from: TolerantDecoder(base: decoder))
    }
}

private struct TolerantKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let base: KeyedDecodingContainer<Key>
    var codingPath: [CodingKey] { base.codingPath }
    var allKeys: [Key] { base.allKeys }

    func contains(_ key: Key) -> Bool { base.contains(key) }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard base.contains(key) else { return true }
        return try base.decodeNil(forKey: key)
    }

    private func value<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T {
        if let fallback = fallback(T.self), try decodeNil(forKey: key) {
            return fallback
        }
        if isLeaf(T.self) || T.self is any TolerantPrimitive.Type {
            return try base.decode(T.self, forKey: key)
        }
        return try T(from: TolerantDecoder(base: try base.superDecoder(forKey: key)))
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try value(type, key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try value(type, key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try value(type, key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try base.decode(type, forKey: key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try value(type, key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try value(type, key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try value(type, key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try value(type, key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try value(type, key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try value(type, key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try value(type, key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try value(type, key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try value(type, key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try value(type, key) }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try value(type, key) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
        -> KeyedDecodingContainer<NestedKey> {
        KeyedDecodingContainer(TolerantKeyed<NestedKey>(base: try base.nestedContainer(keyedBy: type, forKey: key)))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        TolerantUnkeyed(base: try base.nestedUnkeyedContainer(forKey: key))
    }

    func superDecoder() throws -> Decoder { TolerantDecoder(base: try base.superDecoder()) }
    func superDecoder(forKey key: Key) throws -> Decoder { TolerantDecoder(base: try base.superDecoder(forKey: key)) }
}

private struct TolerantUnkeyed: UnkeyedDecodingContainer {
    var base: UnkeyedDecodingContainer
    var codingPath: [CodingKey] { base.codingPath }
    var count: Int? { base.count }
    var isAtEnd: Bool { base.isAtEnd }
    var currentIndex: Int { base.currentIndex }

    mutating func decodeNil() throws -> Bool { try base.decodeNil() }
    mutating func decode(_ type: Bool.Type) throws -> Bool { try base.decode(type) }
    mutating func decode(_ type: String.Type) throws -> String { try base.decode(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { try base.decode(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try base.decode(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try base.decode(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try base.decode(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try base.decode(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try base.decode(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try base.decode(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try base.decode(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try base.decode(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try base.decode(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try base.decode(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try base.decode(type) }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if isLeaf(T.self) || T.self is any TolerantPrimitive.Type {
            return try base.decode(type)
        }
        return try T(from: TolerantDecoder(base: try base.superDecoder()))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey> {
        KeyedDecodingContainer(TolerantKeyed<NestedKey>(base: try base.nestedContainer(keyedBy: type)))
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        TolerantUnkeyed(base: try base.nestedUnkeyedContainer())
    }

    mutating func superDecoder() throws -> Decoder { TolerantDecoder(base: try base.superDecoder()) }
}
