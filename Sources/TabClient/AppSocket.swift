import Darwin
import Foundation
import TabProtocol

/// Any JSON value, for browser command arguments and results.
public enum JSONValue: Hashable, Sendable, Codable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
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
        } else if let value = try? container.decode(UInt64.self) {
            self = .uint(value)
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
        case .uint(let value): try container.encode(value)
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
///     {"type":"show","pane":{"kind":"agent","session":"…","project":"…","beside":"…"}}
///     {"type":"pane","control":{"action":"close","pane":"right","caller":"…"}}
///     {"verb":"browser.click","args":{"tabId":"…","selector":"#go"}}
public enum AppRequest: Hashable, Sendable, Codable {
    /// Opens a folder as a project, selecting it if it is one already.
    case open(path: String)
    /// A browser automation command; see `BrowserCommand` for the names and
    /// their arguments.
    case browser(command: String, args: [String: JSONValue])
    /// Shows a running terminal or agent conversation in a pane, focusing it.
    case show(AppPane)
    /// Opens a simulator, editor or diff pane.
    case add(AppNewPane)
    /// Lists the panes the app shows, or focuses, closes, zooms, moves or
    /// resizes one.
    case pane(AppPaneControl)
    /// A request from a newer `tab`; answer with an error.
    case unknown(String)

    private enum Keys: String, CodingKey { case verb, args, type, path, pane, control }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let verb = try container.decodeIfPresent(String.self, forKey: .verb) {
            let args = container.contains(.args)
                ? try container.decode([String: JSONValue].self, forKey: .args) : [:]
            guard verb.hasPrefix("browser.") else {
                self = .unknown(verb)
                return
            }
            let command = String(verb.dropFirst("browser.".count))
            self = .browser(command: command == "eval" ? "evaluate" : command, args: args)
            return
        }
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "open": self = .open(path: try container.decode(String.self, forKey: .path))
        case "show": self = .show(try container.decode(AppPane.self, forKey: .pane))
        case "add": self = .add(try container.decode(AppNewPane.self, forKey: .pane))
        case "pane":
            // An action from a newer `tab` is unknown, not an invalid request.
            guard let control = try? container.decode(AppPaneControl.self, forKey: .control) else {
                self = .unknown("pane")
                return
            }
            self = .pane(control)
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
            let verb = command == "evaluate" ? "eval" : command
            try container.encode("browser.\(verb)", forKey: .verb)
            try container.encode(args, forKey: .args)
        case .show(let pane):
            try container.encode("show", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .add(let pane):
            try container.encode("add", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .pane(let control):
            try container.encode("pane", forKey: .type)
            try container.encode(control, forKey: .control)
        case .unknown(let type):
            try container.encode(type, forKey: .verb)
        }
    }
}

/// A pane without a session for the app to open: a simulator, an editor or a
/// diff. An editor or diff already showing its file is focused. Otherwise, as
/// a pane, it opens on the `edge` of the pane `anchor` names, else of the pane
/// showing `beside`, else in `project`; as a tab, it opens as a new tab of the
/// Home `project`.
public struct AppNewPane: Hashable, Sendable, Codable {
    public enum Content: Hashable, Sendable, Codable {
        /// A simulator or emulator; one not chosen shows the simulator picker.
        case simulator(SimulatorPane)
        /// A file, absolute or relative to the project, at a 1-based `line`.
        case editor(path: String, line: Int?)
        /// A file's working tree changes, or its staged ones.
        case diff(path: String, staged: Bool)
    }

    public var content: Content
    public var project: ProjectId
    public var beside: SessionId?
    public var placement: AppPane.Placement
    /// Which side of its neighbor the pane opens on; right when missing.
    public var edge: Direction?
    /// The pane to open beside instead of `beside`'s, as `tab pane` names one.
    public var anchor: String?

    public init(content: Content, project: ProjectId, beside: SessionId? = nil,
                placement: AppPane.Placement = .pane, edge: Direction? = nil, anchor: String? = nil) {
        self.content = content
        self.project = project
        self.beside = beside
        self.placement = placement
        self.edge = edge
        self.anchor = anchor
    }
}

/// A terminal or agent conversation for the app to show. A pane already
/// showing it is focused. Otherwise, as a pane, it opens on the `edge` of the
/// pane `anchor` names, else of the pane showing `beside`, such as the agent
/// or terminal that asked, else in `project`; as a tab, it opens as a new tab
/// of the Home `project`.
public struct AppPane: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case terminal, agent
    }

    /// Where a new pane goes: into an existing tab, or a new tab in Home.
    public enum Placement: String, Hashable, Sendable, Codable {
        case pane, tab
    }

    public var kind: Kind
    public var session: SessionId
    public var project: ProjectId
    /// An agent's provider; Claude Code when missing.
    public var provider: AgentChatProvider?
    public var beside: SessionId?
    public var placement: Placement
    /// Which side of its neighbor the pane opens on; right when missing.
    public var edge: Direction?
    /// The pane to open beside instead of `beside`'s, as `tab pane` names one.
    public var anchor: String?

    public init(kind: Kind, session: SessionId, project: ProjectId, provider: AgentChatProvider? = nil,
                beside: SessionId? = nil, placement: Placement = .pane, edge: Direction? = nil,
                anchor: String? = nil) {
        self.kind = kind
        self.session = session
        self.project = project
        self.provider = provider
        self.beside = beside
        self.placement = placement
        self.edge = edge
        self.anchor = anchor
    }

    private enum Keys: String, CodingKey { case kind, session, project, provider, beside, placement, edge, anchor }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        session = try container.decode(SessionId.self, forKey: .session)
        project = try container.decode(ProjectId.self, forKey: .project)
        provider = try container.decodeIfPresent(AgentChatProvider.self, forKey: .provider)
        beside = try container.decodeIfPresent(SessionId.self, forKey: .beside)
        placement = try container.decodeIfPresent(Placement.self, forKey: .placement) ?? .pane
        edge = try container.decodeIfPresent(Direction.self, forKey: .edge)
        anchor = try container.decodeIfPresent(String.self, forKey: .anchor)
    }
}

