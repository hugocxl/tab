import Foundation
import WebKit
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationRangedResourceTests: XCTestCase {
    private func request(_ range: String?, method: String = "GET", ifRange: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "tab-conversation://bundle/__resource/test")!)
        request.httpMethod = method
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue(ifRange, forHTTPHeaderField: "If-Range")
        return request
    }

    func testPinnedSourceRangePolicy() {
        typealias Resource = AgentConversationRangedResource
        XCTAssertEqual(Resource.selection(request(nil), length: 10), .full)
        XCTAssertEqual(Resource.selection(request("bytes=2-4"), length: 10), .range(2, 4))
        XCTAssertEqual(Resource.selection(request("BYTES=2-99"), length: 10), .range(2, 9))
        XCTAssertEqual(Resource.selection(request("bytes=-3"), length: 10), .range(7, 9))
        XCTAssertEqual(Resource.selection(request("bytes=-30"), length: 10), .range(0, 9))
        XCTAssertEqual(Resource.selection(request("bytes=-999999999999999999999999"), length: 10), .range(0, 9))
        XCTAssertEqual(Resource.selection(request(" bytes=1-999999999999999999999999 "), length: 10), .range(1, 9))
        XCTAssertEqual(Resource.selection(request("bytes=2-"), length: 10), .range(2, 9))
        for value in ["invalid", "bytes=3-2", "bytes=0-1,3-4", "bytes=a-b", "bytes=-", "bytes=١-٢", "bytes=999999999999999999999999-1"] {
            XCTAssertEqual(Resource.selection(request(value), length: 10), .full, value)
        }
        for value in ["bytes=10-", "bytes=-0", "bytes=9007199254740992-", "bytes=999999999999999999999999-"] {
            XCTAssertEqual(Resource.selection(request(value), length: 10), .unsatisfiable, value)
        }
        XCTAssertEqual(Resource.selection(request("bytes=0-"), length: 0), .unsatisfiable)
        XCTAssertEqual(Resource.selection(request("bytes=2-4", method: "HEAD"), length: 10), .full)
        XCTAssertEqual(Resource.selection(request("bytes=2-4", ifRange: "anything"), length: 10), .full)
    }

    private final class SchemeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        var response: HTTPURLResponse?
        var bytes = Data()
        var finished = false
        init(_ request: URLRequest) { self.request = request }
        func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
        func didReceive(_ data: Data) { bytes.append(data) }
        func didFinish() { finished = true }
        func didFailWithError(_ error: Error) { XCTFail("Unexpected scheme failure: \(error)") }
    }

    func testStreamsBoundedChunksAndHeadDoesNotReadBytes() async throws {
        let data = Data((0..<700_000).map { UInt8($0 % 251) })
        var reads: [(UInt64, UInt32)] = []
        let resource = AgentConversationRangedResource(length: UInt64(data.count), mimeType: "video/mp4", revision: "recorded") { offset, count in
            reads.append((offset, count))
            return data.subdata(in: Int(offset)..<Int(offset) + Int(count))
        }
        let full = SchemeTask(request(nil))
        try await resource.respond(to: full)
        XCTAssertEqual(full.response?.statusCode, 200)
        XCTAssertEqual(full.bytes, data)
        XCTAssertEqual(reads.count, 3)
        XCTAssertTrue(reads.allSatisfy { $0.1 <= 256 * 1024 })
        let partial = SchemeTask(request("bytes=260000-530000"))
        try await resource.respond(to: partial)
        XCTAssertEqual(partial.response?.statusCode, 206)
        XCTAssertEqual(partial.response?.value(forHTTPHeaderField: "Content-Range"), "bytes 260000-530000/700000")
        XCTAssertEqual(partial.bytes, data.subdata(in: 260000..<530001))
        let countBeforeHead = reads.count
        let head = SchemeTask(request("bytes=0-9", method: "HEAD"))
        try await resource.respond(to: head)
        XCTAssertEqual(head.response?.statusCode, 200)
        XCTAssertEqual(head.response?.expectedContentLength, 700000)
        XCTAssertEqual(reads.count, countBeforeHead)
        XCTAssertTrue(head.bytes.isEmpty)
        let invalid = SchemeTask(request("bytes=700000-"))
        try await resource.respond(to: invalid)
        XCTAssertEqual(invalid.response?.statusCode, 416)
        XCTAssertEqual(invalid.response?.value(forHTTPHeaderField: "Content-Range"), "bytes */700000")
        XCTAssertTrue(invalid.finished)
    }
}
