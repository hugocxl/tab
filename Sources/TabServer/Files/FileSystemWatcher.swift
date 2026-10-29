import CoreServices
import Foundation

/// Watches folders recursively with FSEvents and reports changed paths after
/// they have been quiet for `debounce`, on a private queue.
final class FileSystemWatcher: @unchecked Sendable {
    struct Batch: Sendable {
        /// Absolute paths, symlinks not resolved, in arrival order without repeats.
        var paths: [String] = []
        /// FSEvents dropped events or a watched root changed: read everything again.
        var rescan = false
    }

    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let handler: @Sendable (Batch) -> Void
    private var stream: FSEventStreamRef?
    private var pending = Batch()
    private var pendingSet = Set<String>()
    private var scheduled: DispatchWorkItem?
    private var pendingSince: Date?
    private var stopped = false

    /// Starts watching `roots`. `handler` runs on the watcher's queue.
    init(roots: [String], debounce: TimeInterval, label: String = "tab.watch",
         handler: @escaping @Sendable (Batch) -> Void) throws {
        self.queue = DispatchQueue(label: label)
        self.debounce = debounce
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context, roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags
        ) else {
            throw ServiceError(.badRequest, "Couldn't watch \(roots.first ?? "the folder")")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            throw ServiceError(.badRequest, "Couldn't watch \(roots.first ?? "the folder")")
        }
    }

    deinit { stop() }

    /// Stops delivering events; safe to call more than once and from any queue
    /// except the watcher's own.
    func stop() {
        queue.sync {
            stopped = true
            scheduled?.cancel()
            scheduled = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        var batch = Batch()
        let rescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        for index in 0 ..< count {
            if flags[index] & rescanFlags != 0 { batch.rescan = true }
            if let path = array[index] as? String { batch.paths.append(path) }
        }
        watcher.receive(batch)
    }

    /// Runs on `queue`.
    private func receive(_ batch: Batch) {
        guard !stopped else { return }
        if batch.rescan { pending.rescan = true }
        for path in batch.paths where pendingSet.insert(path).inserted {
            pending.paths.append(path)
        }
        let now = Date()
        let since = pendingSince ?? now
        pendingSince = since
        // Continuous changes still report at least every few debounce periods.
        if scheduled != nil, now.timeIntervalSince(since) >= debounce * 4 { return }
        scheduled?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        scheduled = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func flush() {
        guard !stopped else { return }
        let batch = pending
        pending = Batch()
        pendingSet.removeAll()
        pendingSince = nil
        scheduled = nil
        guard batch.rescan || !batch.paths.isEmpty else { return }
        handler(batch)
    }
}
