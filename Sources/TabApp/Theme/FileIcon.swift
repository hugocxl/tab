import AppKit
import UniformTypeIdentifiers

/// Static bundled file icon data, resolved natively in the same rule order as the source.
@MainActor
enum FileIcon {
    private struct Catalog: Decodable {
        var fileNames: [String: String]
        var extensions: [String: String]
        var completeExtensions: [String: String]
        var overrideNames: [String: String]
        var overrideExtensions: [String: String]
        var aliases: [String: String]
        var languageNames: [String: String]
        var icons: [String: [String]]
    }

    private static let catalog: Catalog? = {
        guard let url = BundledImage.url("agent-file-icons", extension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }()
    private static var images: [String: NSImage] = [:]

    /// Resolves workspace paths without touching the local filesystem, including remote paths.
    static func image(for path: String, isDirectory: Bool = false, mimeType: String? = nil,
                      theme: AppTheme, size: CGFloat = 14) -> NSImage? {
        if isDirectory { return folderImage(size: size) }
        return image(for: path, mimeType: mimeType, dark: !theme.palette.isLight, size: size)
    }

    /// The Finder's folder icon, as macOS draws folders everywhere else.
    private static func folderImage(size: CGFloat) -> NSImage {
        let key = "folder-\(size)"
        if let image = images[key] { return image }
        let image = NSWorkspace.shared.icon(for: .folder)
        image.size = NSSize(width: size, height: size)
        images[key] = image
        return image
    }

    static func syntheticFileName(language: String) -> String {
        let language = language.lowercased()
        return catalog?.languageNames[language] ?? "file." + (catalog?.aliases[language] ?? language)
    }

    static func name(for path: String, mimeType: String? = nil) -> String {
        resolve(path, mimeType: mimeType).name
    }

    private static func resolve(_ path: String, mimeType: String?) -> (name: String, overridden: Bool) {
        let resolved = resolve(path)
        guard resolved.name == "file-tree-builtin-default", let mimeType else { return resolved }
        let extensions = [
            "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
            "application/pdf": "pdf", "application/zip": "zip", "application/vnd.sqlite3": "sqlite",
            "text/x-python": "py", "text/javascript": "js", "text/x-ruby": "rb", "text/x-shellscript": "sh",
        ]
        guard let ext = extensions[mimeType] else { return resolved }
        return resolve("file." + ext)
    }

    private static func resolve(_ path: String) -> (name: String, overridden: Bool) {
        guard let catalog else { return ("file-tree-builtin-default", false) }
        let name = String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? "").lowercased()
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        let extensions = components.indices.dropFirst().map { components[$0...].joined(separator: ".") }
        if let override = catalog.overrideNames[name] { return (override, true) }
        for ext in extensions { if let override = catalog.overrideExtensions[ext] { return (override, true) } }
        if let token = catalog.fileNames[name] { return ("file-tree-builtin-" + token, false) }
        for ext in extensions {
            if let token = catalog.completeExtensions[ext] ?? catalog.extensions[ext] { return ("file-tree-builtin-" + token, false) }
        }
        return ("file-tree-builtin-default", false)
    }

    static func hasSpecificIcon(for path: String) -> Bool { name(for: path) != "file-tree-builtin-default" }

    static func image(for path: String, mimeType: String? = nil, dark: Bool, size: CGFloat = 14) -> NSImage? {
        let resolved = resolve(path, mimeType: mimeType)
        let name = resolved.overridden && resolved.name.hasPrefix("file-tree-builtin-") && resolved.name != "file-tree-builtin-image"
            ? resolved.name + "-neutral" : resolved.name
        let key = "\(name)-\(dark)-\(size)"
        if let image = images[key] { return image }
        guard let variants = catalog?.icons[name], variants.count == 2,
              let image = NSImage(data: Data(variants[dark ? 1 : 0].utf8)) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = false
        images[key] = image
        return image
    }
}

/// A file glyph that updates with the app theme, independent of the file's location.
final class FileIconView: ThemedView {
    private let path: String
    private let size: CGFloat
    private var image: NSImage?

    init(path: String, size: CGFloat = 16) {
        self.path = path
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size + 8, height: 24))
        setAccessibilityElement(false)
        themeDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func themeDidChange() {
        image = FileIcon.image(for: path, theme: theme, size: size)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
