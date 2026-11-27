import Darwin
import Foundation
import TabProtocol

/// A reader-writer lock: Git reads of one repository overlap; changes wait
/// for them and exclude everything else.
final class ReadWriteLock: @unchecked Sendable {
    private var lock = pthread_rwlock_t()

    init() { pthread_rwlock_init(&lock, nil) }
    deinit { pthread_rwlock_destroy(&lock) }

    func reading<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return try body()
    }

    func writing<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return try body()
    }
}

/// One lock per key (a repository's shared `.git` folder, an operation id),
/// kept only while someone holds it.
final class LockTable<Key: Hashable, Lock: AnyObject>: @unchecked Sendable {
    private struct Weak { weak var lock: Lock? }
    private var locks: [Key: Weak] = [:]
    private let mutex = NSLock()
    private let make: () -> Lock

    init(_ make: @escaping () -> Lock) {
        self.make = make
    }

    func lock(for key: Key) -> Lock {
        mutex.lock()
        defer { mutex.unlock() }
        if let lock = locks[key]?.lock { return lock }
        locks = locks.filter { $0.value.lock != nil }
        let lock = make()
        locks[key] = Weak(lock: lock)
        return lock
    }
}

/// Projects and folders with a worktree action in progress.
final class WorktreeOperations: WorktreeOperationGuard, @unchecked Sendable {
    private var projects: [ProjectId: Int] = [:]
    private var removals: [String] = []
    private let mutex = NSLock()

    /// Holds `projects` (and a folder being removed) for the duration of `body`.
    func reserve<T>(_ projects: [ProjectId], removal: String?, _ body: () throws -> T) throws -> T {
        let unique = Array(Set(projects))
        mutex.lock()
        if unique.contains(where: { self.projects[$0] != nil }) {
            mutex.unlock()
            throw gitError("Project has an active worktree operation; retry when it completes")
        }
        for project in unique { self.projects[project] = 1 }
        if let removal { removals.append(removal) }
        mutex.unlock()
        defer {
            mutex.lock()
            for project in unique { self.projects.removeValue(forKey: project) }
            if let removal, let index = removals.firstIndex(of: removal) { removals.remove(at: index) }
            mutex.unlock()
        }
        return try body()
    }

    func checkMutation(of projects: [ProjectId]) throws {
        mutex.lock()
        defer { mutex.unlock() }
        if projects.contains(where: { self.projects[$0] != nil }) {
            throw gitError("Project has an active worktree operation; retry when it completes")
        }
    }

    func checkSession(directory: String) throws {
        let directory = canonical(directory)
        mutex.lock()
        defer { mutex.unlock() }
        if removals.contains(where: { directory == $0 || directory.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) {
            throw gitError("Worktree is being removed")
        }
    }
}
