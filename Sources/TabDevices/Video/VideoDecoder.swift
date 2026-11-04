import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import TabProtocol
import VideoToolbox

/// Decodes a device's screen stream into IOSurface-backed BGRA buffers a
/// layer shows directly. A keyframe's parameter sets start a new format;
/// frames before the first keyframe, or after a failure until the next one,
/// can't decode and throw. Decode on one serial queue.
public final class VideoDecoder: @unchecked Sendable {
    public let codec: VideoCodec
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var session: VTDecompressionSession?

    public init(codec: VideoCodec) {
        self.codec = codec
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decodes one access unit, waiting for the picture.
    public func decode(_ frame: VideoFrame) throws -> CVPixelBuffer {
        if frame.keyframe, frame.parameterSets != parameterSets || session == nil {
            try start(frame.parameterSets)
        }
        guard let session, let format else { throw VideoError.malformed }
        let sample = try Self.sample(frame.sample, format: format)
        var picture: Result<CVPixelBuffer, Error> = .failure(VideoError.malformed)
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, buffer, _, _ in
            if status == noErr, let buffer {
                picture = .success(buffer)
            } else {
                picture = .failure(VideoError.failed("Decoding", status))
            }
        }
        guard status == noErr else {
            reset()
            throw VideoError.failed("Decoding", status)
        }
        do {
            return try picture.get()
        } catch {
            reset()
            throw error
        }
    }

    /// Forgets the format, so only a keyframe decodes next.
    public func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        parameterSets = []
    }

    private func start(_ sets: [Data]) throws {
        reset()
        guard !sets.isEmpty else { throw VideoError.malformed }
        let format = try Self.format(codec, sets)
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else { throw VideoError.failed("Creating the decoder", status) }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        self.format = format
        parameterSets = sets
    }

    private static func format(_ codec: VideoCodec, _ sets: [Data]) throws -> CMVideoFormatDescription {
        // The pointers must stay valid for the whole call.
        let buffers = sets.map { [UInt8]($0) }
        var format: CMVideoFormatDescription?
        let status: OSStatus = withPointers(buffers) { pointers in
            let sizes = buffers.map(\.count)
            switch codec {
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            default:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { throw VideoError.failed("Reading the stream format", status) }
        return format
    }

    private static func withPointers<T>(_ buffers: [[UInt8]], _ body: ([UnsafePointer<UInt8>]) -> T) -> T {
        var pointers: [UnsafePointer<UInt8>] = []
        func step(_ index: Int) -> T {
            guard index < buffers.count else { return body(pointers) }
            return buffers[index].withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return step(index + 1) }
                pointers.append(base)
                return step(index + 1)
            }
        }
        return step(0)
    }

    private static func sample(_ data: Data, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        guard !data.isEmpty else { throw VideoError.malformed }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { throw VideoError.failed("Allocating the frame", status) }
        status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: raw.count)
        }
        guard status == kCMBlockBufferNoErr else { throw VideoError.failed("Copying the frame", status) }
        var sample: CMSampleBuffer?
        var size = data.count
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw VideoError.failed("Wrapping the frame", status) }
        return sample
    }
}
