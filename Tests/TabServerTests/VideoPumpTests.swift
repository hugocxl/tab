import Foundation
import TabProtocol
import XCTest
@testable import TabServer

/// A simulator channel sends at most one frame in flight, and a screen that
/// drew meanwhile is encoded once, as it is when credit returns.
final class VideoPumpTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private var keyframes: [Bool] = []
        func encoded(keyframe: Bool) -> Int {
            lock.withLock {
                value += 1
                keyframes.append(keyframe)
                return value
            }
        }
        var count: Int { lock.withLock { value } }
        var kinds: [Bool] { lock.withLock { keyframes } }
    }

    private func frame(_ keyframe: Bool) -> VideoFrame {
        VideoFrame(seq: 0, keyframe: keyframe, width: 2, height: 2, parameterSets: keyframe ? [Data([1])] : [],
                   sample: Data([0, 0, 0, 1, 9]))
    }

    private final class Box: @unchecked Sendable {
        var data: Data?
    }

    /// The outbox's next video frame and its channel. A read that times out
    /// stays blocked, so the outbox is closed at the end of each test.
    private func nextVideo(_ outbox: Outbox, timeout: TimeInterval = 2) -> (ChannelId, VideoFrame)? {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        Thread {
            box.data = outbox.next()
            done.signal()
        }.start()
        var reader = FrameReader()
        guard done.wait(timeout: .now() + timeout) == .success, let data = box.data,
              let frame = try? reader.frames(from: data).first?.decoded(),
              case .video(let channel, let video) = frame else { return nil }
        return (channel, video)
    }

    private func next(_ outbox: Outbox) -> VideoFrame? {
        nextVideo(outbox)?.1
    }

    private func settle(_ queue: DispatchQueue) {
        queue.sync {}
        queue.sync {}
    }

    func testOneFrameIsInFlightAndADirtyScreenEncodesOnceWhenCreditReturns() throws {
        let outbox = Outbox()
        let queue = DispatchQueue(label: "pump")
        let counter = Counter()
        let channel = ChannelId(3)
        defer { outbox.close() }
        let pump = VideoPump(channel: channel, queue: queue, outbox: outbox) { [self] keyframe in
            _ = counter.encoded(keyframe: keyframe)
            return frame(keyframe)
        }
        pump.open()
        pump.screenChanged(keyframe: true)
        settle(queue)
        XCTAssertEqual(counter.count, 0, "frames wait for the attach reply")
        pump.begin()
        settle(queue)
        let first = try XCTUnwrap(next(outbox))
        XCTAssertTrue(first.keyframe, "a stream starts with a keyframe")
        for _ in 0..<50 { pump.screenChanged() }
        settle(queue)
        XCTAssertEqual(counter.count, 1, "no credit, no encoding: the screen is only marked dirty")
        outbox.ack(UInt64(first.seq), on: channel)
        settle(queue)
        XCTAssertEqual(counter.count, 2, "the dirty screen encodes once when credit returns")
        let second = try XCTUnwrap(next(outbox))
        XCTAssertEqual(second.seq, first.seq + 1)
        XCTAssertEqual(counter.kinds, [true, false])
        outbox.ack(UInt64(second.seq), on: channel)
        settle(queue)
        XCTAssertEqual(counter.count, 2, "an idle screen sends nothing")
        outbox.ack(UInt64(second.seq), on: channel)
        pump.screenChanged(keyframe: true)
        settle(queue)
        XCTAssertEqual(counter.kinds.last, true, "a requested keyframe comes next")
    }

    func testTwoChannelsAtDifferentSpeedsDontWaitForEachOther() throws {
        let outbox = Outbox()
        let fast = DispatchQueue(label: "fast")
        let slow = DispatchQueue(label: "slow")
        let fastCount = Counter()
        let slowCount = Counter()
        let fastPump = VideoPump(channel: ChannelId(1), queue: fast, outbox: outbox) { [self] keyframe in
            _ = fastCount.encoded(keyframe: keyframe)
            return frame(keyframe)
        }
        let slowPump = VideoPump(channel: ChannelId(2), queue: slow, outbox: outbox) { [self] keyframe in
            _ = slowCount.encoded(keyframe: keyframe)
            return frame(keyframe)
        }
        fastPump.open()
        slowPump.open()
        fastPump.begin()
        slowPump.begin()
        defer { outbox.close() }
        for round in 0..<10 {
            fastPump.screenChanged()
            slowPump.screenChanged()
            settle(fast)
            settle(slow)
            // Both channels send in the first round; then only the one that acknowledges.
            for _ in 0..<(round == 0 ? 2 : 1) {
                let (channel, frame) = try XCTUnwrap(nextVideo(outbox))
                if channel == ChannelId(1) { outbox.ack(UInt64(frame.seq), on: channel) }
            }
            settle(fast)
        }
        XCTAssertEqual(slowCount.count, 1, "the slow channel waits for its own acknowledgement")
        XCTAssertGreaterThan(fastCount.count, 5, "the fast channel keeps going")
    }
}
