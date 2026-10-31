import AppKit
import Foundation

/// Native-generated 2s, 32×32 H.264 MP4, with no audio track.
enum AgentConversationMediaFixtures {
    static let mp4 = Data(base64Encoded: "AAAAHGZ0eXBtcDQyAAAAAWlzb21tcDQxbXA0MgAAAAFtZGF0AAAAAAAAAM0AAAA2BgUtR1ZK3FxMQz+U78URPNFDqAEAAAMAAQMAAAMAAQIAAeYACwAAAwAAAwAAAwBuDAORKwGAAAAAMiW4IB/eCOVM/4hP6oA/IAIhTGhgPXhDqx2sM91W7ZcyCRty/QmT7t/x8OgAzwAc4nZsAAAAGCHhDF/ElOkC3Wrd0xkGOAAEg9mZFC6n0AAAABYhqIKEv+tSwBZQdhWhqABONiD+u1bQAAAAEwGowY//7JJGJ7poACjuwzixcoAAAAMCbW9vdgAAAGxtdmhkAAAAAOcL1ULnC9VCAAACWAAABLAAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAo50cmFrAAAAXHRraGQAAAAB5wvVQucL1UIAAAABAAAAAAAABLAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAACAAAAAgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAASwAAACWAABAAAAAAIGbWRpYQAAACBtZGhkAAAAAOcL1ULnC9VCAAACWAAABLBVxAAAAAAAMWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABDb3JlIE1lZGlhIFZpZGVvAAAAAa1taW5mAAAAFHZtaGQAAAABAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAFtc3RibAAAAKFzdHNkAAAAAAAAAAEAAACRYXZjMQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAgACAASAAAAEgAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABj//wAAACdhdmNDAWQAC//hAAwnZAALrFZQw3gUYIUBAAQo7jyw/fj4AAAAAApmaWVsAQAAAAAKY2hybQAAAAAAGHN0dHMAAAAAAAAAAQAAAAQAAAEsAAAAMGN0dHMAAAAAAAAABAAAAAEAAAJYAAAAAQAABLAAAAABAAACWAAAAAEAAAAAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAAQc2R0cAAAAAAgEBAYAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAACAAAAAQAAACRzdHN6AAAAAAAAAAAAAAAEAAAAcAAAABwAAAAaAAAAFwAAABhzdGNvAAAAAAAAAAIAAAAsAAAAuA==")!

    /// Two seconds of silent mono PCM, enough to test metadata and seeking without playback.
    static var wav: Data {
        let count: UInt32 = 16_000 * 2 * 2
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        append(count + 36); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(16_000)); append(UInt32(32_000))
        append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(count)
        data.append(Data(count: Int(count)))
        return data
    }

    @MainActor static func largePNG() throws -> Data {
        let width = 2_304, height = 1_600
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: width * 4, bitsPerPixel: 32), let bytes = bitmap.bitmapData else {
            throw NSError(domain: "MediaFixtures", code: 1)
        }
        var random: UInt32 = 0x12345678
        for index in 0 ..< width * height {
            random ^= random << 13; random ^= random >> 17; random ^= random << 5
            bytes[index * 4] = UInt8(truncatingIfNeeded: random)
            bytes[index * 4 + 1] = UInt8(truncatingIfNeeded: random >> 8)
            bytes[index * 4 + 2] = UInt8(truncatingIfNeeded: random >> 16)
            bytes[index * 4 + 3] = 255
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "MediaFixtures", code: 2) }
        return png
    }
}
