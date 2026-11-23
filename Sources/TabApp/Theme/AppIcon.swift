import AppKit
import SwiftUI
import TabCore
import TabProtocol
import Icons

/// Tab's icons, from @hugocxl/icons' stroke set: signature marks carry their theme hue; UI templates inherit the caller's tint.
public enum AppIcon: String, CaseIterable, Sendable {
    case trash
    case microphone
    case waveform
    case agents
    case antigravity
    case appWindow = "app-window"
    case arrowDown = "arrow-down"
    case arrowUp = "arrow-up"
    case astro
    case babel
    case ban
    case bash
    case bell
    case biome
    case bitbucket
    case bootstrap
    case braces
    case brain
    case browserslist
    case bun
    case c
    case chartLine = "chart-line"
    case check
    case checkbox
    case chevronDown = "chevron-down"
    case chevronLeft = "chevron-left"
    case chevronRight = "chevron-right"
    case chevronUp = "chevron-up"
    case chevronsIn = "chevrons-in"
    case chevronsUpDown = "chevrons-up-down"
    case circleAlert = "circle-alert"
    case circleArrowDown = "circle-arrow-down"
    case circleArrowUp = "circle-arrow-up"
    case circleDashed = "circle-dashed"
    case circle
    case circleCheck = "circle-check"
    case circleUser = "circle-user-round"
    case circleX = "circle-x"
    case claude
    case close
    case code
    case codeBlock = "code-block"
    case codex
    case columns
    case command
    case commentText = "comment-text"
    case conversation
    case conversationAdd = "conversation-add"
    case copilot
    case copy
    case cpp
    case cpu = "microchip"
    case csharp
    case css
    case cursor
    case dart
    case database
    case deno
    case diff
    case docker
    case dot = "circle-small"
    case download
    case droid
    case elixir
    case ellipsis
    case ellipsisCircle = "ellipsis-circle"
    case envelope
    case epub
    case eraser
    case eslint
    case extensions = "extension"
    case externalLink = "external-link"
    case eye
    case file
    case filePlus = "file-plus"
    case fileSymlink = "file-symlink"
    case fileTable = "file-table"
    case fileText = "file-text"
    case foldVertical = "fold-vertical"
    case folder
    case folderOpen = "folder-open"
    case folderPlus = "folder-plus"
    case folderZip = "folder-zip"
    case folders
    case font
    case forgejo
    case gaugeHigh = "gauge-high"
    case gaugeLow = "gauge-low"
    case gaugeMax = "gauge-max"
    case gaugeMedium = "gauge-medium"
    case git
    case gitBranch = "git-branch"
    case gitGraph = "git-graph"
    case gitcafe
    case github
    case gitlab
    case globe
    case go
    case graphql
    case grok
    case hand
    case hash
    case haskell
    case history
    case homebrew
    case html
    case image
    case info
    case java
    case javascript
    case kiro
    case kotlin
    case kubernetes
    case laptop
    case layers
    case lightbulb
    case listTodo = "list-todo"
    case locate
    case lock
    case lockOpen = "lock-open"
    case logs
    case lua
    case markdown
    case maximize
    case mcp
    case minus
    case star
    case minusCircle = "minus-circle"
    case monitor
    case multiplexer
    case network
    case nextjs
    case node
    case npm
    case objc
    case octagonAlert = "octagon-alert"
    case ohMyPi = "oh-my-pi"
    case opencode
    case oxc
    case panelLeft = "panel-left"
    case panelRight = "panel-right"
    case paperclip
    case pauseCircle = "pause-circle-fill"
    case pdf
    case pencil
    case phone
    case phoneAndroid = "phone-android"
    case php
    case pi
    case play
    case plus
    case pnpm
    case postcss
    case powershell
    case prettier
    case python
    case quote
    case r
    case react
    case refresh
    case refreshCircle = "refresh-circle-fill"
    case reset
    case rows
    case rss
    case ruby
    case rust
    case sass
    case scala
    case search
    case serverRack = "server-rack"
    case settings
    case shield
    case shieldKeyhole = "shield-keyhole"
    case slides = "presentation"
    case sparkles = "sparkle"
    case spinner
    case square
    case spreadsheet
    case ssh
    case stylelint
    case svelte
    case svg
    case svgo
    case swift
    case tablet
    case tailwind
    case terminal
    case terminalStack = "terminal-stack"
    case terraform
    case themes = "palette"
    case toml
    case trendingDown = "trending-down"
    case trendingUp = "trending-up"
    case triangleAlert = "triangle-alert"
    case typescript
    case viewList = "list"
    case viewTree = "list-tree"
    case video = "film"
    case vim
    case vite
    case vscode
    case vue
    case wasm
    case webpack
    case word
    case wrap
    case wrench
    case xal
    case xml
    case yarn
    case yml
    case zig
    case zip
    case zoomIn = "zoom-in"
    /// The browser and simulator pane kinds' marks, beside `bash` and
    /// `codeBlock` in the sidebar.
    case browser
    case simulator = "tablet-smartphone"

