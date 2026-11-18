import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An image too large to attach as it is, which the user may choose to attach as a
/// smaller copy. A file is read again only after the user agrees.
enum AgentOversizedImage: Sendable {
    case file(URL, name: String, bytes: Int)
    case data(Data, name: String)

    var name: String {
        switch self {
        case .file(_, let name, _), .data(_, let name): return name
        }
    }

    var byteCount: Int {
        switch self {
        case .file(_, _, let bytes): return bytes
        case .data(let data, _): return data.count
        }
    }
}

enum AgentImageOptimizationError: LocalizedError, Equatable {
    case sourceTooLarge(String), dimensionsTooLarge(String, width: Int, height: Int), undecodable(String), cannotFit(String)

    var errorDescription: String? {
        switch self {
        case .sourceTooLarge(let name):
            return "\(name) is larger than \(AgentImageOptimizer.maximumSourceBytes / 1024 / 1024) MB, too large to optimize. Export a smaller copy and attach that."
        case .dimensionsTooLarge(let name, let width, let height):
            return "\(name) is \(width) × \(height) pixels, too large to optimize safely. Export a smaller copy and attach that."
        case .undecodable(let name):
            return "\(name) could not be read as an image, so it can't be optimized. Try exporting it as PNG or JPEG."
        case .cannotFit(let name):
            return "Even an optimized copy of \(name) exceeds the attachment limit. Crop it or export a smaller copy."
        }
    }
}

/// Makes a smaller copy of an image that exceeds the transport budget, with ImageIO and
/// bounded work: the source bytes and decoded size are checked before anything decodes,
/// and each step can be cancelled. Images within the budget never come here.
enum AgentImageOptimizer {
    static let maximumSourceBytes = 64 * 1024 * 1024
    static let maximumSourcePixels = 50_000_000
    static let maximumSourceDimension = 20_000
    static let largestOutputDimension = 4096
    static let smallestOutputDimension = 384

    /// Whether `data` looks like an image ImageIO can size without decoding it.
    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return dimensions(source) != nil
    }

    /// Reads an oversized file within `maximumSourceBytes`, then optimizes it.
    static func optimize(_ image: AgentOversizedImage, budget: Int) throws -> AgentDraftAttachment {
        switch image {
        case .data(let data, let name): return try optimize(data: data, name: name, budget: budget)
        case .file(let url, let name, _):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: min(1024 * 1024, maximumSourceBytes - data.count + 1)) ?? Data()
                if chunk.isEmpty { break }
                guard data.count + chunk.count <= maximumSourceBytes else { throw AgentImageOptimizationError.sourceTooLarge(name) }
                data.append(chunk)
            }
            return try optimize(data: data, name: name, budget: budget)
        }
    }

    /// A copy of `data` no larger than `budget` bytes: resized and re-encoded as JPEG,
    /// or PNG when it has transparency. Invoke off the main thread.
    static func optimize(data: Data, name: String, budget: Int) throws -> AgentDraftAttachment {
        guard data.count <= maximumSourceBytes else { throw AgentImageOptimizationError.sourceTooLarge(name) }
        guard budget > 0 else { throw AgentImageOptimizationError.cannotFit(name) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let (width, height, alpha) = dimensions(source) else { throw AgentImageOptimizationError.undecodable(name) }
        guard width <= maximumSourceDimension, height <= maximumSourceDimension, width * height <= maximumSourcePixels else {
            throw AgentImageOptimizationError.dimensionsTooLarge(name, width: width, height: height)
        }
        let type: UTType = alpha ? .png : .jpeg
        let base = (name as NSString).deletingPathExtension
        var edge = min(max(width, height), largestOutputDimension)
        while edge >= smallestOutputDimension {
            try Task.checkCancellation()
            guard let image = thumbnail(source, pixels: edge) else { throw AgentImageOptimizationError.undecodable(name) }
            for quality in alpha ? [1.0] : [0.85, 0.7] {
                try Task.checkCancellation()
                let bytes = try encode(image, type: type, quality: quality, name: name)
                guard bytes.count <= budget else { continue }
                let preview = thumbnail(source, pixels: 128).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                return AgentDraftAttachment(name: base + " (optimized)." + (type.preferredFilenameExtension ?? "img"),
                                            mimeType: type.preferredMIMEType ?? "image/png", data: bytes, thumbnail: preview)
            }
            edge = Int(Double(edge) * 0.75)
        }
        throw AgentImageOptimizationError.cannotFit(name)
    }

    private static func dimensions(_ source: CGImageSource) -> (Int, Int, Bool)? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height, (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false)
    }

    private static func thumbnail(_ source: CGImageSource, pixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double, name: String) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw AgentImageOptimizationError.undecodable(name)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AgentImageOptimizationError.undecodable(name) }
        return output as Data
    }
}
