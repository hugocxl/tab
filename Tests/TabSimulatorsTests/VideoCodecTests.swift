import CoreVideo
import IOSurface
import TabProtocol
import XCTest
@testable import TabSimulators

/// The screen codec: what the server encodes, the app decodes into a
/// surface it can show, at the size the pane asked for.
final class VideoCodecTests: XCTestCase {
    private func surface(width: Int, height: Int, color: (UInt8, UInt8, UInt8)) throws -> IOSurface {
        let surface = try XCTUnwrap(IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: 0x4247_5241,
        ]))
        surface.lock(options: [], seed: nil)
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width {
                let pixel = bytes + row * surface.bytesPerRow + column * 4
                // A bar down the middle so frames differ from flat color.
                let bar = abs(column - width / 2) < width / 10
                pixel[0] = bar ? 255 : color.2
                pixel[1] = bar ? 255 : color.1
                pixel[2] = bar ? 255 : color.0
                pixel[3] = 255
            }
        }
        surface.unlock(options: [], seed: nil)
        return surface
    }

    private func frame(_ encoded: EncodedFrame, seq: UInt32, encoder: VideoEncoder) -> VideoFrame {
        VideoFrame(seq: seq, keyframe: encoded.keyframe, width: UInt16(encoder.width), height: UInt16(encoder.height),
                   parameterSets: encoded.parameterSets, sample: encoded.sample)
    }

    func testFramesEncodeAndDecodeIntoShowableSurfacesAtTheAskedSize() throws {
        let size = VideoEncoder.size(width: 1179, height: 2556, maxPixels: 600_000)
        XCTAssertLessThanOrEqual(size.width * size.height, 600_000)
        XCTAssertEqual(size.width % 2, 0)
        XCTAssertEqual(size.height % 2, 0)
        XCTAssertEqual(Double(size.width) / Double(size.height), 1179.0 / 2556.0, accuracy: 0.01)
        XCTAssertEqual(VideoEncoder.size(width: 640, height: 480, maxPixels: 4_000_000).width, 640, "never scaled up")

        let encoder = try VideoEncoder(codec: .h264, width: size.width, height: size.height)
        let decoder = VideoDecoder(codec: .h264)
        let first = try XCTUnwrap(try encoder.encode(surface(width: 1179, height: 2556, color: (200, 30, 30)), keyframe: true))
        XCTAssertTrue(first.keyframe)
        XCTAssertFalse(first.parameterSets.isEmpty, "a keyframe carries what the decoder needs to start")
        let picture = try decoder.decode(frame(first, seq: 1, encoder: encoder))
        XCTAssertEqual(CVPixelBufferGetWidth(picture), size.width)
        XCTAssertEqual(CVPixelBufferGetHeight(picture), size.height)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(picture), "the screen view shows decoded frames as surfaces")

        let second = try XCTUnwrap(try encoder.encode(surface(width: 1179, height: 2556, color: (30, 200, 30)), keyframe: false))
        XCTAssertFalse(second.keyframe)
        XCTAssertNoThrow(try decoder.decode(frame(second, seq: 2, encoder: encoder)))

        let fresh = VideoDecoder(codec: .h264)
        XCTAssertThrowsError(try fresh.decode(frame(second, seq: 2, encoder: encoder)), "a P-frame can't start a stream")
        let requested = try XCTUnwrap(try encoder.encode(surface(width: 1179, height: 2556, color: (30, 30, 200)), keyframe: true))
        XCTAssertTrue(requested.keyframe, "a requested keyframe comes as one")
        XCTAssertNoThrow(try fresh.decode(frame(requested, seq: 3, encoder: encoder)))
    }

    func testBitrateFallsQuicklyWhenRoundTripsGrowAndRecoversSlowly() {
        var control = BitrateControl(bitrate: 4_000_000)
        for _ in 0..<5 { _ = control.acknowledged(after: 0.01) }
        let steady = control.bitrate
        let slowed = control.acknowledged(after: 0.3)
        XCTAssertLessThan(slowed, steady)
        let recovered = control.acknowledged(after: 0.01)
        XCTAssertGreaterThan(recovered, slowed)
        XCTAssertLessThan(recovered - slowed, steady - slowed, "recovery is slower than the fall")
        for _ in 0..<200 { _ = control.acknowledged(after: 2) }
        XCTAssertEqual(control.bitrate, VideoEncoder.minBitrate)
    }
}