    /// The signature palette for file types, providers, Git hosts and command brands.
    /// UI glyphs are absent so their surroundings can choose the tint.
    static let signatureHues: [AppIcon: AppTheme.IconHue] = [
        .agents: .orange,
        .browser: .blue,
        .codeBlock: .indigo,
        .simulator: .purple,
        .antigravity: .blue,
        .astro: .purple,
        .babel: .yellow,
        .bash: .green,
        .biome: .blue,
        .bitbucket: .blue,
        .bootstrap: .indigo,
        .braces: .gray,
        .brain: .gray,
        .browserslist: .yellow,
        .bun: .brown,
        .c: .blue,
        .claude: .orange,
        .codex: .gray,
        .copilot: .gray,
        .cpp: .blue,
        .csharp: .purple,
        .css: .indigo,
        .cursor: .gray,
        .dart: .cyan,
        .database: .gray,
        .deno: .gray,
        .diff: .green,
        .docker: .blue,
        .dot: .gray,
        .droid: .orange,
        .elixir: .purple,
        .epub: .orange,
        .eslint: .indigo,
        .file: .gray,
        .fileSymlink: .gray,
        .fileTable: .gray,
        .fileText: .gray,
        .folder: .gray,
        .folderOpen: .gray,
        .font: .gray,
        .forgejo: .orange,
        .git: .vermilion,
        .gitcafe: .brown,
        .github: .gray,
        .gitlab: .orange,
        .go: .cyan,
        .graphql: .pink,
        .grok: .gray,
        .haskell: .indigo,
        .homebrew: .yellow,
        .html: .orange,
        .image: .gray,
        .java: .orange,
        .javascript: .yellow,
        .kiro: .purple,
        .kotlin: .purple,
        .kubernetes: .blue,
        .lock: .gray,
        .lua: .blue,
        .markdown: .gray,
        .mcp: .gray,
        .nextjs: .gray,
        .node: .green,
        .npm: .red,
        .objc: .vermilion,
        .ohMyPi: .purple,
        .opencode: .gray,
        .oxc: .cyan,
        .pdf: .red,
        .php: .indigo,
        .pi: .purple,
        .pnpm: .orange,
        .postcss: .red,
        .powershell: .blue,
        .prettier: .teal,
        .python: .blue,
        .r: .blue,
        .react: .cyan,
        .ruby: .red,
        .rust: .orange,
        .sass: .pink,
        .scala: .red,
        .slides: .orange,
        .spreadsheet: .green,
        .stylelint: .gray,
        .svelte: .red,
        .svg: .orange,
        .svgo: .green,
        .swift: .orange,
        .tailwind: .cyan,
        .terraform: .indigo,
        .toml: .gray,
        .typescript: .blue,
        .video: .pink,
        .vim: .green,
        .vite: .purple,
        .vscode: .blue,
        .vue: .green,
        .wasm: .indigo,
        .webpack: .blue,
        .word: .blue,
        .xal: .blue,
        .xml: .orange,
        .yarn: .blue,
        .yml: .red,
        .zig: .orange,
        .zip: .gray,
    ]

