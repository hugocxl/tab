import Foundation
import TabClient
import TabCore

/// Opens a connection to a remote server listed in settings: its custom
/// command or ssh with its port and key, through the app's proxy when that
/// applies to the whole app, and with the password typed this session.
/// Without that password it fails at once with `passwordNeeded`, which
/// isn't recoverable, so the shell's backoff stops until the user types it.
/// A refused password is forgotten so Connect asks again.
public struct RemoteServerConnector: ServerConnector {
    public let entry: ServerEntry
    let askpass: AskpassServer
    let proxy: ProxyCommand?
    let login: @Sendable (SSHTarget) async throws -> String
    let open: @Sendable (SSHTarget) async throws -> ServerAPI

    public init(entry: ServerEntry, askpass: AskpassServer, proxy: ProxyCommand?) {
        self.init(entry: entry, askpass: askpass, proxy: proxy,
                  login: { target in try await Task.detached { try target.login() }.value },
                  open: { target in try await RemoteServer.connect(target, start: .ifNeeded, kind: .desktop) })
    }

    init(entry: ServerEntry, askpass: AskpassServer, proxy: ProxyCommand?,
         login: @escaping @Sendable (SSHTarget) async throws -> String,
         open: @escaping @Sendable (SSHTarget) async throws -> ServerAPI) {
        self.entry = entry
        self.askpass = askpass
        self.proxy = proxy
        self.login = login
        self.open = open
    }

    /// Whether connecting asks the app for a password.
    var usesPassword: Bool { entry.passwordLogin && entry.sshCommand == nil }

    /// The target this connector reaches, with the askpass program set when
    /// the server logs in with a password.
    func target() async throws -> SSHTarget {
        var target = try ServerForm.target(for: entry, proxy: proxy)
        guard usesPassword else { return target }
        let key = entry.id.description
        guard askpass.hasPassword(for: key) else {
            throw ClientError.remote(RemoteFailure(reason: .passwordNeeded, destination: entry.name, detail: ""))
        }
        target.askpass = askpass.askpass(for: key, login: try await login(target))
        return target
    }

    public func connect() async throws -> ServerAPI {
        let target: SSHTarget
        do {
            target = try await self.target()
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.wrapping(error)
        }
        do {
            return try await open(target)
        } catch {
            let error = ClientError.wrapping(error)
            if usesPassword, case .remote(let failure) = error, failure.reason == .authenticationFailed {
                askpass.forgetPassword(for: entry.id.description)
            }
            throw error
        }
    }
}

extension ClientError {
    /// Any error from connecting, as the client reports it.
    static func wrapping(_ error: Error) -> ClientError {
        if let error = error as? ClientError { return error }
        if let error = error as? SSHTargetError { return .transport(error.description) }
        return .transport(error.localizedDescription)
    }
}

/// The last line with text, for a one-line message.
func lastLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline)
        .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
}
