import Foundation

/// A page the profile visited or bookmarked.
public struct BrowserHistoryEntry: Codable, Equatable, Sendable {
    public var url: String
    public var title: String?
    public var visitCount: Int
    public var lastVisit: Date
    /// Imported from another browser's bookmarks.
    public var bookmarked: Bool
    /// Source and timestamp keys make repeated imports idempotent.
    public var importedVisits: [String]

    public init(url: String, title: String? = nil, visitCount: Int = 1, lastVisit: Date = Date(), bookmarked: Bool = false, importedVisits: [String] = []) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisit = lastVisit
        self.bookmarked = bookmarked
        self.importedVisits = importedVisits
    }

    private enum CodingKeys: String, CodingKey { case url, title, visitCount, lastVisit, bookmarked, importedVisits }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        visitCount = try container.decodeIfPresent(Int.self, forKey: .visitCount) ?? 1
        lastVisit = try container.decodeIfPresent(Date.self, forKey: .lastVisit) ?? Date(timeIntervalSince1970: 0)
        bookmarked = try container.decodeIfPresent(Bool.self, forKey: .bookmarked) ?? false
        importedVisits = try container.decodeIfPresent([String].self, forKey: .importedVisits) ?? []
    }
}

/// One profile's browsing history, kept by the app in
/// `browser-history.json` in the profile's folder. It feeds the address
/// bar's suggestions: recent pages when nothing is typed, otherwise matching
/// pages by visit count.
@MainActor
public final class BrowserHistoryStore {
    public nonisolated static let suggestionLimit = 8

    public let file: URL
    public private(set) var entries: [BrowserHistoryEntry] = []
    private var index: [String: Int] = [:]
    private var saveScheduled = false
    private let saveDelay: TimeInterval
    private let allowedRoot: URL?

    private var accessible: Bool {
        guard let allowedRoot else { return true }
        return file.resolvingSymlinksInPath().path.hasPrefix(allowedRoot.resolvingSymlinksInPath().path + "/")
    }

    /// Reads `file` when it exists; a damaged file starts an empty history.
    public init(file: URL, saveDelay: TimeInterval = 1, confinedTo allowedRoot: URL? = nil) {
        self.file = file
        self.saveDelay = saveDelay
        self.allowedRoot = allowedRoot
        guard accessible, let data = try? Data(contentsOf: file) else { return }
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
                if entry.importedVisits.isEmpty {
                    entries[position].visitCount += entry.visitCount
                } else {
                    let known = Set(entries[position].importedVisits)
                    let added = Set(entry.importedVisits).subtracting(known)
                    entries[position].visitCount += added.count
                    entries[position].importedVisits.append(contentsOf: added.sorted())
                }
                if let title = entry.title, !title.isEmpty,
                   entries[position].title == nil || entry.lastVisit >= entries[position].lastVisit {
                    entries[position].title = title
                }
                entries[position].lastVisit = max(entries[position].lastVisit, entry.lastVisit)
                entries[position].bookmarked = entries[position].bookmarked || entry.bookmarked
            } else {
                index[entry.url] = entries.count
                entries.append(entry)
                added += 1
            }
        }
        scheduleSave()
        return added
    }

    /// Suggestions follow Codesh's history query: literal text in the URL
    /// or title, most visited first, with ties broken by recency. An empty
    /// query shows recent visits. Unvisited bookmarks do not appear.
    public func suggestions(for query: String, limit: Int = suggestionLimit) -> [BrowserHistoryEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = entries.enumerated().filter { _, entry in
            guard entry.visitCount > 0 else { return false }
            guard !query.isEmpty else { return true }
            return entry.url.range(of: query, options: .caseInsensitive) != nil
                || entry.title?.range(of: query, options: .caseInsensitive) != nil
        }
        return matches.sorted { lhs, rhs in
            if !query.isEmpty, lhs.element.visitCount != rhs.element.visitCount {
                return lhs.element.visitCount > rhs.element.visitCount
            }
            if lhs.element.lastVisit != rhs.element.lastVisit { return lhs.element.lastVisit > rhs.element.lastVisit }
            return lhs.offset > rhs.offset
        }.prefix(max(limit, 0)).map(\.element)
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
        guard accessible else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func isRecordable(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
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
