import Foundation
import TabProtocol
import TabTerminal

/// Saves sessions' screens and history in the background, one writer for
/// the server. Saves of one session coalesce: only the newest is written.
final class ArchiveStore: @unchecked Sendable {
    let root: URL
    private let queue = DispatchQueue(label: "tab.archive", qos: .utility)
    private let lock = NSLock()
    private var pending: [SessionId: Job] = [:]
    private var order: [SessionId] = []
    private var draining = false

    typealias Completion = @Sendable (Error?) -> Void

    private enum Operation {
        case save(TerminalArchive, ExitReason?)
        case discard
    }

    private struct Job {
        var operation: Operation
        var completions: [Completion]
    }

    init(root: URL) throws {
        self.root = root
        try PrivateFolder.ensure(root)
    }

    // MARK: Writing

    /// Queues a save; a session's last save (`reason` set) is synced to disk.
    func save(_ session: SessionId, _ archive: TerminalArchive, reason: ExitReason?, completion: Completion? = nil) {
        submit(session, .save(archive, reason), completion: completion)
    }

    func discard(_ session: SessionId, completion: Completion? = nil) {
        submit(session, .discard, completion: completion)
    }

    /// Discards and waits for the files to be gone.
    func discardNow(_ session: SessionId) throws {
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        discard(session) { error in
            result.error = error
            done.signal()
        }
        done.wait()
        if let error = result.error {
            throw ServiceError(.savedContentUnavailable, "Could not remove saved terminal content: \(error.localizedDescription)")
        }
    }

    /// Waits for every queued write.
    func flush() {
        queue.sync {}
        while lock.withLock({ !pending.isEmpty || draining }) {
            queue.sync {}
        }
    }

    private final class ResultBox: @unchecked Sendable {
        var error: Error?
    }

    private func submit(_ session: SessionId, _ operation: Operation, completion: Completion?) {
        let start = lock.withLock { () -> Bool in
            if var job = pending[session] {
                job.operation = operation
                if let completion { job.completions.append(completion) }
                pending[session] = job
            } else {
                pending[session] = Job(operation: operation, completions: completion.map { [$0] } ?? [])
                order.append(session)
            }
            guard !draining else { return false }
            draining = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while let (session, job) = next() {
            var failure: Error?
            do {
                switch job.operation {
                case .save(let archive, let reason):
                    try ArchiveFiles.write(SavedRecord(archive, reason: reason), root: root, session: session,
                                           durable: reason != nil)
                case .discard:
                    try ArchiveFiles.remove(root: root, session: session)
                }
            } catch {
                failure = error
                ServerLog.error("session \(session) saved content: \(error.localizedDescription)")
            }
            for completion in job.completions { completion(failure) }
        }
    }

    private func next() -> (SessionId, Job)? {
        lock.withLock {
            guard !order.isEmpty else {
                draining = false
                return nil
            }
            let session = order.removeFirst()
            guard let job = pending.removeValue(forKey: session) else { return nil }
            return (session, job)
        }
    }

    // MARK: Reading

    func contains(_ session: SessionId) -> Bool {
        FileManager.default.fileExists(atPath: ArchiveFiles.screenURL(root, session).path)
    }

    func readScreen(_ session: SessionId) throws -> SavedScreen {
        try loaded(session).screen
    }

    private func loaded(_ session: SessionId) throws -> ArchiveFiles.Screen {
        do {
            return try ArchiveFiles.readScreen(root: root, session: session)
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError(.savedContentUnavailable, "No saved terminal content for session \(session)")
        }
    }

    private func history(_ session: SessionId, _ screen: ArchiveFiles.Screen) -> ArchiveFiles.HistoryReader? {
        guard screen.header.historyRows > 0 else { return nil }
        return ArchiveFiles.HistoryReader(root: root, session: session, generation: screen.header.generation)
    }

    /// A page of saved history; the first page also carries the saved screen.
    func historyPage(_ session: SessionId, before: HistoryCursor?, maxRows: UInt16) throws -> HistoryPage {
        let screen = try loaded(session)
        let reader = history(session, screen)
        let total = reader?.count ?? 0
        let (range, next) = try HistoryWindow.range(session: session, generation: screen.header.generation,
                                                    before: before, maxRows: maxRows, total: total)
        let rows = try reader?.rows(range) ?? []
        return HistoryPage(
            rows: rows.enumerated().map { Row(index: UInt16($0.offset), runs: $0.element) },
            next: rows.isEmpty ? nil : next, totalRows: UInt64(total),
            screen: before == nil ? screen.screen : nil)
    }

    func search(_ session: SessionId, query: String, ignoreCase: Bool, before: HistoryCursor?,
                maxResults: UInt16) throws -> SearchPage {
        let screen = try loaded(session)
        let reader = history(session, screen)
        let historyRows = reader?.count ?? 0
        let search = HistorySearch(session: session, generation: screen.header.generation, query: query,
                                   ignoreCase: ignoreCase, before: before, maxResults: maxResults,
                                   historyRows: historyRows, screenRows: screen.screen.rows.count)
        let range = try search.range()
        let historyEnd = min(range.upperBound, historyRows)
        let historyStart = min(range.lowerBound, historyEnd)
        let history = try reader?.rows(historyStart..<historyEnd) ?? []
        return try search.scan { index in
            index < historyRows ? history[index - historyStart] : screen.screen.rows[index - historyRows].runs
        }
    }
}
