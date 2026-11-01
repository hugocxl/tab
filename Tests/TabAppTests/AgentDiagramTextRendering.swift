import AppKit
import XCTest
@testable import TabApp

/// Renders native diagram layouts into a bitmap for smoke tests.
enum AgentDiagramTextRendering {
    /// Draws `layout` into a flipped RGBA bitmap and returns the number of painted pixels.
    static func paintedPixels(_ layout: AgentDiagramLayout) throws -> Int {
        let width = Int(ceil(layout.size.width))
        let height = Int(ceil(layout.size.height))
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        layout.draw(context)
        let data = try XCTUnwrap(context.data)
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var painted = 0
        for pixel in 0..<(width * height) where bytes[pixel * 4 + 3] > 0 {
            painted += 1
        }
        return painted
    }
}
