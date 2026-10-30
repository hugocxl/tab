import AppKit
import TabClient
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class BrowserPanesTests: XCTestCase {
    private func model(projects: [ProjectDescriptor] = []) async throws -> AppModel {
        let identity = ServerId()
        let home = ProjectDescriptor.home(directory: ServerPath(NSHomeDirectory()))
        let server = ModelFakeServer(identity: identity, catalog: CatalogPage(
            server: identity, home: home.id, revision: 1, projects: [home] + projects
        ))
        let model = ModelFixtures.model(try ModelFixtures.profile(), server: server)
        model.start()
        let ready = await ModelFixtures.wait { model.state.serverIdentity(.local) != nil }
        XCTAssertTrue(ready)
        return model
    }

    func testSettingsReachEveryRegisteredControllerAndCreationPersistsResolvedDefaults() async throws {
        let model = try await model()
        defer { model.connection(.local)?.disconnect() }
        let profile = try model.browserProfiles.add(named: "Work")
        let controllers = (0..<2).map { _ in
            BrowserPaneController(tabId: PaneId().description, state: BrowserPane(), host: model)
        }
        var settings = model.settings
        settings.browser.defaultProfile = profile.id
        settings.browser.homePage = "localhost:3000/start"
        settings.browser.enabled = false
        model.apply(settings: settings)
        XCTAssertEqual(model.browserProfiles.defaultProfileId, profile.id)
        XCTAssertTrue(controllers.allSatisfy { !$0.perform(.browserZoomIn) })
        XCTAssertNil(model.openBrowser(select: false))
        XCTAssertThrowsError(try model.openBrowserPane(url: nil, profile: nil, project: nil, worktree: nil, split: false)) {
            XCTAssertEqual($0.localizedDescription, "the built-in browser is disabled")
        }
        settings.browser.enabled = true
        model.apply(settings: settings)
        XCTAssertTrue(controllers.allSatisfy { $0.perform(.browserZoomIn) })
        let pane = try XCTUnwrap(model.openBrowser(select: false))
        let saved = BrowserPane(url: "http://localhost:3000/start", profile: profile.id)
        XCTAssertEqual(model.state.browser(pane), saved)
        let explicit = try XCTUnwrap(model.openBrowser(url: "about:blank", profile: "wOrK", select: false))
        XCTAssertEqual(model.state.browser(explicit), BrowserPane(url: "about:blank", profile: profile.id))
        XCTAssertNil(model.openBrowser(profile: "missing", select: false))
        let builtIn = try await model.browserAutomation.handle(command: "open", args: [
            "profile": .string("Default"), "url": .string("about:blank"),
        ])
        let builtInPane = try XCTUnwrap(builtIn.string.flatMap { PaneId($0) })
        XCTAssertEqual(model.state.browser(builtInPane)?.profile, "")
        model.saveNow()
        settings.browser.defaultProfile = ""
        settings.browser.homePage = ""
        model.apply(settings: settings)
        let restored = AppModel(dirs: model.dirs)
        XCTAssertEqual(restored.state.browser(pane), saved)
    }

    func testTargetResolutionMatchesCodeshNamesIDsCanonicalPathsFamiliesAndErrors() async throws {
        let root = URL(fileURLWithPath: try ModelFixtures.folder("targets")).resolvingSymlinksInPath().path
        let web = ProjectDescriptor(directory: ServerPath(root + "/web"), name: "web")
        let api = ProjectDescriptor(directory: ServerPath(root + "/api"), name: "api")
        let webFeature = ProjectDescriptor(directory: ServerPath(root + "/web-feature"), name: "feature", kind: .worktree, parentId: web.id)
        let apiFeature = ProjectDescriptor(directory: ServerPath(root + "/api-feature"), name: "feature", kind: .worktree, parentId: api.id)
        let duplicate = ProjectDescriptor(directory: ServerPath(root + "/duplicate"), name: "web")
        for project in [web, api, webFeature, apiFeature, duplicate] {
            try FileManager.default.createDirectory(atPath: project.directory.rawValue, withIntermediateDirectories: true)
            if project.kind == .worktree {
                try Data("gitdir: ../repo/.git/worktrees/feature\n".utf8)
                    .write(to: URL(fileURLWithPath: project.directory.rawValue + "/.git"))
            }
        }
        let model = try await model(projects: [web, api, webFeature, apiFeature, duplicate])
        defer { model.connection(.local)?.disconnect() }
        model.selectProject(webFeature.id)
        XCTAssertEqual(try model.browserProject(project: nil, worktree: nil), webFeature.id)
        XCTAssertEqual(try model.browserProject(project: api.id.description, worktree: nil), api.id)
        XCTAssertEqual(try model.browserProject(project: nil, worktree: "feature"), webFeature.id)
        XCTAssertEqual(try model.browserProject(project: "api", worktree: "feature"), apiFeature.id)
        XCTAssertEqual(try model.browserProject(project: nil, worktree: "api-feature"), apiFeature.id)
        XCTAssertEqual(try model.browserProject(project: webFeature.id.description, worktree: nil), webFeature.id)
        XCTAssertEqual(try model.browserProject(project: "api", worktree: "api"), api.id)
        let link = URL(fileURLWithPath: root + "/alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: api.directory.rawValue))
        XCTAssertEqual(try model.browserProject(project: api.directory.rawValue, worktree: nil), api.id)
        XCTAssertEqual(try model.browserProject(project: link.path, worktree: nil), api.id)
        func fails(_ project: String?, _ worktree: String?, _ message: String) {
            XCTAssertThrowsError(try model.browserProject(project: project, worktree: worktree)) {
                XCTAssertEqual($0.localizedDescription, message)
            }
        }
        fails("nope", nil, "no project named 'nope'")
        fails("web", nil, "project 'web' is ambiguous; pass its ID")
        fails(web.id.description, "missing", "no worktree named 'missing'")
        model.selectProject(model.state.home.id)
        fails(nil, "feature", "worktree 'feature' is ambiguous across projects; pass --project to disambiguate")
        XCTAssertEqual(try model.browserProject(project: nil, worktree: apiFeature.id.description), apiFeature.id)
        model.renameProject(web.id, to: "feature")
        fails(web.id.description, "feature", "worktree 'feature' is ambiguous; pass its ID")
    }

    func testCLIOpensSelectOnlyWhenUnscopedAndSplitBesideBackgroundShownPane() async throws {
        let model = try await model()
        defer { model.connection(.local)?.disconnect() }
        let background = try XCTUnwrap(model.addProject(try ModelFixtures.folder("background")))
        model.selectProject(model.state.home.id)
        let foreground = try model.openBrowserPane(url: "about:blank", profile: nil, project: nil, worktree: nil, split: false)
        XCTAssertEqual(model.activePane?.description, foreground.tabId)
        let first = try model.openBrowserPane(url: "about:blank", profile: nil, project: background.description, worktree: nil, split: false)
        let firstId = try XCTUnwrap(PaneId(first.tabId))
        model.focusPane(firstId)
        model.selectProject(model.state.home.id)
        let second = try model.openBrowserPane(url: "about:blank", profile: nil, project: background.description, worktree: nil, split: true)
        XCTAssertEqual(model.activePane?.description, foreground.tabId)
        XCTAssertEqual(model.state.neighbor(of: firstId, .right)?.description, second.tabId)
        let tabs = try model.browserTabs(project: nil, worktree: nil)
        XCTAssertEqual(Set(tabs.filter(\.active).map(\.tabId)), [foreground.tabId, first.tabId])
        let split = try model.openBrowserPane(url: "about:blank", profile: nil, project: nil, worktree: nil, split: true)
        XCTAssertEqual(model.activePane?.description, split.tabId)
        XCTAssertEqual(model.state.neighbor(of: try XCTUnwrap(PaneId(foreground.tabId)), .right)?.description, split.tabId)
        let hidden = try model.openBrowserPane(url: "about:blank", profile: nil, project: model.state.home.id.description,
                                              worktree: nil, split: false)
        XCTAssertEqual(model.activePane?.description, split.tabId)
        XCTAssertFalse(try XCTUnwrap(model.browserTabs(project: nil, worktree: nil).first { $0.tabId == hidden.tabId }).active)
    }

    func testCatalogMenuAndPaletteActionsReachTheBrowserController() async throws {
        let model = try await model()
        defer { model.connection(.local)?.disconnect() }
        let pane = try XCTUnwrap(model.openBrowser(url: "about:blank"))
        let browser = try XCTUnwrap((model.controller(for: pane) as? BrowserPaneContent)?.controller)
        let actions = Actions(model: model)
        XCTAssertTrue(actions.perform(.browserZoomIn))
        XCTAssertGreaterThan(browser.zoom, 1)
        XCTAssertTrue(actions.perform(.browserZoomReset))
        XCTAssertEqual(browser.zoom, 1)
        XCTAssertTrue(actions.perform(.decreaseFontSize))
        XCTAssertLessThan(browser.zoom, 1)
    }
}
