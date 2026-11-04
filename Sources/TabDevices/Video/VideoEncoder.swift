import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import TabProtocol
import VideoToolbox

/// Why a device's screen can't be encoded or decoded.
public enum VideoError: Error, Equatable, CustomStringConvertible {
    case unsupported(VideoCodec)
    case failed(String, OSStatus)
    case malformed

    public var description: String {
        switch self {
        case .unsupported(let codec): "This Mac can't encode \(codec.rawValue) video"
        case .failed(let step, let status): "\(step) failed (\(status))"
        case .malformed: "The video frame is malformed"
        }
    }
}

/// One encoded access unit, before it gets a frame number.
public struct EncodedFrame: Sendable {
    public var keyframe: Bool
    /// SPS and PPS (and VPS for HEVC), on keyframes.
    public var parameterSets: [Data]
    /// NAL units, each after a 4-byte big-endian length.
    public var sample: Data
}

/// A real-time, low-latency encoder for a device's screen: no B-frames and
/// no reordering, so every frame goes out as soon as it is encoded. It scales
/// the device's surface down to at most `maxPixels`, since a pane never
/// shows more. Encode on one serial queue.
public final class VideoEncoder: @unchecked Sendable {
    public let codec: VideoCodec
    public let width: Int
    public let height: Int
    public private(set) var bitrate: Int

    private let session: VTCompressionSession
    private let transfer: VTPixelTransferSession
    private var frameIndex: Int64 = 0

    /// The bitrate a stream starts at, in bits per second.
    public static let startBitrate = 4_000_000
    public static let minBitrate = 500_000
    public static let maxBitrate = 12_000_000

    /// The encoded size for a source of `width` by `height` within
    /// `maxPixels`: scaled down keeping its shape, in even numbers.
    public static func size(width: Int, height: Int, maxPixels: Int) -> (width: Int, height: Int) {
        let pixels = Double(width * height)
        let scale = pixels > Double(maxPixels) ? (Double(maxPixels) / pixels).squareRoot() : 1
        func even(_ value: Double) -> Int { max(2, Int(value) & ~1) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    public init(codec: VideoCodec, width: Int, height: Int, bitrate: Int = VideoEncoder.startBitrate) throws {
        let type: CMVideoCodecType
        switch codec {
        case .h264: type = kCMVideoCodecType_H264
        case .hevc: type = kCMVideoCodecType_HEVC
        case .unknown: throw VideoError.unsupported(codec)
        }
        var specification: [CFString: Any] = [:]
        if codec == .h264 { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else { throw VideoError.failed("Creating the encoder", status) }
        var transfer: VTPixelTransferSession?
        status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        guard status == noErr, let transfer else {
            VTCompressionSessionInvalidate(session)
            throw VideoError.failed("Creating the scaler", status)
        }
        self.codec = codec
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.session = session
        self.transfer = transfer
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            // Keyframes come on request; a long interval still heals a lost one.
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 600,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            kVTCompressionPropertyKey_ProfileLevel: codec == .h264
                ? kVTProfileLevel_H264_Main_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
        VTPixelTransferSessionInvalidate(transfer)
    }

    /// Changes the average bitrate, clamped to the supported range.
    public func setBitrate(_ value: Int) {
        let clamped = min(max(value, Self.minBitrate), Self.maxBitrate)
        guard clamped != bitrate else { return }
        bitrate = clamped
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: clamped as CFNumber)
    }

    /// Encodes what `surface` shows now, waiting for the result.
    public func encode(_ surface: IOSurface, keyframe: Bool) throws -> EncodedFrame? {
        var source: Unmanaged<CVPixelBuffer>?
        var status = CVPixelBufferCreateWithIOSurface(nil, unsafeBitCast(surface, to: IOSurfaceRef.self), nil, &source)
        guard status == kCVReturnSuccess, let source = source?.takeRetainedValue() else {
            throw VideoError.failed("Reading the screen", status)
        }
        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else {
            throw VideoError.failed("Getting the encoder's buffers", -1)
        }
        var scaled: CVPixelBuffer?
        status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &scaled)
        guard status == kCVReturnSuccess, let scaled else { throw VideoError.failed("Allocating a frame", status) }
        surface.lock(options: .readOnly, seed: nil)
        status = VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled)
        surface.unlock(options: .readOnly, seed: nil)
        guard status == noErr else { throw VideoError.failed("Scaling the screen", status) }
        return try encode(scaled, keyframe: keyframe)
    }

    /// Encodes `buffer` at the encoder's size, waiting for the result.
    public func encode(_ buffer: CVPixelBuffer, keyframe: Bool) throws -> EncodedFrame? {
        let time = CMTime(value: frameIndex, timescale: 60)
        frameIndex += 1
        let options: CFDictionary? = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        var output: Result<EncodedFrame?, Error> = .success(nil)
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid,
            frameProperties: options, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr else {
                output = .failure(VideoError.failed("Encoding", status))
                return
            }
            guard let sample else { return }
            output = Result { try Self.frame(from: sample) }
        }
        guard status == noErr else { throw VideoError.failed("Encoding", status) }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return try output.get()
    }

    private static func frame(from sample: CMSampleBuffer) throws -> EncodedFrame {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        var sets: [Data] = []
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            sets = parameterSets(format)
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw VideoError.malformed }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                                 dataPointerOut: &pointer)
        let data: Data
        if status == kCMBlockBufferNoErr, let pointer, CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: length) {
            data = Data(bytes: pointer, count: length)
        } else {
            var copy = Data(count: CMBlockBufferGetDataLength(block))
            let copied = copy.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
            }
            guard copied == kCMBlockBufferNoErr else { throw VideoError.failed("Reading the encoded frame", copied) }
            data = copy
        }
        return EncodedFrame(keyframe: keyframe, parameterSets: sets, sample: data)
    }

    private static func parameterSets(_ format: CMFormatDescription) -> [Data] {
        let hevc = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC
        var count = 0
        var status = hevc
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: nil)
        guard status == noErr else { return [] }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            status = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return [] }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
    }
}

/// Adjusts a stream's bitrate to how long frames take to be acknowledged:
/// down quickly when round trips grow past the stream's fastest, up slowly
/// while they stay near it. Each stream starts its own, so a new route is
/// learned on the next attach.
public struct BitrateControl: Sendable {
    public private(set) var bitrate: Int
    private var fastest: TimeInterval?

    public init(bitrate: Int = VideoEncoder.startBitrate) {
        self.bitrate = bitrate
    }

    /// A frame's round trip took `seconds`; returns the bitrate to use.
    public mutating func acknowledged(after seconds: TimeInterval) -> Int {
        let base = min(fastest ?? seconds, seconds)
        fastest = base
        if seconds > base * 2 + 0.03 {
            bitrate = max(VideoEncoder.minBitrate, Int(Double(bitrate) * 0.8))
        } else if seconds < base * 1.25 + 0.01 {
            bitrate = min(VideoEncoder.maxBitrate, bitrate + 100_000)
        }
        return bitrate
    }
}
