// Renders packaging/AppIcon.icns from packaging/AppIcon.svg (128pt and up) and
// packaging/AppIconSmall.svg (64pt and down). Usage: swift scripts/build-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let packaging = root.appendingPathComponent("packaging")
let big = NSImage(contentsOf: packaging.appendingPathComponent("AppIcon.svg"))!
let small = NSImage(contentsOf: packaging.appendingPathComponent("AppIconSmall.svg"))!
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
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
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", packaging.appendingPathComponent("AppIcon.icns").path, set.path]
try! iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
