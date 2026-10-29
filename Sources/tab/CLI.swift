import Foundation
import TabClient
import TabCore
import TabProtocol

enum CLI {
    static func run(_ arguments: [String]) async throws {
        let invocation = try CLIParser.parse(arguments)
        switch invocation.command {
        case .help(let text):
            Output.line(text)
        case .version:
            Output.line("tab \(Release.version)")
        case .buildInfo:
            Output.json(try JSONValue(encoding: BuildInfo(version: Release.version)))
        case .askpass:
            throw CLIError("tab --askpass answers ssh's prompts for the Tab app; it isn't run by hand")
        case .open(let folder):
            try await OpenFolder.run(folder)
        case .browser(let browser):
            try BrowserCommandRunner.run(browser)
        case .installSkills(let directories):
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            for file in try AgentSkill.install(home: home, directories: directories) {
                Output.line(file.path)
            }
        case .stdio(let start):
            try StdioBridge.serve(try LocalServer.profile(), start: start)
        case .mobile(let command):
            let target = Target(host: invocation.host)
            let client = try await target.connect(start: true)
            defer { client.close() }
            try await target.explaining { try await Mobile.run(command, client: client) }
        case .manage(let manage):
            try await Manage.run(manage, host: invocation.host)
        }
    }

    /// Prints `tab: <message>` and exits with status 1.
    static func fail(_ error: Error) -> Never {
        FileHandle.standardError.write(Data("tab: \(message(error))\n".utf8))
        exit(1)
    }

    static func message(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return text }
        if error is CocoaError || error is POSIXError || error is URLError { return error.localizedDescription }
        return String(describing: error)
    }
}

/// The server a command talks to: this computer's, or another computer's
/// over SSH with `--host`.
struct Target {
    let host: SSHTarget?

    var isRemote: Bool { host != nil }

    func connect(start: Bool) async throws -> ServerClient {
        do {
            if let host {
                return try await RemoteServer.connect(host, start: start ? .ifNeeded : .never, kind: .cli)
            }
            return try await LocalServer.profile().connect(kind: .cli, start: start)
        } catch {
            throw explain(error)
        }
    }

    /// Names the other computer in errors that don't say which server
    /// stopped answering.
    func explain(_ error: Error) -> Error {
        guard let host, let client = error as? ClientError else { return error }
        switch client {
        case .timeout, .disconnected: return CLIError("\(host.description): \(client.description)")
        default: return error
        }
    }

    func explaining<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            throw explain(error)
        }
    }

    /// A directory argument: this computer's may be relative or start with
    /// `~`; another computer's must be absolute, and its server checks it.
    func directory(_ path: String) throws -> String {
        guard isRemote else { return Paths.absolute(path) }
        guard path.hasPrefix("/") else {
            throw CLIError("\(path): with --host, directories must be absolute paths on that computer")
        }
        return (path as NSString).standardizingPath
    }
}

enum Paths {
    /// `path` made absolute against the current folder, with `~` expanded.
    static func absolute(_ path: String) -> String {
        let expanded = TabDirs.expandHome(path, home: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
        let absolute = expanded.hasPrefix("/") ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        return (absolute as NSString).standardizingPath
    }

    /// The path with symbolic links resolved, if it exists.
    static func canonical(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

enum Output {
    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func json(_ value: JSONValue) {
        line(value.description)
    }

    /// Protocol values print in their wire JSON.
    static func wire<T: Encodable>(_ value: T) throws {
        line(String(decoding: try WireJSON.encode(value), as: UTF8.self))
    }

    static func ok(json: Bool) {
        if json { self.json(.object(["ok": .bool(true)])) } else { line("ok") }
    }

    static func record(_ value: JSONValue, columns: [String], json: Bool) {
        if json { self.json(value) } else { row(value, columns) }
    }

    static func list(_ values: [JSONValue], columns: [String], json: Bool) {
        if json {
            self.json(.array(values))
        } else {
            for value in values { row(value, columns) }
        }
    }

    /// One tab-separated line; text fields are escaped so they stay on it.
    static func row(_ value: JSONValue, _ columns: [String]) {
        line(columns.map { column in
            switch value[column] {
            case .string(let text)?: escape(text)
            case .null?, nil: ""
            case let other?: other.description
            }
        }.joined(separator: "\t"))
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\t": result += "\\t"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\\": result += "\\\\"
            default:
                if scalar.properties.generalCategory == .control {
                    result += "\\u{\(String(scalar.value, radix: 16))}"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}

extension JSONValue {
    /// A protocol value as plain JSON.
    init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: WireJSON.encode(value))
    }
}
