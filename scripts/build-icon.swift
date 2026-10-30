// Renders packaging/AppIcon.icns from packaging/AppIcon.svg (128pt and up) and
// packaging/AppIconSmall.svg (64pt and down). Usage: swift scripts/build-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let packaging = root.appendingPathComponent("packaging")
let big = NSImage(contentsOf: packaging.appendingPathComponent("AppIcon.svg"))!
let small = NSImage(contentsOf: packaging.appendingPathComponent("AppIconSmall.svg"))!
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("tab-icon-\(UUID().uuidString)")
let set = temporary.appendingPathComponent("AppIcon.iconset")
defer { try? FileManager.default.removeItem(at: temporary) }
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func render(_ image: NSImage, _ px: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let sizes = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
             ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes {
    render(px <= 64 ? small : big, px, to: set.appendingPathComponent("icon_\(name).png"))
}
render(big, 1024, to: packaging.appendingPathComponent("AppIcon.png"))
// ICNS accepts PNG representations directly. Writing the container here also
// works where iconutil's image encoder service is unavailable in a sandbox.
func chunk(_ type: String, _ payload: Data) -> Data {
    var data = Data(type.utf8)
    var length = UInt32(payload.count + 8).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
}
let types = ["icp4", "ic11", "icp5", "ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10"]
var representations = Data()
for ((name, _), type) in zip(sizes, types) {
    representations.append(chunk(type, try Data(contentsOf: set.appendingPathComponent("icon_\(name).png"))))
}
try chunk("icns", representations).write(to: packaging.appendingPathComponent("AppIcon.icns"), options: .atomic)
