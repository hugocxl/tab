import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class ConnectionOutboxTests: XCTestCase {
    private let channel = ChannelId(1)

    private func row(_ index: UInt16, _ text: String) -> Row {
        Row(index: index, runs: [Run(text: text, width: UInt16(text.count))])
    }

    private func frame(_ seq: UInt64, _ rows: [Row], cursor: UInt16 = 0, reset: Bool = false) -> ScreenFrame {
        ScreenFrame(size: Size(cols: 80, rows: 24), seq: seq, reset: reset, rows: rows,
                    cursor: Cursor(row: cursor, col: 0))
    }

    private func decode(_ data: Data?) throws -> IncomingFrame {
        var reader = FrameReader()
        let frames = try reader.frames(from: try XCTUnwrap(data))
        return try XCTUnwrap(frames.first).decoded()
    }

    /// A blocked `next()` on its own thread, read with a deadline.
    private final class Pending: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private var data: Data?

        init(_ outbox: Outbox) {
            Thread { [self] in
                data = outbox.next()
                done.signal()
            }.start()
        }

        func value(timeout: TimeInterval = 0.3) -> Data? {
            done.wait(timeout: .now() + timeout) == .success ? data : nil
        }
    }

    private func next(_ outbox: Outbox) -> Data? {
        Pending(outbox).value(timeout: 2)
    }

    func testOneFrameIsInFlightAndNewerOutputMergesIntoTheWaitingOne() throws {
        let outbox = Outbox()
        outbox.openChannel(channel)
        XCTAssertTrue(outbox.push(frame(1, [row(0, "a")]), on: channel))
        guard case .screen(_, let first) = try decode(next(outbox)) else { return XCTFail("first frame") }
        XCTAssertEqual(first.seq, 1)

        XCTAssertTrue(outbox.push(frame(2, [row(1, "old"), row(2, "b")], cursor: 1), on: channel))
        XCTAssertTrue(outbox.push(frame(3, [row(1, "new")], cursor: 2), on: channel))
        outbox.push(.event(.changed(topic: .catalog, revision: 4)))
        guard case .message(.event) = try decode(next(outbox)) else { return XCTFail("control goes first") }
        let waiting = Pending(outbox)
        XCTAssertNil(waiting.value(), "no frame before the ack")

        outbox.ack(1, on: channel)
        guard case .screen(_, let merged) = try decode(waiting.value(timeout: 2)) else { return XCTFail("merged frame") }
        XCTAssertEqual(merged.seq, 3)
        XCTAssertEqual(merged.rows, [row(1, "new"), row(2, "b")], "newer rows replace older ones")
        XCTAssertEqual(merged.cursor.row, 2, "the latest cursor wins")
    }

    func testAResetDropsTheRowsItReplaces() {
        var waiting = frame(2, [row(3, "stale")])
        waiting.merge(frame(3, [row(0, "fresh")], reset: true))
        XCTAssertTrue(waiting.reset)
        XCTAssertEqual(waiting.rows, [row(0, "fresh")])

        var afterReset = frame(4, [row(0, "x")], reset: true)
        afterReset.merge(frame(5, [row(1, "y")]))
        XCTAssertTrue(afterReset.reset, "a merged frame stays a reset")
        XCTAssertEqual(afterReset.rows.count, 2)
    }

    func testRepeatedChangeEventsCoalesce() throws {
        let outbox = Outbox()
        outbox.push(.event(.changed(topic: .catalog, revision: 1)))
        outbox.push(.event(.changed(topic: .catalog, revision: 2)))
        outbox.push(.event(.changed(topic: .activity, revision: 9)))
        guard case .message(.event(.changed(.catalog, 2))) = try decode(next(outbox)) else { return XCTFail() }
        guard case .message(.event(.changed(.activity, 9))) = try decode(next(outbox)) else { return XCTFail() }
        let rest = Pending(outbox)
        XCTAssertNil(rest.value())
        outbox.close()
    }

    func testAgentChangesCoalesceBySessionKeepingHighestRevision() throws {
        let outbox = Outbox()
        let first = SessionId(), second = SessionId()
        outbox.push(.event(.agentChatChanged(session: first, revision: 9)))
        outbox.push(.event(.agentChatChanged(session: first, revision: 2)))
        outbox.push(.event(.agentChatChanged(session: second, revision: 4)))
        guard case .message(.event(.agentChatChanged(first, 9))) = try decode(next(outbox)) else { return XCTFail() }
        guard case .message(.event(.agentChatChanged(second, 4))) = try decode(next(outbox)) else { return XCTFail() }
        outbox.close()
        XCTAssertNil(outbox.next(), "Only one queued invalidation per conversation")
    }

    func testAClosedChannelTakesNoFrames() {
        let outbox = Outbox()
        outbox.openChannel(channel)
        outbox.closeChannel(channel)
        XCTAssertFalse(outbox.push(frame(1, []), on: channel))
        XCTAssertFalse(outbox.push(.resized(Size(cols: 1, rows: 1)), on: channel))
    }
}