    /// The theme hue this mark always uses, or nil for a contextual UI glyph.
    public var signatureHue: AppTheme.IconHue? { Self.signatureHues[self] }

    /// Optical scale for small agent conversation glyphs beside text and in controls,
    /// matching the visible size of the SF Symbols they replaced on the same canvas.
    public static let inlineScale: CGFloat = 0.78

    /// Which of @hugocxl/icons' sets an image comes from.
    public enum Artwork: String, Sendable {
        /// Outlines, used everywhere but the Explorer.
        case stroke
        /// The default two-tone set, kept only for the Explorer's file tree.
        case duotone
    }

    /// Draws signature marks in their theme hue; UI glyphs remain templates.
    @MainActor
    public func image(size: CGFloat = Metrics.glyph, scale: CGFloat = 1, theme: AppTheme,
                      artwork: Artwork = .stroke) -> NSImage? {
        if let hue = signatureHue { return image(size: size, scale: scale, hue: hue, theme: theme, artwork: artwork) }
        return image(size: size, scale: scale, artwork: artwork)
    }

    /// Applies a contextual tint only to UI glyphs, preserving signature colors.
    @MainActor
    public func image(size: CGFloat, scale: CGFloat = 1, theme: AppTheme, tint: NSColor) -> NSImage? {
        if signatureHue != nil { return image(size: size, scale: scale, theme: theme) }
        return image(size: size, scale: scale, color: tint)
    }

    /// The default set's name for icons whose stroke stand-in has another name.
    private var duotoneName: String {
        switch self {
        case .bell: return "bell-unread"
        case .circleUser: return "circle-user"
        case .cpu: return "cpu"
        case .dot: return "dot"
        case .simulator: return "simulator"
        case .slides: return "slides"
        case .sparkles: return "sparkles"
        case .themes: return "themes"
        case .video: return "video"
        default: return rawValue
        }
    }

    /// The glyph from the chosen set. Brand and language logos have no
    /// stroke version, so they keep their single mark.
    private func source(_ artwork: Artwork) -> NSImage? {
        switch artwork {
        case .stroke: return StrokeIcon(rawValue: rawValue)?.nsImage ?? Icon(rawValue: rawValue)?.nsImage
        case .duotone: return Icon(rawValue: duotoneName)?.nsImage
        }
    }

    /// A template image on a square canvas `size` points on a side, with the
    /// glyph fitted to `size * scale` and centered, so wide and narrow icons
    /// lay out like the square ones.
    @MainActor
    public func image(size: CGFloat = Metrics.glyph, scale: CGFloat = 1, artwork: Artwork = .stroke) -> NSImage? {
        let key = "template-\(artwork.rawValue)-\(rawValue)-\(size)-\(scale)"
        if let cached = IconCache.images[key] { return cached }
        guard let source = source(artwork), source.size.width > 0, source.size.height > 0 else { return nil }
        let fit = min(size * scale / source.size.width, size * scale / source.size.height)
        let fitted = NSSize(width: source.size.width * fit, height: source.size.height * fit)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: NSRect(x: (rect.width - fitted.width) / 2, y: (rect.height - fitted.height) / 2,
                                   width: fitted.width, height: fitted.height))
            return true
        }
        image.isTemplate = true
        IconCache.images[key] = image
        return image
    }

    /// A non-template image filled with `color`, preserving the SVG's opacity.
    @MainActor
    public func image(size: CGFloat, scale: CGFloat = 1, color: NSColor, artwork: Artwork = .stroke) -> NSImage? {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let key = "tinted-\(artwork.rawValue)-\(rawValue)-\(size)-\(scale)-\(resolved)"
        if let cached = IconCache.images[key] { return cached }
        guard let source = image(size: size, scale: scale, artwork: artwork) else { return nil }
        let tinted = NSImage(size: source.size, flipped: false) { rect in
            source.draw(in: rect)
            resolved.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        tinted.isTemplate = false
        IconCache.images[key] = tinted
        return tinted
    }

    /// A non-template image in the chosen theme hue.
    @MainActor
    public func image(size: CGFloat, scale: CGFloat = 1, hue: AppTheme.IconHue, theme: AppTheme,
                      artwork: Artwork = .stroke) -> NSImage? {
        guard let hex = UInt32(theme.iconHex(hue).dropFirst(), radix: 16) else { return nil }
        return image(size: size, scale: scale, color: NSColor(hex: hex), artwork: artwork)
    }
}

