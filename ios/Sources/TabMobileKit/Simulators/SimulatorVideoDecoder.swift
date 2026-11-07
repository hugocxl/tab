import CoreMedia
import CoreVideo
import Foundation
import TabProtocol
import VideoToolbox

/// Decodes a simulator's screen stream in hardware into IOSurface-backed
/// pictures a layer shows as they are. Frames before the first keyframe, or
/// after a failure until the next one, can't decode. Use from one serial queue.
public final class SimulatorVideoDecoder: @unchecked Sendable {
    public enum Failure: Error {
        /// Waiting for a keyframe.
        case needsKeyframe
        case decoding(OSStatus)
    }

    public let codec: VideoCodec
    private let samples: VideoSamples
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?

    public init(codec: VideoCodec) {
        self.codec = codec
        samples = VideoSamples(codec: codec)
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decodes one frame, waiting for its picture.
    public func decode(_ frame: VideoFrame) throws -> CVPixelBuffer {
        guard let sample = samples.sample(for: frame), let format = CMSampleBufferGetFormatDescription(sample) else {
            throw Failure.needsKeyframe
        }
        if session == nil || self.format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) }) ?? true {
            try start(format)
        }
        guard let session else { throw Failure.needsKeyframe }
        var picture: CVPixelBuffer?
        var result: OSStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, buffer, _, _ in
            result = status
            picture = buffer
        }
        guard status == noErr, result == noErr, let picture else {
            reset()
            throw Failure.decoding(status != noErr ? status : result)
        }
        return picture
    }

    /// Forgets the stream's format, so only a keyframe decodes next.
    public func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        samples.reset()
    }

    private func start(_ format: CMVideoFormatDescription) throws {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else {
            samples.reset()
            throw Failure.decoding(status)
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        self.format = format
    }
}
