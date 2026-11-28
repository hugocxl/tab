import Foundation

/// What a server is in the middle of: the work a restart would cut short.
/// A terminal waiting at its shell's prompt is not work; it reopens in the
/// same folder with its output when the server restarts.
public struct ServerWork: Hashable, Codable, Sendable {
    /// A terminal running a program other than its shell, such as a build or a server.
    public struct Program: Hashable, Codable, Sendable {
        public var session: SessionId
        public var project: ProjectId
        /// The program's name, such as `npm`.
        public var name: String

        public init(session: SessionId, project: ProjectId, name: String) {
            self.session = session
            self.project = project
            self.name = name
        }
    }

    /// Terminals running a program, oldest first.
    public var programs: [Program]
    /// Agent conversations working, waiting for an answer, or running
    /// shells and subagents in the background.
    public var agents: [SessionId]
    /// Other work, such as commands run without a terminal and terminals starting.
    public var jobs: Int

    public init(programs: [Program] = [], agents: [SessionId] = [], jobs: Int = 0) {
        self.programs = programs
        self.agents = agents
        self.jobs = jobs
    }

    public var isIdle: Bool { programs.isEmpty && agents.isEmpty && jobs == 0 }

    /// The most programs a reply lists.
    public static let maxPrograms = 64

    private enum CodingKeys: String, CodingKey { case programs, agents, jobs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        programs = try c.decodeIfPresent([Program].self, forKey: .programs) ?? []
        agents = try c.decodeIfPresent([SessionId].self, forKey: .agents) ?? []
        jobs = try c.decodeIfPresent(Int.self, forKey: .jobs) ?? 0
    }

    public func validate() throws(ErrorCode) {
        guard programs.count <= Self.maxPrograms, agents.count <= Self.maxPrograms, jobs >= 0,
              programs.allSatisfy({ $0.name.utf8.count <= 256 }) else { throw .badRequest }
    }
}
