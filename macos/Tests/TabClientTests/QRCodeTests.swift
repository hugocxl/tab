import CoreImage
import XCTest
@testable import TabClient

final class QRCodeTests: XCTestCase {
    /// Draws the code as an image, one 8-pixel square per module, quiet zone included.
    private func image(_ code: QRCode) -> CGImage? {
        let scale = 8
        let span = code.size + 2 * QRCode.quietZone
        let side = span * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for y in 0 ..< span {
            for x in 0 ..< span where code.isDark(x: x - QRCode.quietZone, y: y - QRCode.quietZone) {
                for py in 0 ..< scale {
                    for px in 0 ..< scale { pixels[(y * scale + py) * side + x * scale + px] = 0 }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func decode(_ code: QRCode) -> String? {
        guard let image = image(code),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        let features = detector.features(in: CIImage(cgImage: image))
        return (features.first as? CIQRCodeFeature)?.messageString
    }

    /// The modules Core Image's own generator draws for `text` at level M.
    private func reference(_ text: String) -> (size: Int, dark: (Int, Int) -> Bool)? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let side = image.width
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: 0) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        // Core Image adds a one-module margin.
        let size = side - 2
        let copy = pixels
        return (size, { x, y in copy[(y + 1) * side + x + 1] < 128 })
    }

    func testCodesDecodeToTheirTextAcrossVersions() throws {
        let fingerprint = String(repeating: "ab", count: 32)
        let samples = [
            "HELLO WORLD",
            "tab://pair?v=1&h=192.168.1.20&p=7419&f=\(fingerprint)&s=\(String(repeating: "0f", count: 16))",
            "tab://pair?v=1&h=studio.local&h=10.0.0.4&h=example.com&p=7419&f=\(fingerprint)&s=\(String(repeating: "c3", count: 16))",
            String(repeating: "x", count: 213),
        ]
        var versions = Set<Int>()
        for text in samples {
            let code = try XCTUnwrap(QRCode(text))
            versions.insert(code.version)
            XCTAssertEqual(code.size, code.version * 4 + 17)
            XCTAssertEqual(decode(code), text, "version \(code.version)")
        }
        XCTAssertTrue(versions.contains(10))
        XCTAssertGreaterThan(versions.count, 2)
        XCTAssertNil(QRCode(String(repeating: "x", count: 214)))
    }

    /// Core Image's generator draws the same modules for byte-mode text
    /// (lowercase forces byte mode) once given the mask it chose.
    func testMatchesCoreImageModuleForModule() throws {
        for text in ["hello, world", "the quick brown fox jumps over the lazy dog",
                     String(repeating: "abcdefghij", count: 15)] {
            let code = try XCTUnwrap(QRCode(text))
            let reference = try XCTUnwrap(reference(text))
            guard reference.size == code.size else {
                throw XCTSkip("Core Image chose another version for \(text)")
            }
            let matching = (0 ..< 8).filter { mask in
                guard let forced = QRCode(bytes: Array(text.utf8), forcedMask: mask) else { return false }
                for y in 0 ..< code.size {
                    for x in 0 ..< code.size where forced.isDark(x: x, y: y) != reference.dark(x, y) { return false }
                }
                return true
            }
            XCTAssertEqual(matching.count, 1, text)
            XCTAssertEqual(matching.first, Self.mask(reference.size, reference.dark), text)
            XCTAssertEqual(code.mask, matching.first, "penalty scoring picks Core Image's mask for \(text)")
        }
    }

    /// The mask a code uses, from its first copy of the format bits.
    private static func mask(_ size: Int, _ dark: (Int, Int) -> Bool) -> Int {
        var bits = 0
        func put(_ index: Int, _ value: Bool) { if value { bits |= 1 << index } }
        for index in 0 ... 5 { put(index, dark(8, index)) }
        put(6, dark(8, 7))
        put(7, dark(8, 8))
        put(8, dark(7, 8))
        for index in 9 ..< 15 { put(index, dark(14 - index, 8)) }
        return ((bits ^ 0x5412) >> 10) & 7
    }

    func testTerminalTextUsesTwoModuleRowsPerLine() throws {
        let code = try XCTUnwrap(QRCode("HELLO"))
        let lines = code.terminalText.split(separator: "\n")
        let span = code.size + 2 * QRCode.quietZone
        XCTAssertEqual(lines.count, (span + 1) / 2)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("\u{1B}[30;47m") && $0.hasSuffix("\u{1B}[0m") })
    }
}
