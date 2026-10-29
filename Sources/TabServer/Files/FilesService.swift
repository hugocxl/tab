import Foundation
import TabProtocol

/// File operations, file watches and search inside server projects.
public final class FilesService: FilesServiceProtocol, @unchecked Sendable {
    /// Watches one client may hold at once.
    static let maxWatchesPerClient = 32
    static let watchDebounce: TimeInterval = 0.3

    private let projects: ProjectLocator
    private let events: ServiceEvents
    private let search: ProjectSearch
    private let state = NSLock()
    private var watches: [ClientId: [ProjectId: FileSystemWatcher]] = [:]
    private var locks: [String: WeakLock] = [:]

    public convenience init(projects: ProjectLocator, events: ServiceEvents) {
        self.init(projects: projects, events: events, lookup: .system)
    }

    init(projects: ProjectLocator, events: ServiceEvents, lookup: ExecutableLookup) {
        self.projects = projects
        self.events = events
        self.search = ProjectSearch(lookup: lookup)
    }

    deinit {
        for watcher in watches.values.flatMap(\.values) { watcher.stop() }
    }

    public func handle(_ request: FilesRequest, client: ClientId) async throws -> FilesReply {
        try request.validate()
        let directory = try projects.projectPath(request.project)
        let reply: FilesReply = try await runBlocking { [self] in
            try perform(request, directory: directory, client: client)
        }
        do {
            try reply.validate()
        } catch {
            throw ServiceError(.badRequest, "The result exceeds the protocol limits")
        }
        return reply
    }

    public func clientDisconnected(_ client: ClientId) {
        state.lock()
        let removed = watches.removeValue(forKey: client)
        state.unlock()
        removed?.values.forEach { $0.stop() }
    }

    private func perform(_ request: FilesRequest, directory: String, client: ClientId) throws -> FilesReply {
        switch request.action {
        case .watch:
            try watch(request.project, directory: directory, client: client)
            return .done
        case .unwatch:
            state.lock()
            let removed = watches[client]?.removeValue(forKey: request.project)
            state.unlock()
            removed?.stop()
            return .done
        case .searchFiles(let limit):
            let root = try ProjectRoot(path: directory)
            return .fileList(try search.files(in: root.path, limit: Int(limit)))
        case .searchContent(let query):
            let root = try ProjectRoot(path: directory)
            return .searchResults(try search.content(in: root.path, query: query))
        default:
            break
        }
        let root = try ProjectRoot(path: directory)
        let lock = lock(for: root.path)
        switch request.action {
        case .list(let path):
            return try lock.reading { .entries(try root.list(path.rawValue, ignored: search.ignoredNames)) }
        case .read(let path):
            return try lock.reading { .content(try root.read(path.rawValue)) }
        case .readBytes(let path):
            return try lock.reading { .bytes(try root.readBytes(path.rawValue)) }
        case .stat(let path):
            return try lock.reading { .info(try root.info(root.resolve(path.rawValue))) }
        case .write(let path, let content):
            return try lock.writing { .path(try root.write(path.rawValue, Data(content.utf8))) }
        case .writeBytes(let path, let bytes):
            return try lock.writing { .path(try root.write(path.rawValue, bytes)) }
        case .mkdir(let path):
            return try lock.writing { .path(try root.mkdir(path.rawValue)) }
        case .rename(let path, let name):
            return try lock.writing { .path(try root.rename(path.rawValue, to: name.rawValue)) }
        case .move(let paths, let into):
            return try lock.writing { .paths(try root.move(paths, into: into.rawValue)) }
        case .delete(let paths):
            return try lock.writing {
                try root.delete(paths)
                return .done
            }
        case .watch, .unwatch, .searchFiles, .searchContent:
            return .done
        }
    }

    private func watch(_ project: ProjectId, directory: String, client: ClientId) throws {
        let root = try ProjectRoot(path: directory)
        state.lock()
        let count = watches[client]?.count ?? 0
        let replacing = watches[client]?[project] != nil
        state.unlock()
        if count >= Self.maxWatchesPerClient, !replacing {
            throw ServiceError(.badRequest, "Too many file watches")
        }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let events = self.events
        let watcher = try FileSystemWatcher(roots: [root.path], debounce: Self.watchDebounce, label: "tab.files.watch") {
            batch in
            let changes = Self.changes(batch, root: root.path, prefix: prefix)
            guard changes.rescan || !changes.paths.isEmpty else { return }
            events.send(.filesChanged(project: project, changes: changes), to: client)
        }
        state.lock()
        let previous = watches[client]?.updateValue(watcher, forKey: project)
        if previous == nil { watches[client, default: [:]][project] = watcher }
        state.unlock()
        previous?.stop()
    }

    /// Paths relative to the project, without anything inside `.git`.
    static func changes(_ batch: FileSystemWatcher.Batch, root: String, prefix: String) -> FileChanges {
        var changes = FileChanges(rescan: batch.rescan)
        if changes.rescan { return changes }
        for path in batch.paths {
            let relative: String
            if path == root {
                relative = ""
            } else if path.hasPrefix(prefix) {
                relative = String(path.dropFirst(prefix.count))
            } else {
                continue
            }
            if relative.split(separator: "/").contains(".git") { continue }
            if relative.utf8.count > Limits.maxPathBytes {
                changes.merge(FileChanges(rescan: true))
            } else {
                changes.merge(FileChanges(paths: [ServerPath(relative)]))
            }
            if changes.rescan { break }
        }
        return changes
    }

    /// One reader-writer lock per project folder: reads overlap, changes wait.
    private func lock(for path: String) -> ReadWriteLock {
        state.lock()
        defer { state.unlock() }
        locks = locks.filter { $0.value.lock != nil }
        if let lock = locks[path]?.lock { return lock }
        let lock = ReadWriteLock()
        locks[path] = WeakLock(lock: lock)
        return lock
    }
}

private struct WeakLock {
    weak var lock: ReadWriteLock?
}

