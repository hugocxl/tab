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
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-controls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dirs = TabDirs(root: root)
        host = PreviewSettingsHost()
        host.languages = [DictationLanguage(id: "en-US", name: "English (United States)")]
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

    /// The controls on a row that write settings.
    private func controls(in control: SettingControl) -> [SettingControl] {
        control.leaves.filter {
            switch $0 {
            case .toggle, .segmented, .choice, .slider, .text: return true
            default: return false
            }
        }
    }

    /// Actuates `control` once; `false` when it offers nothing else to pick.
    private func actuate(_ control: SettingControl, rowId: String) -> Bool {
        switch control {
        case .toggle(let toggle):
            guard toggle.enabled else { return false }
            toggle.change(!toggle.isOn)
        case .segmented(let pill):
            pill.change(pill.selected == 0 ? 1 : 0)
        case .choice(let popUp):
            guard let other = popUp.items.first(where: { $0.id != popUp.selected && !$0.id.hasPrefix("__") }) else { return false }
            popUp.change(other.id)
        case .slider(let slider):
            let next = slider.value + slider.step <= slider.range.upperBound ? slider.value + slider.step : slider.value - slider.step
            slider.commit(next)
        case .text(let field):
            guard field.enabled else { return false }
            if rowId == "browser-profiles" { return false }
            let numeric = Double(field.value) != nil || Double(field.placeholder) != nil
            var text = numeric ? "1000" : (field.value.isEmpty ? "qa-value" : field.value + "-qa")
            if rowId.contains("folder") || rowId.contains("template") { text = "~/qa-worktrees" }
            if rowId == "worktree-template" { text = "../{base-dir}.{branch}" }
            if rowId == "default-shell" { text = "/bin/bash" }
            if rowId == "mobile-port" { text = "7420" }
            if rowId == "browser-home-page" { text = "https://example.com" }
            if rowId == "font-feature" { text = "ss01" }
            if ["palette", "background", "foreground", "cursor-color", "cursor-text", "selection-foreground", "selection-background"].contains(rowId) {
                text = "#123456"
            }
            field.commit(text)
        default:
            return false
        }
        return true
    }

    func testVoiceModelCanBeEditedAndCleared() throws {
        let store = SettingsStore(dirs: dirs, host: host, theme: AppTheme(systemIsDark: true))
        let page = SettingsModel(store: store)
        page.select(.general)
        let row = try XCTUnwrap(page.lastBuild?.rows.first { $0.id == "voice-model" })
        guard case .text(let field) = row.control else { return XCTFail("voice-model is not a text field") }
        XCTAssertTrue(field.enabled)
        field.commit("/tmp/spanish.lm")
        XCTAssertEqual(try Settings.load(dirs.settings).voice.model, "/tmp/spanish.lm")
        field.commit("")
        XCTAssertEqual(try Settings.load(dirs.settings).voice.model, "")
    }

    func testEveryControlWritesItsSetting() async throws {
        let store = SettingsStore(dirs: dirs, host: host, theme: AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: true))
        store.loadServerSettings()
        store.loadRemoteAccess()
        try await Task.sleep(nanoseconds: 50_000_000)
        let page = SettingsModel(store: store)
        var report: [String: [String]] = [:]
        var silent: [String] = []
        for category in SettingsCategory.allCases {
            page.select(category)
            let rowIds = try XCTUnwrap(page.lastBuild).rows.map(\.id)
            for rowId in rowIds {
                for index in 0 ..< 16 {
                    page.reload()
                    guard let row = page.lastBuild?.rows.first(where: { $0.id == rowId }), let control = row.control else { break }
                    let found = controls(in: control)
                    guard found.indices.contains(index) else { break }
                    let before = snapshot()
                    guard actuate(found[index], rowId: rowId) else { continue }
                    if category == .server || category == .mobile {
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }
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
            "close-behavior": "settings.json:window.closeBehavior",
            "confirm-process": "settings.json:window.confirmRunningProcess",
            "width": "settings.json:window.defaultSize.width",
            "height": "settings.json:window.defaultSize.height",
            "voice-auto-send": "settings.json:voice.autoSend",
            "voice-model": "settings.json:voice.model",
            "font-ligatures": "terminal.json:font.features",
            "browser-enabled": "settings.json:browser.enabled",
            "ai-commit-push": "settings.json:ai.commit.push",
            "ai-project-pr-prompt#1": "settings.json:ai.projectPrPrompts.11111111-1111-1111-1111-111111111111",
            "mobile-access": "remote",
            "default-shell": "server",
        ]
        for (row, path) in expected {
            XCTAssertTrue(report[row]?.contains(path) ?? false, "\(row) wrote \(report[row] ?? []) instead of \(path)")
        }
        XCTAssertEqual(try Settings.load(dirs.settings), store.settings)
        XCTAssertEqual(try TerminalSettings.load(dirs.terminalSettings), store.terminal)
        XCTAssertEqual(host.appliedSettings.last, store.settings)
        XCTAssertEqual(host.appliedTerminal.last, store.terminal)
        XCTAssertEqual(store.serverSettings, host.serverSettings)
        XCTAssertEqual(store.remoteAccess?.settings, host.remoteAccess.settings)
    }
}
