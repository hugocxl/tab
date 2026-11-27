import Foundation

/// Reads the archives of items conversations dropped past their size limit, one JSON
/// line each, however long they grow. Each file is memory-mapped and its line positions
/// are indexed once, then extended as it grows, so a page touches only its own lines.
/// Positions count non-empty lines, an unterminated last line included.
final class AgentEarlierArchive: @unchecked Sendable {
    /// The lines of one archive as it was when read, mapped rather than copied.
    struct Lines {
        fileprivate let data: Data
        fileprivate let ranges: [Range<Int>]
        fileprivate let tail: Range<Int>?

        var count: Int { ranges.count + (tail == nil ? 0 : 1) }

        subscript(position: Int) -> Data {
            let range = position < ranges.count ? ranges[position] : (tail ?? 0..<0)
            return data.subdata(in: range)
        }
    }

    private struct Index {
        var fileNumber: Int
        var ranges: [Range<Int>] = []
        /// Bytes scanned so far, up to just past the last newline.
        var scanned = 0
        var lastUse: UInt64 = 0
    }

    private let lock = NSLock()
    private var indexes: [String: Index] = [:]
    private var uses: UInt64 = 0
    private let indexLimit: Int

    init(indexLimit: Int = 32) { self.indexLimit = indexLimit }

    /// The archive's lines, or nil when it doesn't exist. Writes appended later aren't in
    /// the returned lines; the next read indexes them.
    func lines(of file: URL) -> Lines? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.intValue,
              let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var index = indexes[file.path] ?? Index(fileNumber: fileNumber)
        // A file replaced or shortened since is indexed again from its start.
        if index.fileNumber != fileNumber || index.scanned > data.count { index = Index(fileNumber: fileNumber) }
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var start = index.scanned
            while start < buffer.count,
                  let found = memchr(base + start, 0x0A, buffer.count - start) {
                let end = base.distance(to: UnsafeRawPointer(found))
                if end > start { index.ranges.append(start..<end) }
                start = end + 1
            }
            index.scanned = min(start, buffer.count)
        }
        uses &+= 1
        index.lastUse = uses
        indexes[file.path] = index
        if indexes.count > indexLimit, let oldest = indexes.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            indexes.removeValue(forKey: oldest)
        }
        let tail = index.scanned < data.count ? index.scanned..<data.count : nil
        return Lines(data: data, ranges: index.ranges, tail: tail)
    }
}
