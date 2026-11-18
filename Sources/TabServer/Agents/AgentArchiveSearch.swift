import Foundation
import TabProtocol

/// Find in the archive of items a conversation dropped past its size limit, with the
/// app's search semantics (`AgentTranscriptSearch`): a page of candidate items, scanning
/// from newest to oldest, that the app confirms against what it renders.
enum AgentArchiveSearch {
    /// Bytes of archive scanned per page, so one request never reads the whole archive.
    static let scanBytes = 8 * 1024 * 1024

    static func search(file: URL, query: String, before: Int?) -> AgentArchiveSearchPage {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return AgentArchiveSearchPage(query: query, items: [], positions: [], start: 0, end: 0, total: 0)
        }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let end = min(before ?? lines.count, lines.count)
        var items: [AgentChatItem] = []
        var positions: [Int] = []
        var bytes = 0
        var scanned = 0
        var start = end
        let decoder = JSONDecoder()
        while start > 0, items.count < AgentArchiveSearchPage.maxItems, scanned < scanBytes {
            let line = lines[start - 1]
            scanned += line.count
            guard let item = try? decoder.decode(AgentChatItem.self, from: Data(line)),
                  AgentTranscriptSearch.mayMatch(query, item: item) else { start -= 1; continue }
            guard bytes + item.transcriptByteCount <= AgentArchiveSearchPage.maxBytes else { break }
            bytes += item.transcriptByteCount
            items.append(item)
            positions.append(start - 1)
            start -= 1
        }
        return AgentArchiveSearchPage(query: query, items: items.reversed(), positions: positions.reversed(),
                                      start: start, end: end, total: lines.count)
    }
}
