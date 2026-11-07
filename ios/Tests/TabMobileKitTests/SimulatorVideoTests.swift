import CoreMedia
import CoreVideo
import TabProtocol
import VideoToolbox
import XCTest
@testable import TabMobileKit

/// Frames in the stream's format decode to pictures a layer can show.
final class SimulatorVideoTests: XCTestCase {
    func testEncodedFramesDecodeAfterTheirKeyframe() throws {
        let frames = try Self.encode(width: 320, height: 640, count: 3)
        XCTAssertTrue(frames[0].keyframe)
        let decoder = SimulatorVideoDecoder(codec: .h264)

        XCTAssertThrowsError(try decoder.decode(frames[1]), "nothing decodes before a keyframe")
        for frame in frames {
            let picture = try decoder.decode(frame)
            XCTAssertEqual(CVPixelBufferGetWidth(picture), 320)
            XCTAssertEqual(CVPixelBufferGetHeight(picture), 640)
            XCTAssertNotNil(CVPixelBufferGetIOSurface(picture), "a layer shows the surface without copying")
        }
    }

    func testAKeyframeRoundTripsThroughTheProtocol() throws {
        let frame = try XCTUnwrap(Self.encode(width: 64, height: 128, count: 1).first)
        let decoded = try VideoFrame.decode(frame.encoded())
        XCTAssertEqual(decoded, frame)
        XCTAssertNoThrow(try SimulatorVideoDecoder(codec: .h264).decode(decoded))
    }

    /// Encodes `count` frames of a flat picture as a server would send them.
    static func encode(width: Int, height: Int, count: Int) throws -> [VideoFrame] {
        var session: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw XCTSkip("no H.264 encoder here (\(status))") }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        var frames: [VideoFrame] = []
        for index in 0..<count {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let picture = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(picture, [])
            memset(CVPixelBufferGetBaseAddress(picture), Int32(40 * index), CVPixelBufferGetDataSize(picture))
            CVPixelBufferUnlockBaseAddress(picture, [])
            let properties = index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            var output: CMSampleBuffer?
            status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: picture, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { _, _, sample in output = sample }
            XCTAssertEqual(status, noErr)
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            let sample = try XCTUnwrap(output)
            frames.append(try frame(sample, seq: UInt32(index), width: width, height: height))
        }
        return frames
    }

    private static func frame(_ sample: CMSampleBuffer, seq: UInt32, width: Int, height: Int) throws -> VideoFrame {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var sets: [Data] = []
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                if let pointer { sets.append(Data(bytes: pointer, count: size)) }
            }
        }
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var data = Data(count: CMBlockBufferGetDataLength(block))
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
        }
        return VideoFrame(seq: seq, keyframe: keyframe, width: UInt16(width), height: UInt16(height),
                          parameterSets: sets, sample: data)
    }
}
