import XCTest
@testable import TabProtocol

/// One frozen fixture per message type in `Fixtures/v1/messages`, written by
/// the build that added the type. Every later build must still read each one
/// as that type, so a renamed case, a renamed or retyped field, or a new
/// required field fails here instead of on users' mixed-version setups.
/// A missing fixture is written from the current encoder.
final class WireHistoryTests: XCTestCase {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/v1/messages")

    private struct Entry {
        let name: String
        let message: Message
    }

    /// `type`, and for Git and file requests and replies the action's too.
    private static func name(_ kind: String, _ message: Message) throws -> String {
        let object = try JSONSerialization.jsonObject(with: try WireJSON.encode(message)) as? [String: Any]
        let body = object?["body"] as? [String: Any]
        var parts = [kind, body?["type"] as? String ?? ""]
        let nested = (body?["request"] as? [String: Any])?["action"] as? [String: Any]
            ?? body?["reply"] as? [String: Any]
        if let nested, let type = nested["type"] as? String { parts.append(type) }
        return parts.joined(separator: "-") + ".json"
    }

    private static func entries() throws -> [Entry] {
        var messages: [(String, Message)] = []
        messages += Samples.requests.map { ("request", .request(RequestId(1), $0)) }
        messages += Samples.gitActions.map { ("request", .request(RequestId(1), .git(GitRequest(project: Samples.project, action: $0)))) }
        messages += Samples.filesActions.map { ("request", .request(RequestId(1), .files(FilesRequest(project: Samples.project, action: $0)))) }
        messages += Samples.replies.map { ("reply", .reply(RequestId(1), $0)) }
        messages += Samples.gitReplies.map { ("reply", .reply(RequestId(1), .git($0))) }
        messages += Samples.filesReplies.map { ("reply", .reply(RequestId(1), .files($0))) }
        messages += Samples.events.map { ("event", .event($0)) }
        var seen: Set<String> = []
        return try messages.compactMap { kind, message in
            guard !isUnknown(message) else { return nil }
            let name = try name(kind, message)
            return seen.insert(name).inserted ? Entry(name: name, message: message) : nil
        }
    }

    func testEveryMessageTypeStillReadsAsItself() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for entry in try Self.entries() {
            let url = Self.directory.appendingPathComponent(entry.name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try WireJSON.encode(entry.message).write(to: url, options: .atomic)
            }
            let decoded = try WireJSON.decode(Message.self, from: Data(contentsOf: url))
            XCTAssertEqual(try Self.name(String(entry.name.prefix { $0 != "-" }), decoded), entry.name,
                           "\(entry.name) no longer reads as the same message type")
            XCTAssertFalse(Self.isUnknown(decoded), "\(entry.name) reads as an unknown message")
        }
    }

    /// Fixtures stay even when their sample goes, since old builds still send them.
    func testNoFixtureLosesItsMessage() throws {
        let names = Set(try Self.entries().map(\.name))
        let stored = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path).filter { $0.hasSuffix(".json") }
        for file in stored where !names.contains(file) {
            let decoded = try WireJSON.decode(Message.self, from: Data(contentsOf: Self.directory.appendingPathComponent(file)))
            XCTAssertFalse(Self.isUnknown(decoded), "\(file) reads as an unknown message; keep its case")
        }
    }

    private static func isUnknown(_ message: Message) -> Bool {
        switch message {
        case .unknown, .request(_, .unknown), .reply(_, .unknown), .event(.unknown): true
        default: false
        }
    }
}
