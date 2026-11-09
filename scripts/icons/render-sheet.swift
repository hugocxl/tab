#!/usr/bin/env swift
import AppKit

// Usage: swift scripts/icons/render-sheet.swift FOLDER OUT.png
//        [--size 16] [--scale 4] [--columns 10] [--compare OTHER_FOLDER]
// Each group shows light/dark tiles; comparison adds a second pair in the same order.
struct Options {
    let folder: URL
    let output: URL
    var size: CGFloat = 16
    var scale: Int = 4
    var columns: Int = 10
    var compare: URL?
}

enum SheetError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

func options() throws -> Options {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else {
        throw SheetError.message("Usage: swift scripts/icons/render-sheet.swift <svg-folder> <out.png> [--size 16] [--scale 4] [--columns 10] [--compare <folder>]")
    }
    var result = Options(folder: URL(fileURLWithPath: args[0]), output: URL(fileURLWithPath: args[1]))
    var index = 2
    while index < args.count {
        guard index + 1 < args.count else { throw SheetError.message("Missing value for \(args[index])") }
        let value = args[index + 1]
        switch args[index] {
        case "--size":
            guard let size = Double(value), size.isFinite, size > 0, size <= 512 else {
                throw SheetError.message("--size must be in (0, 512]")
            }
            result.size = CGFloat(size)
        case "--scale":
            guard let scale = Int(value), (1...16).contains(scale) else {
                throw SheetError.message("--scale must be an integer in 1...16")
            }
            result.scale = scale
        case "--columns":
            guard let columns = Int(value), (1...100).contains(columns) else {
                throw SheetError.message("--columns must be an integer in 1...100")
            }
            result.columns = columns
        case "--compare": result.compare = URL(fileURLWithPath: value)
        default: throw SheetError.message("Unknown option: \(args[index])")
        }
        index += 2
    }
    return result
}

func render(_ config: Options) throws {
    let files = try FileManager.default.contentsOfDirectory(at: config.folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "svg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty else { throw SheetError.message("No SVGs in \(config.folder.path)") }
    let tile = ceil(max(40, config.size + 24))
    let pairWidth = tile * 2
    let groupWidth = max(140, pairWidth * (config.compare == nil ? 1 : 2)) + 8
    let groupHeight = tile + (config.compare == nil ? 30 : 44)
    let columns = min(config.columns, files.count)
    let rows = (files.count + columns - 1) / columns
    let width = Int(ceil(CGFloat(columns) * groupWidth))
    let height = Int(ceil(CGFloat(rows) * groupHeight))
    let pixelsWide = width * config.scale
    let pixelsHigh = height * config.scale
    guard Double(pixelsWide) * Double(pixelsHigh) <= 120_000_000 else {
        throw SheetError.message("Sheet exceeds 120 million pixels; reduce size, scale, or columns")
    }
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw SheetError.message("Cannot allocate bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(config.scale), y: CGFloat(config.scale))
    context.imageInterpolation = .high
    NSColor(white: 0.84, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byTruncatingMiddle
    let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black, .paragraphStyle: paragraph
    ]
    func label(_ text: String, _ rect: NSRect) {
        (text as NSString).draw(in: rect, withAttributes: labelAttributes)
    }
    for (index, file) in files.enumerated() {
        let x = CGFloat(index % columns) * groupWidth
        let y = CGFloat(height) - CGFloat(index / columns + 1) * groupHeight
        let pairCount = config.compare == nil ? 1 : 2
        let startX = x + (groupWidth - pairWidth * CGFloat(pairCount)) / 2
        var sources = [file]
        if let compare = config.compare { sources.append(compare.appendingPathComponent(file.lastPathComponent)) }
        for (sourceIndex, source) in sources.enumerated() {
            guard let image = NSImage(contentsOf: source), image.isValid, image.size.width > 0, image.size.height > 0 else {
                throw SheetError.message("Cannot load SVG with NSImage: \(source.path)")
            }
            image.isTemplate = true
            // Match the app's NSImage.tinted(_:): draw the template, then sourceAtop.
            // Fit in a size x size slot without distorting non-square viewBoxes.
            let ratio = min(config.size / image.size.width, config.size / image.size.height)
            let glyphSize = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
            for dark in 0...1 {
                let tileRect = NSRect(x: startX + CGFloat(sourceIndex) * pairWidth + CGFloat(dark) * tile,
                    y: y + groupHeight - tile, width: tile, height: tile)
                NSColor(white: dark == 0 ? 0.97 : 0.10, alpha: 1).setFill()
                tileRect.fill()
                let tint = NSColor(white: dark == 0 ? 0.10 : 0.97, alpha: 1)
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    tint.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                let rect = NSRect(x: tileRect.midX - glyphSize.width / 2, y: tileRect.midY - glyphSize.height / 2,
                    width: glyphSize.width, height: glyphSize.height)
                tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            if config.compare != nil {
                label(sourceIndex == 0 ? "input" : "compare", NSRect(x: startX + CGFloat(sourceIndex) * pairWidth,
                    y: y + 20, width: pairWidth, height: 14))
            }
        }
        label(file.lastPathComponent, NSRect(x: x + 2, y: y + 3, width: groupWidth - 4, height: 16))
    }
    context.flushGraphics()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw SheetError.message("PNG encoding failed")
    }
    try png.write(to: config.output, options: .atomic)
    print("\(config.output.path): \(pixelsWide) × \(pixelsHigh) pixels, \(png.count) bytes, \(files.count) icons")
}

do {
    try render(options())
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
