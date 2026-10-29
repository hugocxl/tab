import Foundation

/// A page the profile visited or bookmarked.
public struct BrowserHistoryEntry: Codable, Equatable, Sendable {
    public var url: String
    public var title: String?
    public var visitCount: Int
    public var lastVisit: Date
    /// Imported from another browser's bookmarks.
    public var bookmarked: Bool

    public init(url: String, title: String? = nil, visitCount: Int = 1, lastVisit: Date = Date(), bookmarked: Bool = false) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisit = lastVisit
        self.bookmarked = bookmarked
    }

    private enum CodingKeys: String, CodingKey { case url, title, visitCount, lastVisit, bookmarked }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        visitCount = try container.decodeIfPresent(Int.self, forKey: .visitCount) ?? 1
        lastVisit = try container.decodeIfPresent(Date.self, forKey: .lastVisit) ?? Date(timeIntervalSince1970: 0)
        bookmarked = try container.decodeIfPresent(Bool.self, forKey: .bookmarked) ?? false
    }
}

/// One profile's browsing history, kept by the app in
/// `browser-history.json` in the profile's folder. It feeds the address
/// bar's suggestions: recent pages when nothing is typed, otherwise matching
/// pages by visit count.
@MainActor
public final class BrowserHistoryStore {
    /// How many pages are kept; the least recently visited go first.
    public nonisolated static let capacity = 5_000
    public nonisolated static let suggestionLimit = 8

    public let file: URL
    public private(set) var entries: [BrowserHistoryEntry] = []
    private var index: [String: Int] = [:]
    private var saveScheduled = false
    private let saveDelay: TimeInterval

    /// Reads `file` when it exists; a damaged file starts an empty history.
    public init(file: URL, saveDelay: TimeInterval = 1) {
        self.file = file
        self.saveDelay = saveDelay
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        entries = (try? decoder.decode([BrowserHistoryEntry].self, from: data)) ?? []
        rebuildIndex()
    }

    /// Counts a visit to `url`, keeping the newest non-empty title.
    public func recordVisit(url: String, title: String?, at date: Date = Date()) {
        guard Self.isRecordable(url) else { return }
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let position = index[url] {
            entries[position].visitCount += 1
            entries[position].lastVisit = date
            if let title, !title.isEmpty { entries[position].title = title }
        } else {
            index[url] = entries.count
            entries.append(BrowserHistoryEntry(url: url, title: title?.isEmpty == false ? title : nil, lastVisit: date))
            trim()
        }
        scheduleSave()
    }

    /// Sets the title of a page already visited, as titles arrive after loads.
    public func updateTitle(url: String, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let position = index[url], entries[position].title != title else { return }
        entries[position].title = title
        scheduleSave()
    }

    /// Adds pages from another browser. Visits add up; bookmarks are marked.
    /// Returns how many pages were new.
    @discardableResult
    public func merge(_ imported: [BrowserHistoryEntry]) -> Int {
        var added = 0
        for entry in imported where Self.isRecordable(entry.url) {
            if let position = index[entry.url] {
                entries[position].visitCount += entry.visitCount
                entries[position].lastVisit = max(entries[position].lastVisit, entry.lastVisit)
                entries[position].bookmarked = entries[position].bookmarked || entry.bookmarked
                if entries[position].title == nil { entries[position].title = entry.title }
            } else {
                index[entry.url] = entries.count
                entries.append(entry)
                added += 1
            }
        }
        trim()
        scheduleSave()
        return added
    }

    /// Suggestions for what was typed: the most recent pages when `query` is
    /// empty, else pages whose address or title contains every word,
    /// most visited first (bookmarks count as visited often).
    public func suggestions(for query: String, limit: Int = suggestionLimit) -> [BrowserHistoryEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return Array(entries.sorted { $0.lastVisit > $1.lastVisit }.prefix(limit))
        }
        let matches = entries.filter { entry in
            let haystack = (entry.url + " " + (entry.title ?? "")).lowercased()
            return words.allSatisfy(haystack.contains)
        }
        return Array(matches.sorted { lhs, rhs in
            let left = Self.rank(lhs, words), right = Self.rank(rhs, words)
            if left != right { return left > right }
            return lhs.lastVisit > rhs.lastVisit
        }.prefix(limit))
    }

    /// Forgets every page.
    public func clear() {
        entries.removeAll()
        index.removeAll()
        saveNow()
    }

    /// Writes pending changes now, such as before quitting.
    public func saveNow() {
        saveScheduled = false
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func rank(_ entry: BrowserHistoryEntry, _ words: [String]) -> Int {
        var score = entry.visitCount + (entry.bookmarked ? 10 : 0)
        let host = BrowserHistoryStore.hostAndPath(entry.url)
        if let first = words.first, host.hasPrefix(first) { score += 1_000 }
        return score
    }

    /// The address without its scheme or `www.`, for prefix matches.
    static func hostAndPath(_ url: String) -> String {
        var text = url.lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text
    }

    private static func isRecordable(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    private func trim() {
        guard entries.count > Self.capacity else { return }
        entries.sort { $0.lastVisit > $1.lastVisit }
        entries.removeLast(entries.count - Self.capacity)
        rebuildIndex()
    }

    private func rebuildIndex() {
        index = [:]
        for (position, entry) in entries.enumerated() { index[entry.url] = position }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.saveScheduled else { return }
                self.saveNow()
            }
        }
    }
}