/// A `tab pane` command for panes the app already shows. Panes are named as
/// `PaneSelector` reads them, by the app, against the pane showing `caller`.
///
///     {"action":"list","all":true}
///     {"action":"move","pane":"…","other":"left","edge":"down","caller":"…"}
public struct AppPaneControl: Hashable, Sendable, Codable {
    public enum Action: String, Hashable, Sendable, Codable, CaseIterable {
        /// The panes of the caller's tab, or with `all` of every tab, as
        /// `{"tabs":[{…,"panes":[…]}]}`.
        case list
        case focus
        /// Closes the pane after its content agrees, as Close Pane does. The
        /// caller's own pane closes just after the reply.
        case close
        /// Shows the pane alone in its tab, or with `zoomed` false the whole tab again.
        case zoom
        /// Docks the pane on `edge` of `other`, by default the caller's pane.
        case move
        /// Exchanges the places of the pane and `other`.
        case swap
        /// Gives the pane `percent` of its tab's width or height (`axis`).
        case resize
        /// Gives every row and column of the pane's tab equal shares.
        case equalize
        /// Closes a tab as Close Tab does: `pane` names the tab by its ID or by
        /// one of its panes. A worktree's tab removes the worktree.
        case closeTab
    }

    public var action: Action
    /// The pane acted on; `nil` means the caller's.
    public var pane: String?
    /// The other pane of `move` and `swap`.
    public var other: String?
    public var edge: Direction?
    /// The share of the tab `resize` gives the pane, 1 to 100.
    public var percent: Int?
    /// `horizontal` resizes the width, `vertical` the height.
    public var axis: Axis?
    /// `list`: every tab instead of the caller's.
    public var all: Bool?
    /// `zoom`: false shows the whole tab again.
    public var zoomed: Bool?
    /// The Tab terminal or agent the command runs in.
    public var caller: SessionId?

