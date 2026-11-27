import CoreMedia
import Foundation
import TabProtocol

/// Wraps a simulator stream's frames as sample buffers for decoding. A
/// keyframe's parameter sets start a format; frames before the first
/// keyframe have none and are skipped.
public final class VideoSamples {
    public let codec: VideoCodec
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []

    public init(codec: VideoCodec) {
        self.codec = codec
    }

    /// The sample for `frame`, or nil when it can't be shown until the next keyframe.
    public func sample(for frame: VideoFrame) -> CMSampleBuffer? {
        if frame.keyframe, frame.parameterSets != parameterSets || format == nil {
            format = Self.format(codec, frame.parameterSets)
            parameterSets = format == nil ? [] : frame.parameterSets
        }
        guard let format, !frame.sample.isEmpty else { return nil }
        return Self.sample(frame.sample, format: format)
    }

    /// Forgets the format, so only a keyframe shows next.
    public func reset() {
        format = nil
        parameterSets = []
    }

    static func format(_ codec: VideoCodec, _ sets: [Data]) -> CMVideoFormatDescription? {
        guard !sets.isEmpty, sets.allSatisfy({ !$0.isEmpty }) else { return nil }
        let buffers = sets.map { [UInt8]($0) }
        let sizes = buffers.map(\.count)
        var format: CMVideoFormatDescription?
        let status = withPointers(buffers) { pointers -> OSStatus in
            switch codec {
            case .hevc:
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            default:
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    /// Calls `body` with a pointer to each buffer, all valid for the call.
    private static func withPointers<T>(_ buffers: [[UInt8]], _ body: ([UnsafePointer<UInt8>]) -> T) -> T {
        func step(_ index: Int, _ pointers: [UnsafePointer<UInt8>]) -> T {
            guard index < buffers.count else { return body(pointers) }
            return buffers[index].withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return step(index + 1, pointers) }
                return step(index + 1, pointers + [base])
            }
        }
        return step(0, [])
    }

    private static func sample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { return nil }
        status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: raw.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }
}
