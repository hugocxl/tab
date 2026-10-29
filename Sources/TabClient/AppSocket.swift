import Darwin
import Foundation
import TabProtocol

/// Any JSON value, for browser command arguments and results.
public enum JSONValue: Hashable, Sendable, Codable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Compact JSON, keys sorted.
    public var description: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}

/// A request to the desktop app over `app.sock`: one JSON request, after which
/// the client closes its writing side, and one JSON reply, after which the app
/// closes the connection.
///
///     {"type":"open","path":"/Users/me/code/app"}
///     {"type":"browser","command":"click","args":{"tabId":"…","selector":"#go"}}
public enum AppRequest: Hashable, Sendable, Codable {
    /// Opens a folder as a project, selecting it if it is one already.
    case open(path: String)
    /// A browser automation command; see `BrowserCommand` for the names and
    /// their arguments.
    case browser(command: String, args: [String: JSONValue])
    /// A request from a newer `tab`; answer with an error.
    case unknown(String)

    private enum Keys: String, CodingKey { case type, path, command, args }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "open": self = .open(path: try container.decode(String.self, forKey: .path))
        case "browser":
            self = .browser(command: try container.decode(String.self, forKey: .command),
                            args: try container.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:])
        default: self = .unknown(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .open(let path):
            try container.encode("open", forKey: .type)
            try container.encode(path, forKey: .path)
        case .browser(let command, let args):
            try container.encode("browser", forKey: .type)
            try container.encode(command, forKey: .command)
            try container.encode(args, forKey: .args)
        case .unknown(let type):
            try container.encode(type, forKey: .type)
        }
    }
}

/// The app's answer:
///
///     {"ok":true,"result":…}
///     {"ok":false,"error":"No tab with that ID"}
public enum AppReply: Hashable, Sendable, Codable {
    case ok(JSONValue)
    case failed(String)

    private enum Keys: String, CodingKey { case ok, result, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .ok) == true {
            self = .ok(try container.decodeIfPresent(JSONValue.self, forKey: .result) ?? .null)
        } else {
            self = .failed(try container.decodeIfPresent(String.self, forKey: .error) ?? "Tab did not handle the request")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .ok(let result):
            try container.encode(true, forKey: .ok)
            try container.encode(result, forKey: .result)
        case .failed(let error):
            try container.encode(false, forKey: .ok)
            try container.encode(error, forKey: .error)
        }
    }
}

public enum AppSocketError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Nothing listens: the app isn't running.
    case notRunning
    case noResponse
    case transport(String)
    /// The app answered with an error.
    case failed(String)

    public var description: String {
        switch self {
        case .notRunning: "the Tab app is not running"
        case .noResponse: "no response from Tab"
        case .transport(let message): "could not reach Tab: \(message)"
        case .failed(let message): message
        }
    }
}

extension AppSocketError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Both sides of `app.sock`.
public enum AppSocket {
    public static let maxRequestBytes = 8 * 1024 * 1024
    public static let maxReplyBytes = 128 * 1024 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// Sends `request` and waits up to `timeout` for the reply; an error reply
    /// throws `failed`.
    public static func call(socket: URL, _ request: AppRequest, timeout: TimeInterval) throws -> JSONValue {
        let stream: FileDescriptorStream
        do {
            stream = try FileDescriptorStream.connect(unixSocket: socket.path)
        } catch let error as TransportError where LocalServer.unavailable(error) {
            throw AppSocketError.notRunning
        } catch {
            throw AppSocketError.transport(String(describing: error))
        }
        let done = DispatchSemaphore(value: 0)
        let timedOut = Flag()
        DispatchQueue.global().async {
            if done.wait(timeout: .now() + timeout) == .timedOut {
                timedOut.set()
                stream.close()
            }
        }
        defer {
            done.signal()
            stream.close()
        }
        let data: Data
        do {
            try stream.write(try encode(request))
            shutdown(stream.writeDescriptor, SHUT_WR)
            data = try readAll(stream, limit: maxReplyBytes)
        } catch {
            if timedOut.isSet { throw AppSocketError.noResponse }
            throw AppSocketError.transport(String(describing: error))
        }
        if timedOut.isSet || data.isEmpty { throw AppSocketError.noResponse }
        guard let reply = try? JSONDecoder().decode(AppReply.self, from: data) else {
            throw AppSocketError.failed("invalid reply from Tab")
        }
        switch reply {
        case .ok(let result): return result
        case .failed(let error): throw AppSocketError.failed(error)
        }
    }

