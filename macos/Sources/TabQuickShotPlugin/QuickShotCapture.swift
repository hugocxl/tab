import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum QuickShotError: LocalizedError {
    case displayUnavailable
    case folderUnavailable
    case writeFailed
    case clipboardUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: return "The display under the pointer couldn't be found."
        case .folderUnavailable: return "The screenshots folder is unavailable."
        case .writeFailed: return "The screenshot couldn't be saved."
        case .clipboardUnavailable(let url): return "Saved \(url.lastPathComponent), but the clipboard is unavailable."
        }
    }
}

/// A finished capture.
struct QuickShot {
    let url: URL
    let image: CGImage
    let screen: NSScreen
}

/// Captures the display under the pointer to a PNG.
enum QuickShotCapture {
    static let filePrefix = "QuickShot-"

    static var temporaryFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("QuickShot", isDirectory: true)
    }

    static func folder(for destination: QuickShotConfig.Destination) throws -> URL {
        let folder: URL
        switch destination {
        case .desktop:
            guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
                throw QuickShotError.folderUnavailable
            }
            folder = desktop
        case .temporary:
            folder = temporaryFolder
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @MainActor
    static func captureDisplayUnderPointer(to destination: QuickShotConfig.Destination) async throws -> QuickShot {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { throw QuickShotError.displayUnavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
            throw QuickShotError.displayUnavailable
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let folder = try folder(for: destination)
        let url = folder.appendingPathComponent("\(filePrefix)\(timestamp()).png")
        // Encoding a full-resolution PNG takes long enough to stall a frame.
        try await Task.detached(priority: .userInitiated) { try writePNG(image, to: url) }.value
        return QuickShot(url: url, image: image, screen: screen)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw QuickShotError.writeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw QuickShotError.writeFailed
        }
    }

    /// Puts the capture on the clipboard as its path or as the image.
    @MainActor
    static func copy(_ shot: QuickShot, as clipboard: QuickShotConfig.Clipboard) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let written: Bool
        switch clipboard {
        case .path:
            written = pasteboard.setString(shot.url.path, forType: .string)
        case .image:
            let image = NSImage(cgImage: shot.image, size: .zero)
            written = pasteboard.writeObjects([image, shot.url as NSURL])
        }
        guard written else { throw QuickShotError.clipboardUnavailable(shot.url) }
    }

    /// Deletes this plugin's PNGs older than a day from the temporary folder,
    /// never anything else in it.
    static func removeExpiredCaptures(in folder: URL = temporaryFolder, now: Date = Date()) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.path) else { return }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        for file in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
        where file.lastPathComponent.hasPrefix(filePrefix) && file.pathExtension == "png" {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified <= cutoff
            else { continue }
            try manager.removeItem(at: file)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss.SSS"
        return formatter.string(from: Date())
    }
}
