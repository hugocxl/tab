import Foundation
import os
import TabProtocol

/// What one Mac's cards last showed from the server: each project's Git
/// branch and base. Saved in Caches, so the next launch draws them as soon
/// as the tabs arrive, before the server answers the Git requests; live
/// values replace them as they come. Only for display.
@MainActor
final class CardMemory {
    struct Contents: Codable, Equatable, Sendable {
        /// By project id.
        var git: [String: RememberedGit] = [:]

        init(git: [String: RememberedGit] = [:]) {
            self.git = git
        }

        /// Tolerates a missing `git`, and drops entries a later version wrote
        /// in a shape this one can't read instead of the whole file.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let entries = try container.decodeIfPresent([String: Lossy<RememberedGit>].self, forKey: .git) ?? [:]
            git = entries.compactMapValues(\.value)
        }
    }

    struct RememberedGit: Codable, Equatable, Sendable {
        /// Nil when the project's folder isn't a repository.
        var summary: GitSummary?
    }

    /// A value that decodes to nil instead of failing.
    struct Lossy<Value: Decodable>: Decodable {
        var value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private nonisolated static let log = Logger(subsystem: "com.hugocorta.tabios", category: "card-memory")
    private let file: URL?
    /// Writes in order, so an older save never lands after a newer one.
    private let writer = DispatchQueue(label: "com.hugocorta.tabios.card-memory", qos: .utility)
    private(set) var contents: Contents
    private var saveScheduled = false

    /// Loads `file`; a missing or unreadable one starts empty. With no file,
    /// nothing is saved.
    init(file: URL?) {
        self.file = file
        contents = file.flatMap { try? Data(contentsOf: $0) }.flatMap(Self.decode) ?? Contents()
    }

    static func decode(_ data: Data) -> Contents? {
        try? JSONDecoder().decode(Contents.self, from: data)
    }

    /// The Git summaries last shown, by project; nil for a folder that isn't a repository.
    var gitSummaries: [ProjectId: GitSummary?] {
        var summaries: [ProjectId: GitSummary?] = [:]
        for (key, remembered) in contents.git {
            guard let project = ProjectId(string: key) else { continue }
            summaries[project] = .some(remembered.summary)
        }
        return summaries
    }

    func setGit(_ project: ProjectId, _ summary: GitSummary?) {
        let remembered = RememberedGit(summary: summary)
        guard contents.git[project.description] != remembered else { return }
        contents.git[project.description] = remembered
        scheduleSave()
    }

    /// Forgets the projects the server no longer lists.
    func retain(projects: Set<ProjectId>) {
        let keys = Set(projects.map(\.description))
        let git = contents.git.filter { keys.contains($0.key) }
        guard git.count != contents.git.count else { return }
        contents.git = git
        scheduleSave()
    }

    /// Deletes the file, as when the Mac is forgotten.
    func erase() {
        contents = Contents()
        saveScheduled = false
        guard let file else { return }
        writer.async { try? FileManager.default.removeItem(at: file) }
    }

    private func scheduleSave() {
        guard file != nil, !saveScheduled else { return }
        saveScheduled = true
        // One write for a burst of answers, such as every project's after connecting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.saveScheduled, let file = self.file else { return }
                self.saveScheduled = false
                let contents = self.contents
                self.writer.async { Self.write(contents, to: file) }
            }
        }
    }

    private nonisolated static func write(_ contents: Contents, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(contents).write(to: file, options: .atomic)
        } catch {
            log.error("Could not save the card cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}