    static func readAll(_ stream: ByteStream, limit: Int) throws -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= limit {
            let count = try chunk.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { return data }
            data.append(contentsOf: chunk[0 ..< count])
        }
        throw AppSocketError.transport("the message is too large")
    }
}

/// The app's side of `app.sock`: accepts connections on a background thread
/// and answers each request with `handler`. Only this user can open the socket.
public final class AppSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AppRequest) async -> AppReply

    private let listener: UnixSocketListener

    public init(socket: URL, handler: @escaping Handler) throws {
        listener = try UnixSocketListener(path: socket.path)
        chmod(socket.path, 0o600)
        let listener = listener
        let thread = Thread {
            while let client = try? listener.accept() {
                Task.detached { await Self.serve(client, handler) }
            }
        }
        thread.name = "TabClient.app-socket"
        thread.start()
    }

    deinit {
        listener.close()
    }

    /// Stops accepting and removes the socket.
    public func close() {
        listener.close()
    }

    private static func serve(_ client: FileDescriptorStream, _ handler: Handler) async {
        let request = try? await blocking { try AppSocket.readAll(client, limit: AppSocket.maxRequestBytes) }
        let reply: AppReply
        if let request, let decoded = try? JSONDecoder().decode(AppRequest.self, from: request) {
            reply = await handler(decoded)
        } else {
            reply = .failed("invalid request")
        }
        if let data = try? AppSocket.encode(reply) {
            try? client.write(data)
        }
        client.close()
    }
}

/// The browser automation commands `tab browser` sends as
/// `{"type":"browser","command":<rawValue>,"args":{…}}`. Every command but
/// `open` and `list` names its tab with `"tabId"`. Element commands take a CSS
/// `"selector"` and answer `false` when nothing matches. Waits take an
/// optional `"timeoutMs"` (capped at 60000).
public enum BrowserCommand: String, Hashable, Sendable, CaseIterable {
    /// `url?`, `split`, `project?`, `worktree?`, `profile?` → the new tab's ID (string).
    case open
    /// `project?`, `worktree?` → `[{"tabId","title","url","profile","active"}]`.
    case list
    /// `url` → `true`.
    case navigate
    /// → `{"title","url","text"}`.
    case read
    case close
    case reload
    case back
    case forward
    /// → `{"png": base64}`.
    case screenshot
    /// `script` → the script's result.
    case evaluate
    case click
    case hover
    case scrollIntoView
    /// `selector`, `checked`.
    case setChecked
    /// `selector`, `text`.
    case fill
    /// `selector`, `text`, `submit`.
    case type
    /// `key`, `selector?`.
    case press
    /// `selector`, `value`.
    case select
    /// `property` (visible, hidden, enabled, disabled, checked), `selector` → Bool.
    case `is`
    case getText
    case getValue
    case getCount
    /// `selector`, `attribute`.
    case getAttribute
    /// `selector?`.
    case getHTML
    /// `kind` (role, text, label, placeholder, testid), `value`.
    case find
    /// `selector?` → interactive elements, each with a `selector`.
    case snapshot
    /// `selector?`, `text?`, `urlContains?`, `function?`, `timeoutMs?`.
    case wait
    /// `selector`, `timeoutMs?`.
    case waitFor
    /// `timeoutMs?`.
    case waitForNavigation
    /// `key`, `kind` (local, session).
    case storageGet = "storage.get"
    /// `key`, `value`, `kind`.
    case storageSet = "storage.set"
    /// `kind`.
    case storageClear = "storage.clear"
    /// `url?`.
    case cookiesGet = "cookies.get"
    /// `name`, `value`, `domain`, `path?`, `secure?`, `httpOnly?`, `expires?` (Unix seconds).
    case cookiesSet = "cookies.set"
    /// `name`, `domain?`.
    case cookiesDelete = "cookies.delete"
    case cookiesClear = "cookies.clear"

    /// How long a wait may take by default, and at most.
    public static let defaultWait: TimeInterval = 5
    public static let defaultNavigationWait: TimeInterval = 10
    public static let maxWait: TimeInterval = 60
}