    public init(_ action: Action, pane: String? = nil, other: String? = nil, edge: Direction? = nil,
                percent: Int? = nil, axis: Axis? = nil, all: Bool? = nil, zoomed: Bool? = nil,
                caller: SessionId? = nil) {
        self.action = action
        self.pane = pane
        self.other = other
        self.edge = edge
        self.percent = percent
        self.axis = axis
        self.all = all
        self.zoomed = zoomed
        self.caller = caller
    }
}

/// The app's answer:

///
///     {"ok":true,"value":…}
///     {"ok":false,"error":"No tab with that ID"}
public enum AppReply: Hashable, Sendable, Codable {
    case ok(JSONValue)
    case failed(String)

    private enum Keys: String, CodingKey { case ok, value, error }

    public init(from decoder: Decoder) throws {
        let reply = try JSONValue(from: decoder)
        if reply["ok"] == .bool(true) {
            self = .ok(reply["value"] ?? .null)
            return
        }
        self = .failed(reply["error"]?.string ?? "Tab did not handle the request")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .ok(let result):
            try container.encode(true, forKey: .ok)
            try container.encode(result, forKey: .value)
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
        case .notRunning: "the Tab desktop app is not running"
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

    /// Sends `request` with a read/write timeout; an error reply
    /// throws `failed`. Each successful I/O operation renews the timeout.
    public static func call(socket: URL, _ request: AppRequest, timeout: TimeInterval) throws -> JSONValue {
        let stream: FileDescriptorStream
        do {
            stream = try FileDescriptorStream.connect(unixSocket: socket.path)
        } catch let error as TransportError where LocalServer.unavailable(error) {
            throw AppSocketError.notRunning
        } catch {
            if let transport = error as? TransportError, case .system(_, let code) = transport {
                throw ioError(code)
            }
            throw AppSocketError.transport(String(describing: error))
        }
        defer { stream.close() }
        guard timeout > 0, timeout.isFinite else { throw ioError(EINVAL) }
        let seconds = min(timeout, Double(Int.max / 2))
        var interval = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard setsockopt(stream.readDescriptor, SOL_SOCKET, option, &interval,
                             socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw ioError(errno) }
        }
        let requestData = try encode(request)
        try requestData.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = send(stream.writeDescriptor, base + offset, bytes.count - offset, MSG_NOSIGNAL)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ioError(errno)
                }
                offset += count
            }
        }
        guard shutdown(stream.writeDescriptor, SHUT_WR) == 0 else { throw ioError(errno) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < maxReplyBytes {
            let count = chunk.withUnsafeMutableBytes { bytes in
                recv(stream.readDescriptor, bytes.baseAddress, min(bytes.count, maxReplyBytes - data.count), 0)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ioError(errno)
            }
            data.append(contentsOf: chunk[..<count])
        }
        if data.isEmpty { throw AppSocketError.noResponse }
        guard let reply = try? JSONDecoder().decode(AppReply.self, from: data) else {
            throw AppSocketError.failed("invalid reply from Tab")
        }
        switch reply {
        case .ok(let result): return result
        case .failed(let error): throw AppSocketError.failed(error)
        }
    }

    private static func ioError(_ code: Int32) -> AppSocketError {
        if code == EAGAIN || code == EWOULDBLOCK { return .noResponse }
        return .transport("\(String(cString: strerror(code))) (os error \(code))")
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
/// `{"verb":"browser.<command>","args":{…}}` (`evaluate` uses `eval`). Every command but
/// `open` and `list` names its tab with `"tabId"`. Element commands take a CSS
/// `"selector"` and answer `false` when nothing matches. Waits take an
/// optional `"timeoutMs"` (capped at 60000).
public enum BrowserCommand: String, Hashable, Sendable, CaseIterable {
    /// `url?`, `profile?`, `project?`, `beside?` (a terminal or agent's session),
    /// `tab` (a new tab in Home), `edge?` (left, right, up, down), `anchor?` (a
    /// pane as `tab pane` names one) → the new browser's ID (string).
    case open
    /// `project?`, `worktree?` → `[{"id","title","url","profile","active"}]`.
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
