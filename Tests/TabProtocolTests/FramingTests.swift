import XCTest
@testable import TabProtocol

final class FramingTests: XCTestCase {
    func testHeaderLayoutIsBigEndian() throws {
        let data = try FrameEncoder.encode(kind: .input, channel: ChannelId(0x0102_0304), payload: Data([9, 8, 7]))
        XCTAssertEqual(Array(data), [0, 0, 0, 3, 2, 1, 2, 3, 4, 9, 8, 7])
    }

    func testFramesSurviveArbitraryChunking() throws {
        let frames = [
            Frame(kind: .json, channel: .control, payload: try WireJSON.encode(Message.request(RequestId(1), .ping))),
            Frame(kind: .input, channel: ChannelId(5), payload: Data()),
            Frame(kind: .screen, channel: ChannelId(5), payload: Data(repeating: 0xaa, count: 70_000)),
            Frame(kind: FrameKind(rawValue: 9), channel: ChannelId(2), payload: Data([1])),
        ]
        var stream = Data()
        for frame in frames { stream.append(try FrameEncoder.encode(frame)) }

        for chunkSize in [1, 2, 7, 9, 10, 4096, stream.count] {
            var reader = FrameReader()
            var received: [Frame] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                received += try reader.frames(from: stream.subdata(in: offset ..< end))
                offset = end
            }
            XCTAssertEqual(received, frames, "chunk size \(chunkSize)")
            XCTAssertNoThrow(try reader.finish())
            XCTAssertEqual(reader.bufferedByteCount, 0)
        }
    }

    func testOversizedFrameIsRejectedFromItsHeader() throws {
        var reader = FrameReader(maxFrame: 1024)
        reader.append(Data([0, 0, 4, 1, 0, 0, 0, 0, 1]))
        XCTAssertThrowsError(try reader.next()) { error in
            XCTAssertEqual(error as? FramingError, .frameTooLarge(length: 1025, limit: 1024))
        }
        // The stream stays failed.
        reader.append(try FrameEncoder.encode(kind: .json, channel: .control, payload: Data("{}".utf8)))
        XCTAssertThrowsError(try reader.next())

        XCTAssertThrowsError(try FrameEncoder.encode(kind: .input, channel: ChannelId(1),
                                                     payload: Data(count: 2048), maxFrame: 1024))
        var huge = FrameReader()
        huge.append(Data([0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0]))
        XCTAssertThrowsError(try huge.next())
    }

    func testReservedKindIsCorruptTraffic() {
        var reader = FrameReader()
        reader.append(Data([0, 0, 0, 0, 0x80, 0, 0, 0, 0]))
        XCTAssertThrowsError(try reader.next()) { error in
            XCTAssertEqual(error as? FramingError, .reservedKind(0x80))
        }
    }

    func testStreamEndingInsideAFrameIsTruncated() throws {
        var reader = FrameReader()
        let frame = try FrameEncoder.encode(input: Data([1, 2, 3]), channel: ChannelId(1))
        reader.append(frame.prefix(frame.count - 1))
        XCTAssertNil(try reader.next())
        XCTAssertThrowsError(try reader.finish()) { error in
            XCTAssertEqual(error as? FramingError, .truncated(bufferedBytes: frame.count - 1))
        }
    }

    func testGarbageNeverCrashesTheReader() {
        var generator = SeededGenerator(seed: 0x5eed)
        for _ in 0 ..< 2000 {
            var reader = FrameReader(maxFrame: 4096)
            let length = Int.random(in: 0 ..< 256, using: &generator)
            reader.append(Data((0 ..< length).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }))
            do {
                while let frame = try reader.next() { _ = try? frame.decoded() }
                try? reader.finish()
            } catch {
                XCTAssertTrue(error is FramingError)
            }
        }
    }

    func testDecodedFramesByChannel() throws {
        let control = Frame(kind: .json, channel: .control, payload: try WireJSON.encode(Message.event(.serverRestarting)))
        XCTAssertEqual(try control.decoded(), .message(.event(.serverRestarting)))
        let session = Frame(kind: .json, channel: ChannelId(3), payload: try WireJSON.encode(SessionMessage.ack(7)))
        XCTAssertEqual(try session.decoded(), .session(ChannelId(3), .ack(7)))
        let screenOnControl = Frame(kind: .screen, channel: .control, payload: Data())
        XCTAssertThrowsError(try screenOnControl.decoded())
        let future = Frame(kind: FrameKind(rawValue: 12), channel: ChannelId(1), payload: Data([1]))
        XCTAssertEqual(try future.decoded(), .other(future))
        let badJSON = Frame(kind: .json, channel: .control, payload: Data("{".utf8))
        XCTAssertThrowsError(try badJSON.decoded())
    }
}

/// A small deterministic generator (SplitMix64) so fuzz failures reproduce.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}
