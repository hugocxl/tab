import Foundation

/// A settings problem, naming the setting it is about.
public struct SettingsError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The setting, such as `keymap.split_right` or a file path.
    public let key: String
    public let message: String

    public init(_ key: String, _ message: String) {
        self.key = key
        self.message = message
    }

    public var description: String { "\(key): \(message)" }
    public var errorDescription: String? { description }
}

extension KeyedDecodingContainer {
    /// The value at `key`, or `fallback` when the key is missing or null.
    /// Present values of the wrong type still fail.
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

/// How settings files are written: pretty, with sorted keys, so hand edits
/// and diffs stay readable.
enum SettingsJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder().encode(value)
        data.append(0x0A)
        return data
    }

    /// `value` as a JSON object tree.
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encoder().encode(value), options: [.fragmentsAllowed])
    }

    static func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(type, from: data)
    }

    /// A readable reason a decode failed, naming the field.
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(path(context)): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            let prefix = path(context)
            return "\(prefix.isEmpty ? "" : prefix + ".")\(key.stringValue) is missing"
        case .dataCorrupted(let context):
            let prefix = path(context)
            let underlying = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            let message = underlying ?? context.debugDescription
            return prefix.isEmpty ? message : "\(prefix): \(message)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

/// A settings file as a JSON object, edited section by section so values
/// written by hand or by another window since loading are kept.
struct SettingsDocument {
    var root: [String: Any]

    /// The file's object; empty when the file is missing. A file that is not
    /// a JSON object is an error, so it is never overwritten.
    static func read(_ url: URL) throws -> SettingsDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return SettingsDocument(root: [:])
        } catch {
            throw SettingsError(url.path, error.localizedDescription)
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return SettingsDocument(root: [:])
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsError(url.path, "is not a valid JSON object")
        }
        return SettingsDocument(root: root)
    }

    func write(to url: URL) throws {
        do {
            var data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            data.append(0x0A)
            try AtomicFile.write(data, to: url)
        } catch let error as SettingsError {
            throw error
        } catch {
            throw SettingsError(url.path, error.localizedDescription)
        }
    }

    /// Sets each key of `section` to the encoded value's, keeping keys the
    /// value does not have.
    mutating func merge<T: Encodable>(_ section: String, _ value: T) throws {
        guard let values = try SettingsJSON.object(value) as? [String: Any] else {
            throw SettingsError(section, "must be an object")
        }
        var target = root[section] as? [String: Any] ?? [:]
        if root[section] != nil && !(root[section] is [String: Any]) {
            throw SettingsError(section, "must be an object")
        }
        target.merge(values) { _, new in new }
        root[section] = target
    }

    /// Replaces `section` with the encoded value.
    mutating func replace<T: Encodable>(_ section: String, _ value: T) throws {
        root[section] = try SettingsJSON.object(value)
    }

    /// Sets or removes keys of the object `section.table`.
    mutating func setEntries(_ section: String, _ table: String, _ entries: [(String, Any?)]) throws {
        if root[section] != nil && !(root[section] is [String: Any]) {
            throw SettingsError(section, "must be an object")
        }
        var values = root[section] as? [String: Any] ?? [:]
        var target = values[table] as? [String: Any] ?? [:]
        for (key, value) in entries {
            target[key] = value
        }
        values[table] = target
        root[section] = values
    }
}

/// Reads `url`, first writing `defaults` there when it does not exist.
func readOrCreate(_ url: URL, defaults: () throws -> Data) throws -> Data {
    if let data = try? Data(contentsOf: url) { return data }
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw SettingsError(url.path, "could not be read")
    }
    let data = try defaults()
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if descriptor < 0 {
            if errno == EEXIST { return try Data(contentsOf: url) }
            throw posixError(path: url.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return data
    } catch let error as SettingsError {
        throw error
    } catch {
        throw SettingsError(url.path, error.localizedDescription)
    }
}

extension String {
    var hasControlCharacter: Bool {
        unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