extension SwiftUI.Image {
    /// Signature marks keep their theme color; UI glyphs accept foreground styling.
    @MainActor
    public init(_ icon: AppIcon, size: CGFloat = 16) {
        self.init(icon, size: size, theme: .shared)
    }

    /// A Tab Icon drawn with an explicitly supplied app theme.
    @MainActor
    public init(_ icon: AppIcon, size: CGFloat = 16, theme: AppTheme) {
        self = Image(nsImage: icon.image(size: size, theme: theme) ?? NSImage())
            .renderingMode(icon.signatureHue == nil ? .template : .original)
    }
}

@MainActor
private enum IconCache {
    static var images: [String: NSImage] = [:]
    static var ink: [ObjectIdentifier: NSRect] = [:]
}

extension NSImage {
    /// The part of the image that is drawn, in its own points: glyphs leave
    /// uneven margins, which matters when spacing them by what is visible.
    @MainActor
    var inkBounds: NSRect {
        if let cached = IconCache.ink[ObjectIdentifier(self)] { return cached }
        let scale = 4
        let width = Int(ceil(size.width)) * scale, height = Int(ceil(size.height)) * scale
        var bounds = NSRect(origin: .zero, size: size)
        if width > 0, height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ), let data = rep.bitmapData {
            rep.size = NSSize(width: ceil(size.width), height: ceil(size.height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            var minX = width, maxX = -1, minY = height, maxY = -1
            for y in 0..<height {
                for x in 0..<width where data[(y * width + x) * 4 + 3] > 76 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            if maxX >= 0 {
                let unit = 1 / CGFloat(scale)
                // Bitmap rows run top down; the image's points run bottom up.
                bounds = NSRect(x: CGFloat(minX) * unit, y: size.height - CGFloat(maxY + 1) * unit,
                                width: CGFloat(maxX + 1 - minX) * unit, height: CGFloat(maxY + 1 - minY) * unit)
            }
        }
        IconCache.ink[ObjectIdentifier(self)] = bounds
        return bounds
    }
}

/// Provider marks from @hugocxl/icons, colored in the provider's theme hue.
public enum AgentLogo {
    /// The provider's mark on a 64-point square canvas, including a generic
    /// agent mark for unknown providers.
    @MainActor
    public static func image(for provider: AgentProvider, lightBackground: Bool) -> NSImage? {
        mark(provider).image(size: 64, theme: AppTheme.shared)
    }

    /// A configured provider's mark, with a dot of its accent color in the corner when it has one,
    /// so several accounts of one kind tell apart.
    @MainActor
    public static func image(for provider: AgentProviderConfig, lightBackground: Bool) -> NSImage? {
        let logo = image(for: provider.kind.activityProvider, lightBackground: lightBackground)
        guard let logo, let accent = provider.accentColor.flatMap(RGBColor.init(hex:))?.nsColor else { return logo }
        return NSImage(size: logo.size, flipped: false) { rect in
            logo.draw(in: rect)
            let side = (rect.width * 0.4).rounded()
            accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - side, y: rect.minY, width: side, height: side)).fill()
            return true
        }
    }

    static func mark(_ provider: AgentProvider) -> AppIcon {
        switch provider {
        case .claude: return .claude
        case .codex: return .codex
        case .openCode: return .opencode
        case .cursor: return .cursor
        case .copilot: return .copilot
        case .droid: return .droid
        case .pi: return .pi
        case .grok: return .grok
        case .kiro: return .kiro
        case .xal: return .xal
        case .antigravity: return .antigravity
        // @hugocxl/icons has no Gemini mark yet; the generic agent mark stands in.
        case .gemini: return .brain
        case .ohMyPi: return .ohMyPi
        case .unknown: return .brain
        }
    }
}
