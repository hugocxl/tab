import Foundation
import TabProtocol
import TabTerminal

/// A session's saved screen and history, as stored under `sessions/<id>/`:
///
///     screen.bin   "TABSCRN1", then three u32-length-prefixed sections:
///                  a JSON header, the rows (ScreenCodec.encodeRows), and the
///                  graphics (ScreenCodec.encodeGraphics, empty when none)
///     history.bin  "TABHIST1", u64 row count, u64 generation,
///                  (count + 1) u64 offsets into the data, then each row's
///                  runs (ScreenCodec.encodeRuns), oldest first
///
/// Integers are little-endian. Both files carry the same generation, so a
/// screen is never paired with another save's history.
struct SavedRecord {
    var screen: SavedScreen
    var history: [[Run]]
    var savedAt: UInt64

    /// A record whose screen passes `SavedScreen.validate()`.
    init(_ archive: TerminalArchive, reason: ExitReason?, savedAt: UInt64 = Clock.now()) {
        let size = archive.size
        let hasGraphics = !archive.graphics.images.isEmpty || !archive.graphics.placements.isEmpty
        let graphics = hasGraphics && (try? archive.graphics.validate()) != nil ? archive.graphics : nil
        screen = SavedScreen(size: size, rows: ScreenShape.rows(archive.rows, size: size),
                             cursor: ScreenShape.cursor(archive.cursor, size: size), graphics: graphics, reason: reason)
        history = archive.history.map { ScreenShape.fit($0, cols: Limits.maxCols) }
        self.savedAt = savedAt
    }
}

struct ScreenHeader: Codable {
    var version: Int
    var size: Size
    var cursor: Cursor
    var reason: ExitReason?
    var savedAt: UInt64
    var historyRows: UInt64
    var generation: UInt64
}

enum ArchiveFiles {
    static let screenMagic = Data("TABSCRN1".utf8)
    static let historyMagic = Data("TABHIST1".utf8)
    static let version = 1
    /// The largest screen file read back.
    static let screenLimit = 32 * 1024 * 1024

    static func folder(_ root: URL, _ session: SessionId) -> URL {
        root.appendingPathComponent(session.description, isDirectory: true)
    }

    static func screenURL(_ root: URL, _ session: SessionId) -> URL {
        folder(root, session).appendingPathComponent("screen.bin")
    }

    static func historyURL(_ root: URL, _ session: SessionId) -> URL {
        folder(root, session).appendingPathComponent("history.bin")
    }

    // MARK: Writing

    static func write(_ record: SavedRecord, root: URL, session: SessionId, durable: Bool) throws {
        try PrivateFolder.ensure(folder(root, session))
        let generation = UInt64.random(in: 1...UInt64.max)
        try replace(historyURL(root, session), with: encodeHistory(record.history, generation: generation),
                    durable: durable)
        let header = ScreenHeader(version: version, size: record.screen.size, cursor: record.screen.cursor,
                                  reason: record.screen.reason, savedAt: record.savedAt,
                                  historyRows: UInt64(record.history.count), generation: generation)
        var screen = screenMagic
        appendSection(&screen, try JSONEncoder().encode(header))
        appendSection(&screen, ScreenCodec.encodeRows(record.screen.rows))
        appendSection(&screen, record.screen.graphics.map(ScreenCodec.encodeGraphics) ?? Data())
        try replace(screenURL(root, session), with: screen, durable: durable)
    }

