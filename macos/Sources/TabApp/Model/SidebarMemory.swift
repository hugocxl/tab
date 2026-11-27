import AppKit
import Foundation
import TabCore
import TabProtocol

/// What the sidebar last showed: each project's Git facts and icon, and
/// pages' favicons. Saved in the profile so the next launch draws them in
/// its first frame, before any server answers; live values replace them as
/// they arrive. Only for display: decisions use live values.
@MainActor
final class SidebarMemory {
    struct Contents: Codable, Sendable {
        /// By project id.
        var git: [String: RememberedGit] = [:]
        /// By project icon key: a local folder's path, else the project id.
        var icons: [String: RememberedImage] = [:]
        /// By page origin, such as `https://github.com`.
        var favicons: [String: RememberedImage] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            git = try container.decodeIfPresent([String: RememberedGit].self, forKey: .git) ?? [:]
            icons = try container.decodeIfPresent([String: RememberedImage].self, forKey: .icons) ?? [:]
            favicons = try container.decodeIfPresent([String: RememberedImage].self, forKey: .favicons) ?? [:]
        }
    }

    struct RememberedGit: Codable, Sendable, Equatable {
        /// `nil` when the project isn't a repository.
        var summary: GitSummary?
        var pullRequest: UInt64?
    }

    struct RememberedImage: Codable, Sendable, Equatable {
        /// A small PNG; `nil` when there is none.
        var png: Data?
        var used: Date?
    }

    /// Favicons kept, the most recently used.
    static let faviconLimit = 200
    /// Pixels on a side of a remembered icon: a 32-point icon on Retina.
    nonisolated static let iconPixels = 64
    /// Pixels on a side of a remembered favicon: 16 points on Retina.
    nonisolated static let faviconPixels = 32

    private let file: URL?
    /// Writes in order, so an older save never lands after a newer one.
    private let writer = DispatchQueue(label: "tab.sidebar-cache", qos: .utility)
    private(set) var contents: Contents
    private var images: [Data: NSImage] = [:]
    private var saveScheduled = false

    /// Loads `file`; a missing or unreadable one starts empty. With no file,
    /// nothing is saved.
    init(file: URL?) {
        self.file = file
        contents = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Contents.self, from: $0) } ?? Contents()
    }

    // MARK: Git

    func git(_ project: ProjectId) -> GitInfo? {
        contents.git[project.description].map { GitInfo(summary: $0.summary, pullRequest: $0.pullRequest) }
    }

    func setGit(_ project: ProjectId, _ info: GitInfo) {
        let remembered = RememberedGit(summary: info.summary, pullRequest: info.pullRequest)
        guard contents.git[project.description] != remembered else { return }
        contents.git[project.description] = remembered
        scheduleSave()
    }

    // MARK: Project icons

    /// The remembered icon's PNG, or `nil` when unknown or there is none.
    func iconPNG(_ key: String) -> Data? {
        contents.icons[key]?.png
    }

    func setIcon(_ key: String, png: Data?) {
        let remembered = RememberedImage(png: png)
        guard contents.icons[key] != remembered else { return }
        contents.icons[key] = remembered
        scheduleSave()
    }

    // MARK: Favicons

    /// The favicon last shown for a page of `url`'s site.
    func favicon(for url: String) -> NSImage? {
        guard let origin = Self.origin(url), let png = contents.favicons[origin]?.png, let image = image(png) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    func setFavicon(_ png: Data, for url: String) {
        guard let origin = Self.origin(url) else { return }
        let now = Date()
        if let current = contents.favicons[origin], current.png == png,
           let used = current.used, now.timeIntervalSince(used) < 24 * 60 * 60 { return }
        contents.favicons[origin] = RememberedImage(png: png, used: now)
        if contents.favicons.count > Self.faviconLimit {
            let kept = contents.favicons.sorted { ($0.value.used ?? .distantPast) > ($1.value.used ?? .distantPast) }
                .prefix(Self.faviconLimit)
            contents.favicons = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        scheduleSave()
    }

    /// `scheme://host[:port]` of a web page, or `nil` for other addresses.
    static func origin(_ url: String) -> String? {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        return components.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    // MARK: Images

    /// `png` decoded, once per distinct image.
    func image(_ png: Data) -> NSImage? {
        if let cached = images[png] { return cached }
        guard let image = NSImage(data: png) else { return nil }
        images[png] = image
        return image
    }

    /// `image` drawn at most `pixels` square as a PNG, keeping its aspect
    /// ratio. Safe off the main thread.
    nonisolated static func thumbnail(_ image: NSImage, pixels: Int = iconPixels) -> Data? {
        guard image.size.width > 0, image.size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let side = CGFloat(pixels)
        let scale = min(side / image.size.width, side / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: Keeping

    /// Forgets the Git facts of projects not in `projects`.
    func retain(projects: Set<ProjectId>) {
        let keys = Set(projects.map(\.description))
        let git = contents.git.filter { keys.contains($0.key) }
        guard git.count != contents.git.count else { return }
        contents.git = git
        scheduleSave()
    }

    /// Forgets the icons whose keys aren't in `keys`.
    func retain(iconKeys keys: Set<String>) {
        let icons = contents.icons.filter { keys.contains($0.key) }
        guard icons.count != contents.icons.count else { return }
        contents.icons = icons
        scheduleSave()
    }

    /// Writes pending changes now, such as when quitting.
    func saveNow() {
        saveScheduled = false
        guard let file else { return }
        let contents = contents
        writer.sync { Self.write(contents, to: file) }
    }

    private func scheduleSave() {
        guard file != nil, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.saveScheduled else { return }
                self.saveScheduled = false
                self.saveInBackground()
            }
        }
    }

    private func saveInBackground() {
        guard let file else { return }
        let contents = contents
        writer.async { Self.write(contents, to: file) }
    }

    private nonisolated static func write(_ contents: Contents, to file: URL) {
        do {
            try JSONEncoder().encode(contents).write(to: file, options: .atomic)
        } catch {
            Log.app.error("Could not save the sidebar cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}
