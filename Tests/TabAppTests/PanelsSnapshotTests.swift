import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

/// Renders Settings, the panels and the feature sheets offscreen to PNGs for
/// comparing with `design/reference`. Runs only with `TAB_SNAPSHOT_DIR` set.
@MainActor
final class PanelsSnapshotTests: XCTestCase {
    private var output = ""
    private var root: URL!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TAB_SNAPSHOT_DIR to render snapshots")
        }
        output = dir
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-snap-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var theme: AppTheme { AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: true) }

    func testRenderSettingsPages() async throws {
        let host = PreviewSettingsHost()
        host.remoteAccess = RemoteAccessState(revision: 1, settings: RemoteAccessSettings(enabled: true), status: .listening)
        let store = SettingsStore(dirs: TabDirs(root: root), host: host, theme: theme)
        let controller = SettingsWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(SettingsWindowController.defaultSize)
        for category in SettingsCategory.allCases {
            controller.select(category, section: nil)
            if category == .mobile {
                store.loadRemoteAccess()
                try await Task.sleep(nanoseconds: 50_000_000)
                store.startPairing()
            }
            try await Task.sleep(nanoseconds: 80_000_000)
            controller.reload()
            try render(window.contentView, "settings-\(category.rawValue)")
        }
        controller.search("font")
        try render(window.contentView, "settings-search")
    }

    func render(_ view: NSView?, _ name: String) throws {
        let view = try XCTUnwrap(view)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
    }
}

/// Renders the Files and Source Control panels, the diff pane and the editor
/// from a real `tabd` and a real repository. Runs only with `TAB_SNAPSHOT_DIR`.
@MainActor
final class PanelsLiveSnapshotTests: LiveServerTestCase {
    private var output = ""

    override func setUp() async throws {
        guard let dir = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TAB_SNAPSHOT_DIR to render snapshots")
        }
        output = dir
        _ = NSApplication.shared
        try await super.setUp()
    }

    private func render(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
    }

    func testRenderPanelsAndPanes() async throws {
        for folder in [".agents", ".claude", "backend", "docs", "frontend", "node_modules", "packages", "scripts"] {
            try write("\(folder)/.keep", "")
        }
        for file in [".env", "AGENTS.md", "CLAUDE.md", "Dockerfile", "biome.json", "package.json", "docker-compose.yml"] {
            try write(file, "x\n")
        }
        try write(".gitignore", "node_modules\n.env\n")
        try write("conflict.txt", "base\n")
        try git("add", ".")
        try git("commit", "-q", "-m", "Layout")
        try git("checkout", "-q", "-b", "other")
        try write("conflict.txt", "theirs\n")
        try git("commit", "-qam", "Theirs")
        try git("checkout", "-q", "main")
        try write("conflict.txt", "ours\n")
        try git("commit", "-qam", "Ours")
        try git("merge", "other")
        try write("staged.swift", "let staged = true\n")
        try git("add", "staged.swift")
        try write("Sources/App.swift", "import Foundation\n\n/// The answer.\nlet answer = 43\nprint(answer)\n")
        try write("untracked.md", "new\n")

        let files = FilesPanelController(host: host)
        let filesWindow = show(files, size: NSSize(width: 300, height: 640))
        files.ensureRoot()
        await settle { files.tree.isLoaded("") }
        files.open("docs")
        await settle { files.tree.isLoaded("docs") }
        try render(try XCTUnwrap(filesWindow.contentView), "files-panel")

        let control = SourceControlController(host: host)
        let controlWindow = show(control, size: NSSize(width: 300, height: 640))
        control.refresh()
        await settle { control.model.status != nil }
        try render(try XCTUnwrap(controlWindow.contentView), "source-control")

        let diff = DiffPaneController(host: host, path: "Sources/App.swift", staged: false)
        let diffWindow = show(diff, size: NSSize(width: 760, height: 420))
        diff.refresh()
        await settle { diff.document != nil }
        try render(try XCTUnwrap(diffWindow.contentView), "diff-pane")

        try write("Sources/Highlight.swift", """
        import AppKit

        /// Draws a rounded card.
        @MainActor
        final class Card: NSView {
            private let radius: CGFloat = 10 // points
            var title = "Files"

            override func draw(_ dirtyRect: NSRect) {
                let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
                NSColor(white: 0.1, alpha: 1).setFill()
                path.fill()
                if title.isEmpty { return }
                print("drawn \\(title) at \\(0x1F)")
            }
        }

        """)
        let editor = EditorPaneController(host: host, path: "Sources/Highlight.swift")
        let editorWindow = show(editor, size: NSSize(width: 760, height: 420))
        editor.viewDidAppear()
        await settle { editor.text.contains("Card") }
        try await Task.sleep(nanoseconds: 100_000_000)
        try render(try XCTUnwrap(editorWindow.contentView), "editor-pane")
    }
}
