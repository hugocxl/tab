import Foundation
import TabProtocol

/// How long to wait before connecting again after failures in a row: 2 s,
/// doubling up to a minute, which then repeats. Backing off spares the other
/// computer's sshd and keeps tools like fail2ban from blocking this one.
public enum ReconnectBackoff {
    public static func delay(afterFailures attempts: Int) -> TimeInterval {
        TimeInterval(min(2 << min(max(attempts, 0), 5), 60))
    }
}

/// Sessions closed while their server was offline, each with the operation
/// that makes closing it again safe. Persist it with the app's state and
/// replay it once the server is back, so a pane closed offline still ends its
/// terminal there.
public struct PendingCloses: Hashable, Codable, Sendable {
    public struct Entry: Hashable, Codable, Sendable {
        public var session: SessionId
        /// Reused on every attempt, so a close whose reply was lost isn't
        /// applied twice.
        public var operation: OperationId
    }

    /// In the order they were closed.
    public private(set) var entries: [Entry] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var sessions: [SessionId] { entries.map(\.session) }

    /// Queues a close; queuing a session again keeps its first operation.
    public mutating func queue(_ session: SessionId) {
        guard !entries.contains(where: { $0.session == session }) else { return }
        entries.append(Entry(session: session, operation: OperationId()))
    }

    public func operation(for session: SessionId) -> OperationId? {
        entries.first { $0.session == session }?.operation
    }

    public mutating func complete(_ session: SessionId) {
        entries.removeAll { $0.session == session }
    }

    /// What replaying the queue did.
    public struct Replay: Sendable {
        /// Closed now, or already gone from the server.
        public var closed: [SessionId] = []
        /// Still queued, with why closing failed.
        public var failed: [(SessionId, ClientError)] = []
        /// The connection dropped; the rest waits for the next one.
        public var disconnected = false
    }

    /// Closes every queued session on `client`, in order. A session the
    /// server no longer knows counts as closed. Stops at a dropped connection
    /// and keeps the rest queued.
    public mutating func replay(on client: ServerClient) async -> Replay {
        var result = Replay()
        for entry in entries {
            do {
                try await client.closeSession(entry.session, operation: entry.operation)
                result.closed.append(entry.session)
            } catch let error as ClientError where error.serverCode == .unknownSession {
                result.closed.append(entry.session)
            } catch ClientError.disconnected {
                result.disconnected = true
                break
            } catch {
                result.failed.append((entry.session, ClientError(error)))
            }
        }
        for session in result.closed { complete(session) }
        return result
    }
}

/// Connects a server again on its own after a drop, waiting longer after
/// each failure in a row. It stops when connecting needs the user: a refused
/// login, an untrusted or changed host key, a missing or incompatible Tab, or
/// a password not typed this session.
public final class Reconnector: @unchecked Sendable {
    public typealias Connect = @Sendable () async throws -> ServerClient

    /// Why reconnecting stopped.
    public enum Outcome: Sendable {
        case connected(ServerClient)
        /// Connecting needs the user first.
        case needsUser(ClientError)
        case cancelled
    }

    private let connect: Connect
    private let needsPassword: @Sendable () -> Bool
    private let delay: @Sendable (Int) -> TimeInterval
    private let destination: String
    private let lock = NSLock()
    private var task: Task<Outcome, Never>?
    private var failures = 0

    /// - Parameters:
    ///   - needsPassword: whether the server logs in with a password that
    ///     isn't known now.
    ///   - delay: the wait after a number of failures in a row.
    public init(connect: @escaping Connect, needsPassword: @escaping @Sendable () -> Bool = { false },
                delay: @escaping @Sendable (Int) -> TimeInterval = { ReconnectBackoff.delay(afterFailures: $0) },
                destination: String = "") {
        self.connect = connect
        self.needsPassword = needsPassword
        self.delay = delay
        self.destination = destination
    }

    /// Failures in a row since the last connection.
    public var attempts: Int { lock.withLock { failures } }

    /// Whether a wait or an attempt is under way.
    public var isRunning: Bool { lock.withLock { task != nil } }

    /// Starts reconnecting, after a wait, unless already under way. Returns
    /// the outcome once connected or once the user is needed.
    @discardableResult
    public func start() -> Task<Outcome, Never> {
        lock.withLock {
            if let task { return task }
            let task = Task { await self.run() }
            self.task = task
            return task
        }
    }

    /// Stops waiting, such as when the user disconnects the server.
    public func cancel() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }

    /// Coming back, such as after sleep, often means the network is back:
    /// an attempt waiting now starts over without its wait.
    public func retryNow() {
        lock.withLock {
            guard task != nil else { return }
            task?.cancel()
            failures = max(0, failures - 1)
            let task = Task { await self.run(waitFirst: false) }
            self.task = task
        }
    }

    /// A connection came: the next drop waits the shortest time again.
    public func connected() {
        lock.withLock { failures = 0 }
    }

    private func run(waitFirst: Bool = true) async -> Outcome {
        var wait = waitFirst
        while !Task.isCancelled {
            if needsPassword() {
                return finish(.needsUser(.remote(RemoteFailure(reason: .passwordNeeded, destination: destination,
                                                               detail: ""))))
            }
            if wait {
                let seconds = delay(attempts)
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return .cancelled
                }
            }
            wait = true
            do {
                let client = try await connect()
                lock.withLock { failures = 0 }
                return finish(.connected(client))
            } catch {
                let error = ClientError(error)
                lock.withLock { failures += 1 }
                if !error.recoverable { return finish(.needsUser(error)) }
            }
        }
        return .cancelled
    }

    private func finish(_ outcome: Outcome) -> Outcome {
        lock.withLock { task = nil }
        return outcome
    }
}
