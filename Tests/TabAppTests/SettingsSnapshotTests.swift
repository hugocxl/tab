import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

/// Hosts Settings offscreen, including every section and the expanded editors.
@MainActor
final class SettingsSnapshotTests: XCTestCase {
    func testRenderEveryPageAndEditor() async throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SETTINGS_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TAB_SETTINGS_SNAPSHOT_DIR to render Settings")
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = PreviewSettingsHost()
        host.profiles.append(BrowserProfileSummary(id: "work", name: "Work"))
        host.importSources = [BrowserImportSource(name: "Safari", supportsCookies: false), BrowserImportSource(name: "Chrome", supportsCookies: true)]
        host.projects = [SettingsProject(id: "demo", name: "Tab")]
        host.remoteAccess = RemoteAccessState(revision: 1, settings: RemoteAccessSettings(enabled: true), status: .listening)
        host.remoteAccess.devices = [PairedDevice(id: DeviceId(), name: "My iPhone", pairedAt: 1, connected: true)]
        let theme = AppTheme.shared
        let wasDark = theme.systemIsDark
        let originalCatalog = theme.catalog
        defer {
            theme.setCatalog(originalCatalog)
            theme.setSystemDark(wasDark)
        }
        theme.setCatalog(ThemeCatalog.load(customDirectory: nil))
        let store = SettingsStore(dirs: TabDirs(root: root), host: host, theme: theme)
        let controller = SettingsWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        defer { window.close() }
        try await Task.sleep(nanoseconds: 50_000_000)
        for dark in [true, false] {
            theme.setSystemDark(dark)
            let mode = dark ? "dark" : "light"
            for category in SettingsCategory.allCases {
                controller.select(category)
                try await Task.sleep(nanoseconds: 5_000_000)
                controller.reload()
                try render(window.contentView, output, "\(mode)-\(category.rawValue)")
            }
        }
        theme.setSystemDark(true)
        controller.select(.terminal)
        controller.model.bindingDraft = BindingDraft(chord: try KeyChord("cmd-ctrl-f9"), action: "text", parameter: "\\e[A")
        controller.reload()
        try render(window.contentView, output, "terminal-binding-editor")
        controller.model.bindingDraft = nil
        controller.model.codepointDraft = CodepointDraft(range: "U+E000-U+F8FF", family: "Menlo")
        controller.reload()
        try render(window.contentView, output, "terminal-codepoint-editor")
        controller.select(.mobile)
        store.startPairing()
        try await Task.sleep(nanoseconds: 20_000_000)
        controller.reload()
        try render(window.contentView, output, "mobile-pairing-qr")
        controller.search("font")
        try render(window.contentView, output, "search-font")
        let proxy = ProxySheet(model: ProxyModel(file: root.appendingPathComponent("proxy.json")), oldServer: false) { _ in }
        proxy.window.isReleasedWhenClosed = false
        proxy.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        try render(proxy.window.contentView, output, "proxy-setup")
        proxy.window.close()
        host.serverState = .stopped
        store.updateServerState(.stopped)
        controller.select(.general)
        try render(window.contentView, output, "general-offline")
    }

    private func render(_ view: NSView?, _ output: String, _ name: String) throws {
        let view = try XCTUnwrap(view)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
}
