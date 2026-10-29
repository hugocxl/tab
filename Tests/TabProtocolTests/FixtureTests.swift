import XCTest
@testable import TabProtocol

/// Messages and screens encoded by protocol version 1, kept in
/// `Fixtures/v1`. Every later build must still read them. A missing fixture
/// is written from the current encoder; set `TAB_UPDATE_FIXTURES=1` to
/// rewrite them all (only while version 1 is unreleased).
final class FixtureTests: XCTestCase {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/v1")

    private struct Fixture {
        let name: String
        let encode: () throws -> Data
        let check: (Data) throws -> Void
    }

    /// The first sample whose JSON `type` (and nested `type`) match, so
    /// fixtures don't depend on sample order.
    private static func sample<T: Encodable>(_ values: [T], _ type: String, _ nested: String? = nil) -> T {
        let match = values.first { value in
            guard let data = try? WireJSON.encode(value),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == type else { return false }
            guard let nested else { return true }
            return object.values.contains { ($0 as? [String: Any])?["type"] as? String == nested }
        }
        guard let match else { fatalError("no \(type) sample") }
        return match
    }

    private static func json<T: Codable & Equatable>(_ name: String, _ value: T) -> Fixture {
        Fixture(name: name, encode: { try WireJSON.encode(value) }, check: { data in
            XCTAssertEqual(try WireJSON.decode(T.self, from: data), value, name)
        })
    }

    private static let screen = ScreenFrame(
        size: Size(cols: 10, rows: 2), seq: 42, reset: true, rows: Samples.rows,
        cursor: Cursor(shape: .bar, row: 1, col: 3, visible: true), modes: Modes(), graphics: Samples.graphics,
        historyRows: 1000
    )

    private static let fixtures: [Fixture] = [
        json("request-hello.json", Message.request(RequestId(1), sample(Samples.requests, "hello"))),
        json("request-createSession.json", Message.request(RequestId(2), sample(Samples.requests, "createSession"))),
        json("request-git-worktree-create.json",
             Message.request(RequestId(3), .git(GitRequest(project: Samples.project, action: sample(Samples.gitActions, "worktree"))))),
        json("request-files-searchContent.json",
             Message.request(RequestId(4), .files(FilesRequest(project: Samples.project,
                                                               action: sample(Samples.filesActions, "searchContent"))))),
        json("reply-attached.json", Message.reply(RequestId(5), sample(Samples.replies, "attached"))),
        json("reply-catalog.json", Message.reply(RequestId(6), sample(Samples.replies, "catalog"))),
        json("reply-git-status.json", Message.reply(RequestId(7), .git(sample(Samples.gitReplies, "status")))),
        json("reply-remoteAccess.json", Message.reply(RequestId(8), sample(Samples.replies, "remoteAccess"))),
        json("event-sessionEnded.json", Message.event(sample(Samples.events, "sessionEnded"))),
        json("session-links.json", sample(Samples.sessionMessages, "metadata", "links")),
        json("session-key.json", sample(Samples.sessionMessages, "input", "key")),
        Fixture(name: "screen-frame.bin", encode: { ScreenCodec.encode(screen) }, check: { data in
            XCTAssertEqual(try ScreenCodec.decode(data), screen)
        }),
        Fixture(name: "history-rows.bin", encode: { ScreenCodec.encodeRows(Samples.rows) }, check: { data in
            XCTAssertEqual(try ScreenCodec.decodeRows(data), Samples.rows)
        }),
        Fixture(name: "stream.bin", encode: {
            var stream = try FrameEncoder.encode(Message.request(RequestId(1), .ping))
            stream.append(try FrameEncoder.encode(.ack(42), channel: ChannelId(3)))
            stream.append(try FrameEncoder.encode(screen: screen, channel: ChannelId(3)))
            stream.append(try FrameEncoder.encode(input: Data("echo hi\r".utf8), channel: ChannelId(3)))
            return stream
        }, check: { data in
            var reader = FrameReader()
            let frames = try reader.frames(from: data).map { try $0.decoded() }
            try reader.finish()
            XCTAssertEqual(frames, [
                .message(.request(RequestId(1), .ping)), .session(ChannelId(3), .ack(42)),
                .screen(ChannelId(3), screen), .input(ChannelId(3), Data("echo hi\r".utf8)),
            ])
        }),
    ]

    func testVersionOneFixturesStillDecode() throws {
        let update = ProcessInfo.processInfo.environment["TAB_UPDATE_FIXTURES"] == "1"
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for fixture in Self.fixtures {
            let url = Self.directory.appendingPathComponent(fixture.name)
            if update || !FileManager.default.fileExists(atPath: url.path) {
                try fixture.encode().write(to: url, options: .atomic)
            }
            try fixture.check(try Data(contentsOf: url))
        }
    }
}
