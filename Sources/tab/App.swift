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
        guard let seconds = UInt32(text), seconds > 0 else {
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
    static func launch() -> Bool {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let executable = Executable.currentURL(), let bundle = Executable.containingBundle(of: executable) {
            open.arguments = ["-g", "-a", bundle.path]
        } else {
            open.arguments = ["-g", "-b", Release.bundleIdentifier]
        }
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
        do {
            _ = try App.call(.open(path: folder), timeout: try App.replyTime(), startApp: true)
            return
        } catch AppSocketError.notRunning {
            let client = try await LocalServer.profile().connect(kind: .cli)
            defer { client.close() }
            let project = try await Projects.folderProject(folder, client: client)
            Output.line(project.id.description)
        }
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
        case .text:
            Output.line(reply.string ?? reply.description)
        case .tabs:
            guard case .array(let tabs) = reply else { throw CLIError("invalid reply from Tab") }
            for tab in tabs {
                Output.line(["tabId", "title", "url", "profile", "active"].map { key in
                    switch tab[key] {
                    case .string(let text)?: text.replacingOccurrences(of: "\t", with: " ")
                        .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                    case .null?, nil: ""
                    case let other?: other.description
                    }
                }.joined(separator: "\t"))
            }
        case .page:
            Output.line([reply["title"], reply["url"], reply["text"]].map { $0?.string ?? "" }.joined(separator: "\n"))
        case .screenshot:
            guard let png = reply["png"]?.string else { throw CLIError("invalid reply from Tab") }
            Output.line(png)
        }
    }
}
