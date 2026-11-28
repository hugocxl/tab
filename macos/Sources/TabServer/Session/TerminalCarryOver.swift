import Foundation
import TabCore
import TabProtocol

/// `sessions/carry-over.json`: the terminals a server restarting with
/// `restartServerKeepingTerminals` hands to the next one. Each reopens in the
/// panes that showed it, in the folder it was in, with its output above a
/// new shell. The next server reads it once, whenever it starts.
struct TerminalCarryOver: Codable, Equatable {
    struct Terminal: Codable, Equatable {
        var session: SessionId
        var project: ProjectId
        /// The folder the terminal was in when the server stopped.
        var directory: ServerPath
        var size: Size
        /// The environment it was created with beyond the shell's own, such as a proxy.
        var environment: [String: String]
        /// The program the restart stopped, when one ran.
        var stopped: String?

        init(session: SessionId, project: ProjectId, directory: ServerPath, size: Size,
             environment: [String: String] = [:], stopped: String? = nil) {
            self.session = session
            self.project = project
            self.directory = directory
            self.size = size
            self.environment = environment
            self.stopped = stopped
        }
    }

    var version = 1
    var terminals: [Terminal]

    /// What a carried terminal says above its new shell.
    static func note(stopped: String?) -> String {
        if let stopped, !stopped.isEmpty { return "\(stopped) stopped when Tab's server restarted. This is a new shell." }
        return "Tab's server restarted. This is a new shell in the same folder."
    }

    static func url(_ dirs: TabDirs) -> URL { dirs.sessions.appendingPathComponent("carry-over.json") }

    func write(to url: URL) throws {
        try AtomicFile.write(JSONEncoder().encode(self), to: url)
    }

    /// The handoff at `url`. The server removes it once its terminals
    /// reopened; a damaged or newer handoff is removed at once, and its
    /// terminals end as before.
    static func read(_ url: URL) -> TerminalCarryOver? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let carried = try JSONDecoder().decode(TerminalCarryOver.self, from: data)
            guard carried.version == 1 else { throw ServiceError(.badRequest, "version \(carried.version)") }
            return carried
        } catch {
            ServerLog.error("the terminals of the previous server couldn't be reopened: \(error)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }
}
