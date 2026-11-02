import Foundation
import TabCore
import TabProtocol

/// `server.json`: the server's own settings. Unknown keys are ignored and
/// missing ones take their defaults, so the file only grows.
struct ServerSettingsFile: Codable, Equatable {
    var startupCommand: [String]
    var historyBudgetBytes: UInt64
    var shellIntegration: Bool

    init(_ document: ServerSettingsDoc = ServerSettingsDoc()) {
        startupCommand = document.startupCommand
        historyBudgetBytes = document.historyBudgetBytes
        shellIntegration = document.shellIntegration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerSettingsDoc()
        startupCommand = try container.decodeIfPresent([String].self, forKey: .startupCommand) ?? []
        historyBudgetBytes = try container.decodeIfPresent(UInt64.self, forKey: .historyBudgetBytes)
            ?? defaults.historyBudgetBytes
        shellIntegration = try container.decodeIfPresent(Bool.self, forKey: .shellIntegration)
            ?? defaults.shellIntegration
    }

    var document: ServerSettingsDoc {
        ServerSettingsDoc(startupCommand: startupCommand, historyBudgetBytes: historyBudgetBytes,
                          shellIntegration: shellIntegration)
    }
}

/// The server's settings, kept in `server.json`.
final class ServerSettingsStore: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var current: ServerSettingsDoc

    /// Reads `url`, writing the defaults when it doesn't exist.
    init(url: URL) throws {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            let file: ServerSettingsFile
            do {
                file = try JSONDecoder().decode(ServerSettingsFile.self, from: data)
            } catch {
                throw ServiceError(.badRequest, "\(url.path): \(error.localizedDescription)")
            }
            let document = file.document
            do {
                try document.validate()
            } catch {
                throw ServiceError(.badRequest, "\(url.path): the startup command is invalid or the history budget is over 64 GiB")
            }
            current = document
        } else {
            current = ServerSettingsDoc()
            try Self.save(current, to: url)
        }
    }

    var settings: ServerSettingsDoc {
        lock.withLock { current }
    }

    /// Validates, saves, then applies `settings` to new sessions.
    func write(_ settings: ServerSettingsDoc) throws {
        do {
            try settings.validate()
        } catch {
            throw ServiceError(.badRequest, "The startup command is invalid or the history budget is over 64 GiB")
        }
        if let program = settings.startupCommand.first,
           SessionSpawn.resolve(program, environment: ProcessInfo.processInfo.environment) == nil {
            throw ServiceError(.badPath, "\(program) is not an executable file")
        }
        try lock.withLock {
            do {
                try Self.save(settings, to: url)
            } catch {
                throw ServiceError(.persistenceFailed, "Could not save server settings: \(error.localizedDescription)")
            }
            current = settings
        }
    }

    private static func save(_ settings: ServerSettingsDoc, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(ServerSettingsFile(settings)), to: url)
    }
}