    static func remove(root: URL, session: SessionId) throws {
        let url = folder(root, session)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func encodeHistory(_ rows: [[Run]], generation: UInt64) -> Data {
        var data = historyMagic
        append(&data, UInt64(rows.count))
        append(&data, generation)
        var encoded: [Data] = []
        encoded.reserveCapacity(rows.count)
        var offset: UInt64 = 0
        append(&data, offset)
        for runs in rows {
            let bytes = ScreenCodec.encodeRuns(runs)
            offset += UInt64(bytes.count)
            append(&data, offset)
            encoded.append(bytes)
        }
        for bytes in encoded { data.append(bytes) }
        return data
    }

    private static func appendSection(_ data: inout Data, _ section: Data) {
        var length = UInt32(section.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(section)
    }

    private static func append(_ data: inout Data, _ value: UInt64) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    /// Writes a temporary file and renames it over `url`; `durable` also
    /// syncs, for a session's last save.
    private static func replace(_ url: URL, with data: Data, durable: Bool) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posix(temporary) }
        do {
            try data.withUnsafeBytes { buffer in
                guard var pointer = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let written = Darwin.write(descriptor, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw posix(temporary)
                    }
                    pointer += written
                    remaining -= written
                }
            }
            if durable, fsync(descriptor) != 0 { throw posix(temporary) }
            close(descriptor)
            guard rename(temporary.path, url.path) == 0 else { throw posix(url) }
        } catch {
            close(descriptor)
            unlink(temporary.path)
            throw error
        }
    }

    private static func posix(_ url: URL) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }

    // MARK: Reading

    struct Screen {
        var header: ScreenHeader
        var screen: SavedScreen
    }

    static func readScreen(root: URL, session: SessionId) throws -> Screen {
        let url = screenURL(root, session)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? Int, size <= screenLimit else {
            throw ServiceError(.savedContentUnavailable, "The saved screen is too large")
        }
        let data = try Data(contentsOf: url)
        guard data.prefix(screenMagic.count) == screenMagic else { throw corrupt() }
        var offset = screenMagic.count
        let headerBytes = try section(data, &offset)
        let rowsBytes = try section(data, &offset)
        let graphicsBytes = try section(data, &offset)
        let header = try JSONDecoder().decode(ScreenHeader.self, from: headerBytes)
        guard header.version == version else { throw corrupt() }
        let rows = try ScreenCodec.decodeRows(rowsBytes)
        let graphics = graphicsBytes.isEmpty ? nil : try ScreenCodec.decodeGraphics(graphicsBytes)
        let screen = SavedScreen(size: header.size, rows: rows, cursor: header.cursor, graphics: graphics,
                                 reason: header.reason)
        do {
            try screen.validate()
        } catch {
            throw corrupt()
        }
        return Screen(header: header, screen: screen)
    }

    private static func section(_ data: Data, _ offset: inout Int) throws -> Data {
        guard data.count >= offset + 4 else { throw corrupt() }
        let length = data[data.startIndex + offset ..< data.startIndex + offset + 4].enumerated()
            .reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        offset += 4
        guard data.count >= offset + length else { throw corrupt() }
        defer { offset += length }
        return data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + length)
    }

    static func corrupt() -> ServiceError {
        ServiceError(.savedContentUnavailable, "The saved terminal content is damaged")
    }

    /// Reads rows of `history.bin` lazily.
    final class HistoryReader {
        let count: Int
        let generation: UInt64
        private let handle: FileHandle
        private let dataStart: UInt64
        private let fileSize: UInt64

        init?(root: URL, session: SessionId, generation expected: UInt64) {
            guard let handle = try? FileHandle(forReadingFrom: historyURL(root, session)) else { return nil }
            self.handle = handle
            guard let header = try? handle.read(upToCount: 24), header.count == 24,
                  header.prefix(8) == historyMagic,
                  let size = try? handle.seekToEnd()
            else { return nil }
            let count = Self.u64(header, 8)
            let generation = Self.u64(header, 16)
            let dataStart = 24 + (count + 1) * 8
            guard generation == expected, count < UInt64(Int32.max), dataStart <= size else { return nil }
            self.count = Int(count)
            self.generation = generation
            self.dataStart = dataStart
            fileSize = size
        }

        deinit { try? handle.close() }

        /// The runs of rows `range`, oldest first.
        func rows(_ range: Range<Int>) throws -> [[Run]] {
            guard !range.isEmpty else { return [] }
            guard range.lowerBound >= 0, range.upperBound <= count else { throw corrupt() }
            try handle.seek(toOffset: 24 + UInt64(range.lowerBound) * 8)
            guard let table = try handle.read(upToCount: (range.count + 1) * 8), table.count == (range.count + 1) * 8
            else { throw corrupt() }
            let offsets = (0...range.count).map { Self.u64(table, $0 * 8) }
            guard let first = offsets.first, let last = offsets.last, first <= last,
                  dataStart + last <= fileSize else { throw corrupt() }
            try handle.seek(toOffset: dataStart + first)
            guard let bytes = try handle.read(upToCount: Int(last - first)), bytes.count == Int(last - first)
            else { throw corrupt() }
            var rows: [[Run]] = []
            rows.reserveCapacity(range.count)
            for index in 0..<range.count {
                let start = Int(offsets[index] - first)
                let end = Int(offsets[index + 1] - first)
                guard start <= end, end <= bytes.count else { throw corrupt() }
                rows.append(try ScreenCodec.decodeRuns(bytes.subdata(in: start..<end)))
            }
            return rows
        }

        private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[data.startIndex + offset + $1]) << (8 * UInt64($1)) }
        }
    }
}
