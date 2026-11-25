import Foundation
import TabClient
import TabCore
import TabProtocol

/// The Tab app on this computer, reached over `app.sock`.
enum App {
    /// How long a started app has to begin listening.
    static let startTime: TimeInterval = 20

    static func socket() throws -> URL {
        try TabDirs.profile().appSocket
    }

    /// How long the app has to answer: `TAB_CLI_TIMEOUT` seconds, else 10.
    static func replyTime(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> TimeInterval {
        guard let text = environment["TAB_CLI_TIMEOUT"], !text.isEmpty else { return 10 }
        guard let seconds = UInt64(text), seconds > 0 else {
            throw CLIError("TAB_CLI_TIMEOUT must be a whole number of seconds")
        }
        return TimeInterval(seconds)
    }

    /// Over SSH the app would open away from the user.
    static var overSSH: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["SSH_CONNECTION"] != nil || environment["SSH_TTY"] != nil
    }

    /// Sends `request`, starting the app first when it isn't running and
    /// `startApp` allows.
    static func call(_ request: AppRequest, timeout: TimeInterval, startApp: Bool) throws -> JSONValue {
        let socket = try socket()
        do {
            return try AppSocket.call(socket: socket, request, timeout: timeout)
        } catch AppSocketError.notRunning where startApp && !overSSH && launch() {
            let deadline = Date().addingTimeInterval(startTime)
            while true {
                do {
                    return try AppSocket.call(socket: socket, request, timeout: timeout)
                } catch AppSocketError.notRunning where Date() < deadline {
                    usleep(100_000)
                }
            }
        }
    }

    /// Starts the app: the bundle this program is in, else the installed one
    /// by its bundle identifier. Returns false when it can't.
    static func launch(folder: String? = nil) -> Bool {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let executable = Executable.currentURL(), let bundle = Executable.containingBundle(of: executable) {
            open.arguments = ["-a", bundle.path]
        } else {
            open.arguments = ["-b", Release.bundleIdentifier]
        }
        if let folder { open.arguments?.append(folder) }
        open.standardInput = FileHandle.nullDevice
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        do {
            try open.run()
        } catch {
            return false
        }
        open.waitUntilExit()
        return open.terminationStatus == 0
    }
}

/// `tab <folder>`: opens the folder in the app, starting it if needed. With
/// no app here, or over SSH, the folder becomes a project on the server and
/// its ID is printed.
enum OpenFolder {
    static func run(_ word: String) async throws {
        let path = Paths.absolute(word)
        guard Paths.isDirectory(path), let folder = Paths.canonical(path) else {
            throw CLIError("\(word) is not a command or a folder; run tab --help")
        }
        if !App.overSSH {
            do {
                _ = try AppSocket.call(socket: App.socket(), .open(path: folder), timeout: try App.replyTime())
                return
            } catch AppSocketError.notRunning {
                if App.launch(folder: folder) { return }
            }
        }
        let client = try await LocalServer.profile().connect(kind: .cli)
        defer { client.close() }
        let project = try await Projects.folderProject(folder, client: client)
        Output.line(project.id.description)
    }
}

/// `tab browser`: one request to the app per command.
enum BrowserCommandRunner {
    static func run(_ invocation: BrowserInvocation) throws {
        let reply = try App.call(invocation.request, timeout: try App.replyTime() + invocation.extraTime,
                                 startApp: invocation.command == .open)
        switch invocation.output {
        case .ok:
            Output.line("ok")
        case .json:
            Output.json(reply)
        case .id, .idJSON:
            guard let id = reply.string else { throw CLIError("invalid reply from Tab") }
            Output.record(.object(["id": .string(id)]), columns: ["id"], json: invocation.output == .idJSON)
        case .list:
            guard case .array(let browsers) = reply else { throw CLIError("invalid reply from Tab") }
            Output.list(browsers, columns: ["id", "title", "url", "profile", "active"], json: false)
        case .page:
            Output.line([reply["title"], reply["url"], reply["text"]].map { $0?.string ?? "" }.joined(separator: "\n"))
        case .screenshot:
            guard let image = reply["png"]?.string ?? reply["image"]?.string else { throw CLIError("invalid reply from Tab") }
            Output.line(image)
        case .screenshotFile(let path):
            guard let text = reply["png"]?.string ?? reply["image"]?.string, let image = Data(base64Encoded: text) else {
                throw CLIError("invalid reply from Tab")
            }
            do {
                try image.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                throw CLIError("can't write \(path): \(error.localizedDescription)")
            }
            Output.line(path)
            if case .array(let refs)? = reply["refs"], !refs.isEmpty {
                Output.line("labels: " + refs.compactMap(\.string).map { "[\($0.dropFirst())] @\($0)" }.joined(separator: " "))
            }
        case .snapshot:
            guard let text = reply["text"]?.string else { return Output.json(reply) }
            Output.line(text.isEmpty ? "(no elements)" : text)
        case .action:
            printAction(reply)
        case .console:
            for entry in entries(reply) {
                Output.line("[\(entry["level"]?.string ?? "log")] \(entry["text"]?.string ?? "")")
            }
        case .errors:
            for entry in entries(reply) {
                var line = entry["text"]?.string ?? ""
                if let source = entry["source"]?.string, !source.isEmpty {
                    line += " (\(source):\(entry["line"]?.description ?? "0"))"
                }
                Output.line(line)
            }
        case .network:
            for entry in entries(reply) {
                let outcome = entry["status"]?.description ?? entry["error"]?.string ?? "pending"
                let time = entry["ms"].map { " \($0.description)ms" } ?? ""
                Output.line("\(entry["method"]?.string ?? "GET") \(outcome)\(time) \(entry["url"]?.string ?? "")")
            }
        case .dialog:
            guard let type = reply["type"]?.string else { return Output.line("none") }
            var line = "\(type) \(JSONValue.string(reply["message"]?.string ?? "").description)"
            if let text = reply["defaultText"]?.string { line += " default \(JSONValue.string(text).description)" }
            Output.line(line)
        }
    }

    private static func entries(_ reply: JSONValue) -> [JSONValue] {
        if case .array(let entries) = reply { return entries }
        return []
    }

    /// An action prints `true`/`false` as before, or the diff `--settle`
    /// asked for; notes, warnings and dialogs go to stderr.
    private static func printAction(_ reply: JSONValue) {
        guard case .object = reply, reply["ok"] != nil else { return Output.json(reply) }
        if let note = reply["note"]?.string { FileHandle.standardError.write(Data("tab: \(note)\n".utf8)) }
        if let warning = reply["warning"]?.string { FileHandle.standardError.write(Data("tab: warning: \(warning)\n".utf8)) }
        if let dialog = reply["dialog"], let type = dialog["type"]?.string {
            let message = JSONValue.string(dialog["message"]?.string ?? "").description
            FileHandle.standardError.write(Data("tab: the page opened a dialog: \(type) \(message); answer it with tab browser dialog\n".utf8))
        }
        if let diff = reply["diff"]?.string { Output.line(diff) } else { Output.json(.bool(reply["ok"] == .bool(true))) }
    }
}
