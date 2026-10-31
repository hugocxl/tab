import Foundation
import WebKit

/// One immutable, caller-owned resource. This responder has no file paths,
/// conversation delegates or JavaScript privileges and is also used by previews.
@MainActor
struct AgentConversationRangedResource {
    typealias Read = @MainActor (UInt64, UInt32) async throws -> Data
    let length: UInt64
    let mimeType: String
    let revision: String
    let read: Read
    static let chunkSize: UInt32 = 256 * 1024

    enum Selection: Equatable { case full, range(UInt64, UInt64), unsatisfiable }
    static func selection(_ request: URLRequest, length: UInt64) -> Selection {
        guard request.httpMethod != "HEAD", request.value(forHTTPHeaderField: "If-Range") == nil,
              let rawHeader = request.value(forHTTPHeaderField: "Range") else { return .full }
        let header = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        guard header.lowercased().hasPrefix("bytes=") else { return .full }
        let values = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard values.count == 2, values.allSatisfy({ $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
              !values.allSatisfy(\.isEmpty) else { return .full }
        func decimal(_ value: Substring) -> String? {
            guard !value.isEmpty else { return nil }
            let significant = value.drop(while: { $0 == "0" })
            return significant.isEmpty ? "0" : String(significant)
        }
        func less(_ lhs: String, _ rhs: String) -> Bool {
            lhs.count == rhs.count ? lhs.lexicographicallyPrecedes(rhs) : lhs.count < rhs.count
        }
        let first = decimal(values[0]), last = decimal(values[1]), size = String(length)
        if let first, let last, less(last, first) { return .full }
        guard length > 0 else { return .unsatisfiable }
        let start: UInt64, end: UInt64
        if let first {
            guard less(first, size), let parsed = UInt64(first) else { return .unsatisfiable }
            start = parsed
            end = last.flatMap { less($0, size) ? UInt64($0) : nil } ?? (length - 1)
        } else {
            guard let last, last != "0" else { return .unsatisfiable }
            start = less(last, size) ? length - (UInt64(last) ?? length) : 0
            end = length - 1
        }
        let safe: UInt64 = 9_007_199_254_740_991
        guard start <= safe, end <= safe else { return .unsatisfiable }
        return .range(start, end)
    }

    func respond(to task: any WKURLSchemeTask) async throws {
        guard let url = task.request.url else { throw ModelError("Invalid media URL.") }
        let selection = Self.selection(task.request, length: length)
        var headers = ["Content-Type": mimeType, "Accept-Ranges": "bytes", "Cache-Control": "private, no-store",
                       "X-Content-Type-Options": "nosniff",
                       "Content-Security-Policy": "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data: blob: tab-conversation:"]
        let start: UInt64, count: UInt64, status: Int
        switch selection {
        case .full: start = 0; count = length; status = 200
        case .range(let first, let last):
            start = first; count = last - first + 1; status = 206
            headers["Content-Range"] = "bytes \(first)-\(last)/\(length)"
        case .unsatisfiable:
            start = 0; count = 0; status = 416
            headers["Content-Range"] = "bytes */\(length)"
        }
        headers["Content-Length"] = String(count)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw ModelError("Invalid media response.")
        }
        try Task.checkCancellation()
        task.didReceive(response)
        if task.request.httpMethod != "HEAD", status != 416 {
            var offset = start
            let end = start + count
            while offset < end {
                try Task.checkCancellation()
                let requested = UInt32(min(UInt64(Self.chunkSize), end - offset))
                let data = try await read(offset, requested)
                try Task.checkCancellation()
                guard data.count == Int(requested) else { throw ModelError("The media changed or returned an incomplete range.") }
                task.didReceive(data)
                offset += UInt64(data.count)
            }
        }
        try Task.checkCancellation()
        task.didFinish()
    }
}
