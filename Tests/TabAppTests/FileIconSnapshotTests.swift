import AppKit
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class FileIconSnapshotTests: XCTestCase {
    func testRenderFileSurfacesInBothAppearances() throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TAB_SNAPSHOT_DIR to render snapshots")
        }
        _ = NSApplication.shared
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let root = ThemedView(frame: NSRect(x: 0, y: 0, width: 800, height: 610))
            root.layer?.backgroundColor = theme.bg.cgColor
            let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = theme.nsAppearance
            window.contentView = root
            defer { window.contentView = nil; window.close() }

            let paths = ["Sources", "Closed", "main.swift", "Widget.tsx", "types.d.ts", "content.mdx.tsx", "package.json", ".gitignore", "README.md", "Dockerfile", "run.ps1", "report.xlsx", "unknown.xyz"]
            for (index, path) in paths.enumerated() {
                let cell = FilesCellView(frame: NSRect(x: 16, y: 16 + index * 28, width: 250, height: 28))
                cell.theme = theme
                cell.configure(node: .init(path: path, name: path, isDirectory: index < 2, dimmed: path == ".gitignore"),
                               depth: index < 2 ? 0 : 1, expanded: index == 0, selected: path == "main.swift")
                root.addSubview(cell)
                let tile = PaletteTileView(frame: NSRect(x: 290, y: 20 + index * 28, width: 20, height: 20))
                tile.theme = theme
                tile.tile = PaletteTile(.file(path: path, isDirectory: index < 2), .none)
                root.addSubview(tile)
            }

            let picker = AgentComposerSuggestionsView(frame: NSRect(x: 340, y: 16, width: 440, height: 250))
            root.addSubview(picker)
            picker.update(paths.dropFirst(2).map {
                AgentComposerSuggestion(id: "Sources/" + $0, title: $0, subtitle: "Sources", kind: .file)
            }, theme: theme)
            picker.isHidden = false

            let links = AgentRichTextView(frame: NSRect(x: 16, y: 440, width: 760, height: 130))
            links.setContent(AgentMarkdown.inline("Open [**main.swift**](Sources/main.swift:12:4), [package.json](package.json), or [Sources](Sources/).\n[Adjacent](main.swift)[links](README.md) keep their own icons.\nInferred `Sources/main.swift` keeps its code styling.", theme: theme, fileLinks: true, lineBreaks: true))
            links.linkTextAttributes = [:]
            _ = links.height(for: 760)
            root.addSubview(links)
            root.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output + "/file-surfaces-\(dark ? "dark" : "light").png"))
        }
    }
}
