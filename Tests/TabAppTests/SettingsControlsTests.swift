import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

/// Drives every control on every Settings page and checks which key of
/// `settings.json`, `terminal.json` or the server it wrote.
@MainActor
final class SettingsControlsTests: XCTestCase {
    private var root: URL!
    private var dirs: TabDirs!
    private var host: PreviewSettingsHost!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-controls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dirs = TabDirs(root: root)
        host = PreviewSettingsHost()
        host.remoteAccess = RemoteAccessState(revision: 1, settings: RemoteAccessSettings(enabled: true), status: .listening)
        host.projects = [SettingsProject(id: "11111111-1111-1111-1111-111111111111", name: "demo")]
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The JSON leaves that differ between two documents, as dotted paths.
    private func changedPaths(_ old: Any?, _ new: Any?, prefix: String = "") -> [String] {
        switch (old, new) {
        case let (a as [String: Any], b as [String: Any]):
            return Set(a.keys).union(b.keys).sorted().flatMap { key in
                changedPaths(a[key], b[key], prefix: prefix.isEmpty ? key : "\(prefix).\(key)")
            }
        default:
            let encode = { (value: Any?) -> Data? in
                value.flatMap { try? JSONSerialization.data(withJSONObject: [$0], options: [.sortedKeys]) }
            }
            return encode(old) == encode(new) ? [] : [prefix]
        }
    }

    private func document(_ url: URL) -> Any? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    private struct Snapshot {
        var settings: Any?
        var terminal: Any?
        var server: ServerSettingsDoc
        var remote: RemoteAccessSettings
    }

    private func snapshot() -> Snapshot {
        Snapshot(settings: document(dirs.settings), terminal: document(dirs.terminalSettings),
                 server: host.serverSettings, remote: host.remoteAccess.settings)
    }

    private func written(since before: Snapshot) -> [String] {
        let after = snapshot()
        var paths = changedPaths(before.settings, after.settings).map { "settings.json:\($0)" }
        paths += changedPaths(before.terminal, after.terminal).map { "terminal.json:\($0)" }
        if before.server != after.server { paths.append("server") }
        if before.remote != after.remote { paths.append("remote") }
        return paths
    }

    private func controls(in view: NSView) -> [NSView] {
        if view is Switch || view is SegmentedPill || view is PopUp || view is Slider || view is InsetTextField {
            return [view]
        }
        return view.subviews.flatMap(controls)
    }

    /// Actuates `control` once; `false` when it offers nothing else to pick.
    private func actuate(_ control: NSView, rowId: String) -> Bool {
        switch control {
        case let toggle as Switch:
            guard toggle.isEnabled else { return false }
            toggle.toggle()
        case let pill as SegmentedPill:
            pill.select(pill.selectedIndex == 0 ? 1 : 0)
        case let popUp as PopUp:
            guard let other = popUp.items.first(where: { $0.id != popUp.selectedId && !$0.id.hasPrefix("__") }) else { return false }
            popUp.choose(other.id)
        case let slider as Slider:
            let next = slider.value + slider.step <= slider.maximum ? slider.value + slider.step : slider.value - slider.step
            slider.value = next
            slider.onCommit?(next)
        case let field as InsetTextField:
            let numeric = Double(field.stringValue) != nil || Double(field.field.placeholderString ?? "") != nil
            field.stringValue = numeric ? "1000" : (field.stringValue.isEmpty ? "qa-value" : field.stringValue + "-qa")
            if rowId.contains("folder") || rowId.contains("template") { field.stringValue = "~/qa-worktrees" }
            field.commit()
        default:
            return false
        }
        return true
    }

    func testEveryControlWritesItsSetting() async throws {
        let store = SettingsStore(dirs: dirs, host: host, theme: AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: true))
        store.loadServerSettings()
        store.loadRemoteAccess()
        try await Task.sleep(nanoseconds: 50_000_000)
        let page = SettingsPageView(store: store)
        var report: [String: [String]] = [:]
        var silent: [String] = []
        for category in SettingsCategory.allCases {
            page.category = category
            page.reload()
            let rowIds = try XCTUnwrap(page.lastBuild).groups.flatMap(\.blocks).compactMap { block -> String? in
                if case .row(let row) = block { return row.id }
                return nil
            }
            for rowId in rowIds {
                for index in 0 ..< 8 {
                    page.reload()
                    guard let row = page.lastBuild?.groups.flatMap(\.blocks).lazy.compactMap({ block -> CardRow? in
                        if case .row(let row) = block, row.id == rowId { return row }
                        return nil
                    }).first, let view = row.control else { break }
                    let found = controls(in: view)
                    guard found.indices.contains(index) else { break }
                    let before = snapshot()
                    guard actuate(found[index], rowId: rowId) else { continue }
                    try await Task.sleep(nanoseconds: 2_000_000)
                    let paths = written(since: before)
                    let key = index == 0 ? rowId : "\(rowId)#\(index)"
                    if paths.isEmpty && store.errors[rowId] == nil {
                        silent.append(key)
                    } else {
                        report[key] = paths.isEmpty ? ["refused: \(store.errors[rowId] ?? "")"] : paths
                    }
                    store.dismissError(rowId)
                }
            }
        }
        let table = report.keys.sorted().map { "\($0) -> \(report[$0]!.joined(separator: ", "))" }.joined(separator: "\n")
        if let path = ProcessInfo.processInfo.environment["TAB_SETTINGS_REPORT"] {
            try Data((table + "\n\nsilent: \(silent.joined(separator: ", "))\n").utf8).write(to: URL(fileURLWithPath: path))
        }
        XCTAssertEqual(silent, [], "these controls changed nothing")

        let expected: [String: String] = [
            "close-behavior": "settings.json:closeBehavior",
            "confirm-running-process": "settings.json:confirmRunningProcess",
            "width": "settings.json:windowSize.width",
            "height": "settings.json:windowSize.height",
            "voice-auto-send": "settings.json:voice.autoSend",
            "font-ligatures": "terminal.json:fontLigatures",
            "browser-enabled": "settings.json:browser.enabled",
            "ai-commit-push": "settings.json:ai.commit.push",
            "ai-project-pr-prompt#1": "settings.json:ai.projectPrPrompts.11111111-1111-1111-1111-111111111111",
            "mobile-enabled": "remote",
            "default-shell": "server",
        ]
        for (row, path) in expected {
            XCTAssertTrue(report[row]?.contains(path) ?? false, "\(row) wrote \(report[row] ?? []) instead of \(path)")
        }
    }
}
