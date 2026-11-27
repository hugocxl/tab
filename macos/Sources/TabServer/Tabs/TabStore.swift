import Foundation
import TabCore
import TabProtocol

/// The server's tabs, kept in `sessions/tabs.json`. Every app connected to
/// the server shows them. Every change bumps the revision and is saved
/// before it is visible.
final class TabStore: @unchecked Sendable {
    /// How many recent changes a snapshot names as applied.
    static let appliedLimit = 128
    static let receiptLimit = 256

    struct Receipt: Codable, Equatable {
        var operation: OperationId
        var mutation: TabMutation
        var error: ErrorReply?
        var revision: UInt64
    }

    struct State: Codable, Equatable {
        var version = 1
        var revision: UInt64 = 0
        var projects: [ProjectTabs] = []
        var receipts: [Receipt] = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
            projects = try container.decodeIfPresent([ProjectTabs].self, forKey: .projects) ?? []
            receipts = try container.decodeIfPresent([Receipt].self, forKey: .receipts) ?? []
        }
    }

    let url: URL?
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var state: State
    private let home: ProjectId
    /// Called with the new revision after each committed change.
    var onChange: (@Sendable (UInt64) -> Void)?

    /// Opens the tabs in `directory`. Tabs of projects `isProject` doesn't
    /// know are dropped, and so are terminal panes whose session isn't
    /// `isLive`: a stopped server's terminals ended with it.
    init(directory: URL?, home: ProjectId, isProject: (ProjectId) -> Bool, isLive: (SessionId) -> Bool) throws {
        url = directory?.appendingPathComponent("tabs.json")
        self.home = home
        var state = State()
        if let url, let data = try? Data(contentsOf: url) {
            do {
                state = try JSONDecoder().decode(State.self, from: data)
            } catch {
                throw ServiceError(.persistenceFailed, "\(url.path) is damaged: \(error.localizedDescription)")
            }
            guard state.version == 1 else {
                throw ServiceError(.persistenceFailed, "\(url.path) was written by a newer Tab")
            }
        }
        var board = TabBoard(home: home, projects: state.projects)
        board.retainProjects(isProject)
        for session in Set(board.allPanes.compactMap(\.content.session)) where !isLive(session) {
            _ = TabReducer.removePanes(showing: session, in: &board)
        }
        do {
            try board.validate()
        } catch {
            throw ServiceError(.persistenceFailed, "The saved tabs are not valid: \(error)")
        }
        state.projects = board.projects
        self.state = state
        try save(state)
    }

    var revision: UInt64 { lock.withLock { state.revision } }

    func snapshot() -> TabsSnapshot {
        lock.withLock {
            TabsSnapshot(revision: state.revision, applied: state.receipts.suffix(Self.appliedLimit).map(\.operation),
                         projects: state.projects)
        }
    }

    func pane(_ id: PaneId) -> Pane? {
        lock.withLock { TabBoard(home: home, projects: state.projects).allPanes.first { $0.id == id } }
    }

    /// Whether a pane shows the terminal `session`.
    func shows(_ session: SessionId) -> Bool {
        lock.withLock { TabBoard(home: home, projects: state.projects).shows(session: session) }
    }

    /// Applies a client's change once per operation, returning the revision
    /// and what it ended. A retried change returns what it did the first time.
    /// `applying` is the change as the server checked it, such as adopted
    /// tabs without terminals that ended.
    func mutate(_ intent: TabIntent, applying: TabMutation? = nil,
                isProject: (ProjectId) -> Bool) throws -> (UInt64, TabChangeEffects) {
        let recorded = lock.withLock { state.receipts.first { $0.operation == intent.operation } }
        if let receipt = recorded {
            guard receipt.mutation == intent.mutation else {
                throw ServiceError(.badRequest, "The operation was already used for another change")
            }
            if let error = receipt.error { throw ServiceError(error.code, error.message) }
            return (receipt.revision, TabChangeEffects())
        }
        var effects = TabChangeEffects()
        var failure: ErrorReply?
        let revision = try update { state, board in
            do {
                effects = try TabReducer.apply(Self.stamped(applying ?? intent.mutation), to: &board, isProject: isProject)
            } catch {
                failure = ErrorReply(code: .badRequest, message: "The tabs changed: \(error)")
            }
            state.receipts.append(Receipt(operation: intent.operation, mutation: intent.mutation, error: failure,
                                          revision: state.revision + 1))
            if state.receipts.count > Self.receiptLimit {
                state.receipts.removeFirst(state.receipts.count - Self.receiptLimit)
            }
            return true
        }
        if let failure { throw ServiceError(failure.code, failure.message) }
        return (revision, effects)
    }

    /// Makes a change only the server makes, such as showing a terminal
    /// that started. `body` returns whether it changed anything.
    @discardableResult
    func edit(_ body: (inout TabBoard) -> Bool) throws -> Bool {
        var changed = false
        try update { _, board in
            changed = body(&board)
            return changed
        }
        return changed
    }

    /// New tabs are dated by the server's clock, so every app orders them alike.
    private static func stamped(_ mutation: TabMutation) -> TabMutation {
        let now = Date()
        switch mutation {
        case let .createTab(project, tab, after):
            var tab = tab
            tab.createdAt = now
            return .createTab(project: project, tab: tab, after: after)
        case let .adoptTabs(project, tabs):
            return .adoptTabs(project: project, tabs: tabs.map { tab in
                var tab = tab
                tab.createdAt = tab.createdAt ?? now
                return tab
            })
        default:
            return mutation
        }
    }

    /// Applies `edit` to a copy, saves it, then makes it current. Nothing is
    /// saved when `edit` returns false.
    @discardableResult
    private func update(_ edit: (inout State, inout TabBoard) throws -> Bool) throws -> UInt64 {
        let (revision, changed): (UInt64, Bool) = try writeLock.withLock {
            var next = lock.withLock { state }
            var board = TabBoard(home: home, projects: next.projects)
            guard try edit(&next, &board) else { return (next.revision, false) }
            try board.validate()
            next.projects = board.projects
            next.revision += 1
            try save(next)
            lock.withLock { state = next }
            return (next.revision, true)
        }
        if changed { onChange?(revision) }
        return revision
    }

    private func save(_ state: State) throws {
        guard let url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try AtomicFile.write(try encoder.encode(state), to: url)
        } catch {
            throw ServiceError(.persistenceFailed, "Could not save the tabs: \(error.localizedDescription)")
        }
    }
}
