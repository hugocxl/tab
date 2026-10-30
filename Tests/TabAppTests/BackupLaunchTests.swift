import XCTest
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class BackupLaunchTests: XCTestCase {
    func testPortableArchiveRestoresAtLaunchWithRecoveryAndMatchedLayouts() throws {
        let source = try ModelFixtures.profile()
        defer { try? FileManager.default.removeItem(at: source.root) }
        let firstDirectory = source.root.appendingPathComponent("project-one", isDirectory: true)
        let secondDirectory = source.root.appendingPathComponent("project-two", isDirectory: true)
        for directory in [firstDirectory, secondDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("project-file-secret".utf8).write(to: directory.appendingPathComponent("source.swift"))
        }
        var settings = Settings()
        settings.window.closeBehavior = .detach
        settings.browser.openTerminalLinks = true
        let remote = ServerEntry(name: "Production", ssh: "dev@box", port: 2222, group: "Team")
        settings.servers = [remote]
        try AtomicFile.write(JSONEncoder().encode(settings), to: source.settings)
        var terminal = TerminalSettings()
        terminal.fontSize = 23
        try terminal.save(to: source.terminalSettings)
        let serverSettings = ServerSettingsDoc(defaultShell: "/bin/zsh", historyBudgetBytes: 1_048_576, shellIntegration: false)
        try AtomicFile.write(JSONEncoder().encode(serverSettings), to: source.serverSettings)
        try FileManager.default.createDirectory(at: source.themes, withIntermediateDirectories: true)
        try Data("background = 123456\nforeground = abcdef\n".utf8).write(to: source.themes.appendingPathComponent("Custom"))
        try ProxySettings(kind: .socks5, host: "proxy", port: 1080, username: "me", password: "proxy-secret", global: true).save(to: source.proxy)
        try Data("paired-device-secret".utf8).write(to: source.root.appendingPathComponent("remote.json"))
        try FileManager.default.createDirectory(at: source.root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try Data("live-session-secret".utf8).write(to: source.root.appendingPathComponent("sessions/live"))

        let model = AppModel(dirs: source, theme: AppTheme(systemIsDark: true))
        let first = try XCTUnwrap(model.addProject(firstDirectory.path))
        let second = try XCTUnwrap(model.addProject(secondDirectory.path))
        var originalPanes: [PaneId] = []
        let live = SessionId()
        model.edit { state in
            _ = try state.openTerminalTab(first)
            let pane = try XCTUnwrap(state.window.activePane)
            let split = try state.splitPane(pane, edge: .down)
            originalPanes = [pane, split]
            try state.setRatio(try XCTUnwrap(state.project(first)?.tabs.first?.id), path: [], ratio: 0.3)
            try state.setPaneSession(pane, live)
            try state.setPaneProxy(pane, true)
            try state.setPaneTitle(pane, "Saved main")
            try state.setPaneTitle(split, "Saved split")
            _ = try state.openTerminalTab(second)
            let workspace = try state.createWorkspace("Portable")
            try state.setWorkspaceMember(workspace, project: first, member: true)
            let home = ProjectDescriptor.home(directory: "/home/dev")
            let project = ProjectDescriptor(directory: "/remote-only-secret", name: "Remote")
            try state.applyCatalog(remote.id, CatalogPage(server: ServerId(), home: home.id, revision: 1, projects: [home, project]))
            _ = try state.openTerminalTab(project.id)
        }
        model.terminalFontSizes[originalPanes[0].description] = 27
        let state = try SettingsHostImpl(model: model).backupState()
        let exported = try BackupArchive.collect(from: source, state: state)
        let archiveURL = source.root.appendingPathComponent("profile.tab")
        try exported.write(to: archiveURL)
        let archive = try BackupArchive.read(archiveURL)
        let expectedSettings = try Settings.decode(try XCTUnwrap(archive.files["settings.json"]))
        XCTAssertEqual(expectedSettings.browser, settings.browser)
        XCTAssertEqual(expectedSettings.servers, [remote])
        XCTAssertEqual(expectedSettings.window, settings.window)
        XCTAssertEqual(Set(archive.files.keys), ["settings.json", "terminal.json", "server.json", "state.json", "themes/Custom"])
        let portable = try AppStateStore.decode(try XCTUnwrap(archive.files["state.json"]))
        XCTAssertTrue(portable.projects.allSatisfy { $0.serverId.isLocal })
        XCTAssertTrue(portable.projects.flatMap(\.tabs).flatMap(\.panes).allSatisfy { $0.content.session == nil && !$0.proxy })
        XCTAssertTrue(portable.projectIntents(.local).isEmpty)
        let archiveText = String(decoding: archive.files.values.reduce(into: Data()) { $0.append($1) }, as: UTF8.self)
        for excluded in ["paired-device-secret", "live-session-secret", "project-file-secret", "proxy-secret", "/remote-only-secret", live.description] {
            XCTAssertFalse(archiveText.contains(excluded), excluded)
        }

        for existingProjects in [false, true] {
            let destination = try ModelFixtures.profile()
            defer { try? FileManager.default.removeItem(at: destination.root) }
            var oldSettings = Settings()
            oldSettings.browser.homePage = "https://old.example"
            try AtomicFile.write(JSONEncoder().encode(oldSettings), to: destination.settings)
            var oldTerminal = TerminalSettings()
            oldTerminal.fontSize = 12
            try oldTerminal.save(to: destination.terminalSettings)
            try AtomicFile.write(JSONEncoder().encode(ServerSettingsDoc()), to: destination.serverSettings)
            try FileManager.default.createDirectory(at: destination.themes, withIntermediateDirectories: true)
            try Data("background = 654321\n".utf8).write(to: destination.themes.appendingPathComponent("Old"))
            var current = try AppState.bootstrap()
            var matched: ProjectId?
            var kept: ProjectId?
            if existingProjects {
                matched = try current.addProject(server: .local, directory: firstDirectory.path)
                _ = try current.openTerminalTab(try XCTUnwrap(matched))
                let existing = source.root.appendingPathComponent("project-existing")
                try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
                kept = try current.addProject(server: .local, directory: existing.path)
            }
            let oldState = try AppStateStore.encode(current)
            try AtomicFile.write(oldState, to: destination.state)
            let originals = try Dictionary(uniqueKeysWithValues: ["settings.json", "terminal.json", "server.json", "state.json"].map {
                ($0, try Data(contentsOf: destination.root.appendingPathComponent($0)))
            })
            try archive.stage(in: destination)
            XCTAssertEqual(try TerminalSettings.load(destination.terminalSettings).fontSize, 12, "staging must wait for launch")
            let restored = AppModel(dirs: destination, theme: AppTheme(systemIsDark: true))
            XCTAssertTrue(restored.loadProblems.isEmpty, restored.loadProblems.joined(separator: "\n"))
            XCTAssertEqual(restored.settings, expectedSettings)
            XCTAssertEqual(restored.terminalSettings, terminal)
            XCTAssertEqual(try JSONDecoder().decode(ServerSettingsDoc.self, from: Data(contentsOf: destination.serverSettings)), serverSettings)
            XCTAssertEqual(try Data(contentsOf: destination.themes.appendingPathComponent("Custom")), archive.files["themes/Custom"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.themes.appendingPathComponent("Old").path))
            XCTAssertFalse(BackupArchive.hasPending(destination))
            let backups = try FileManager.default.contentsOfDirectory(at: destination.backups, includingPropertiesForKeys: nil)
            XCTAssertEqual(backups.count, 1)
            let recovery = try XCTUnwrap(backups.first)
            for (name, data) in originals { XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(name)), data) }
            XCTAssertEqual(try String(contentsOf: recovery.appendingPathComponent("themes/Old"), encoding: .utf8), "background = 654321\n")
            let restoredProject = try XCTUnwrap(restored.state.project(matched ?? first))
            let panes = restoredProject.tabs.flatMap(\.panes)
            XCTAssertEqual(panes.map(\.title), ["Saved main", "Saved split"])
            XCTAssertTrue(panes.allSatisfy { !originalPanes.contains($0.id) && $0.content.session == nil && !$0.proxy })
            XCTAssertEqual(restoredProject.tabs.first?.layout, .split(axis: .vertical, ratio: 0.3,
                                                                     first: .leaf(panes[0].id), second: .leaf(panes[1].id)))
            XCTAssertEqual(restored.terminalFontSizes[try XCTUnwrap(panes.first).id.description], 27)
            XCTAssertNotNil(restored.state.project(second))
            if let kept { XCTAssertNotNil(restored.state.project(kept)) }
            if let matched {
                XCTAssertNotEqual(matched, first)
                XCTAssertNil(restored.state.project(first))
            }
            XCTAssertTrue(restored.state.projects.allSatisfy { $0.serverId.isLocal })
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.proxy.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.root.appendingPathComponent("remote.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.root.appendingPathComponent("sessions/live").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.root.appendingPathComponent("project-one/source.swift").path))
            let relaunched = AppModel(dirs: destination, theme: AppTheme(systemIsDark: true))
            XCTAssertEqual(relaunched.state, restored.state)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.backups.path).count, 1)
        }
    }
}
