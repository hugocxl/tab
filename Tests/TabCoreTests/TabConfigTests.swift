import XCTest
import TabProtocol
@testable import TabCore

/// The hand-edited `settings.json` of `~/.config/tab` and a project's `.config/tab`.
final class TabConfigTests: XCTestCase {
    func testAFileParsesEveryShapeSkipsBlankCommandsAndIgnoresUnknownKeys() throws {
        let config = try TabConfig.parse(Data(#"""
            {"defaultBranch": {"name": " develop ", "open": ["  npm ci  ", " "], "future": true},
             "worktrees": {"location": "../{base-dir}.{branch}",
                           "open": [{"name": "Start", "command": "docker compose up -d"}],
                           "close": ["docker compose down"]},
             "someFutureSection": {"x": 1}}
            """#.utf8), project: true)
        XCTAssertEqual(config.defaultBranch.name, "develop")
        XCTAssertEqual(config.defaultBranch.commands, BranchCommands(open: [BranchCommand(command: "npm ci", project: true)]))
        XCTAssertEqual(config.worktrees.location, "../{base-dir}.{branch}")
        XCTAssertEqual(config.worktrees.commands.open, [BranchCommand(command: "docker compose up -d", name: "Start", project: true)])
        XCTAssertEqual(config.worktrees.commands.close, [BranchCommand(command: "docker compose down", project: true)])
        XCTAssertEqual(try TabConfig.parse(Data("  \n".utf8), project: false), TabConfig())
        XCTAssertEqual(try TabConfig.load("/nonexistent/settings.json", project: false), TabConfig())
    }

    func testMistakesAreRefusedNamingTheFileAndKey() {
        for (json, expected) in [
            ("{", "settings.json"),
            (#"{"worktrees":{"location":"../fixed"}}"#, "worktrees.location"),
            (#"{"worktrees":{"open":"npm ci"}}"#, "worktrees.open"),
            (#"{"defaultBranch":{"name":"-x"}}"#, "defaultBranch.name"),
            (#"{"defaultBranch":{"name":"two words"}}"#, "defaultBranch.name"),
        ] {
            XCTAssertThrowsError(try TabConfig.parse(Data(json.utf8), path: "/p/settings.json", project: true), json) {
                XCTAssertTrue("\($0)".contains(expected), "\(json): \($0)")
            }
        }
    }

    func testTheProjectWinsForValuesAndCommandsAddUpInRunOrder() {
        func command(_ text: String, _ project: Bool) -> BranchCommand { BranchCommand(command: text, project: project) }
        let user = TabConfig(
            defaultBranch: .init(name: "main", commands: BranchCommands(open: [command("u-open", false)], close: [command("u-close", false)])),
            worktrees: .init(location: "~/trees/{branch}", commands: BranchCommands(open: [command("u-wt", false)], close: [command("u-wt-close", false)])))
        let project = TabConfig(
            defaultBranch: .init(name: "develop", commands: BranchCommands(open: [command("p-open", true)], close: [command("p-close", true)])),
            worktrees: .init(commands: BranchCommands(open: [command("p-wt", true)], close: [command("p-wt-close", true)])))
        let merged = TabConfig.merge(user: user, project: project)
        XCTAssertEqual(merged.defaultBranch, "develop")
        XCTAssertEqual(merged.worktreeLocation, "~/trees/{branch}")
        XCTAssertEqual(merged.defaultBranchCommands.open.map(\.command), ["u-open", "p-open"])
        XCTAssertEqual(merged.defaultBranchCommands.close.map(\.command), ["p-close", "u-close"])
        XCTAssertEqual(merged.worktreeCommands.open.map(\.command), ["u-wt", "p-wt"])
        XCTAssertEqual(merged.worktreeCommands.close.map(\.command), ["p-wt-close", "u-wt-close"])
        XCTAssertEqual(TabConfig.merge(user: TabConfig(), project: TabConfig()), BranchSettings())
    }

    func testBothFilesAreReadFromTheirPlaces() throws {
        let directory = try TemporaryDirectory()
        let user = try directory.write("user.json", #"{"worktrees":{"location":"~/u/{branch}","open":["a"]}}"#)
        try FileManager.default.createDirectory(at: directory.file("repo/.config/tab"), withIntermediateDirectories: true)
        _ = try directory.write("repo/.config/tab/settings.json", #"{"worktrees":{"open":["b"]}}"#)
        let settings = try TabConfig.branchSettings(projectDirectory: directory.file("repo").path, userFile: user)
        XCTAssertEqual(settings.worktreeLocation, "~/u/{branch}")
        XCTAssertEqual(settings.worktreeCommands.open, [BranchCommand(command: "a", project: false), BranchCommand(command: "b", project: true)])
        XCTAssertEqual(TabConfig.userFile(environment: ["HOME": "/Users/dev"]).path, "/Users/dev/.config/tab/settings.json")
        XCTAssertEqual(TabConfig.userFile(environment: ["XDG_CONFIG_HOME": "/cfg", "HOME": "/Users/dev"]).path, "/cfg/tab/settings.json")
    }

    func testLocationsKeepTheBranchInTheFolderAndResolveLikeAPath() throws {
        for template in ["../fixed", "../{branch}/../fixed"] {
            XCTAssertThrowsError(try TabConfig.validateLocation(template), template)
        }
        XCTAssertNoThrow(try TabConfig.validateLocation("  "))
        func directory(_ location: String?) throws -> String {
            try TabConfig.worktreeDirectory(location: location, projectName: "My Project", projectDirectory: "/code/repo",
                                            branch: "feature/a", home: "/Users/dev")
        }
        XCTAssertEqual(try directory(nil), "/Users/dev/.tab/worktrees/My-Project/feature-a")
        XCTAssertEqual(try directory("  "), "/Users/dev/.tab/worktrees/My-Project/feature-a")
        XCTAssertEqual(try directory("../{base-dir}.{branch}/{project-name}"), "/code/repo.feature-a/My-Project")
        XCTAssertEqual(try directory("/trees/{branch}"), "/trees/feature-a")
        XCTAssertThrowsError(try directory("../fixed"))
        XCTAssertEqual(sanitizedComponent("feature/a b", fallback: "name"), "feature-a-b")
        XCTAssertEqual(sanitizedComponent("..", fallback: "name"), "name")
    }

    func testSavingTheLocationKeepsTheRestOfTheFileAndNeverOverwritesABrokenOne() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("config/tab/settings.json")
        try TabConfig.setWorktreeLocation("../{base-dir}.{branch}", in: url)
        XCTAssertEqual(try TabConfig.worktreeLocation(in: url), "../{base-dir}.{branch}")
        _ = try directory.write("config/tab/settings.json", #"{"defaultBranch":{"name":"main"},"worktrees":{"open":["npm ci"],"location":"~/a/{branch}"},"later":1}"#)
        try TabConfig.setWorktreeLocation("~/b/{branch}", in: url)
        var config = try TabConfig.load(url.path, project: false)
        XCTAssertEqual(config.worktrees.location, "~/b/{branch}")
        XCTAssertEqual(config.worktrees.commands.open.map(\.command), ["npm ci"])
        XCTAssertEqual(config.defaultBranch.name, "main")
        try TabConfig.setWorktreeLocation(" ", in: url)
        config = try TabConfig.load(url.path, project: false)
        XCTAssertNil(config.worktrees.location)
        XCTAssertEqual(config.worktrees.commands.open.map(\.command), ["npm ci"])
        XCTAssertTrue(try directory.read("config/tab/settings.json").contains(#""later" : 1"#))
        XCTAssertThrowsError(try TabConfig.setWorktreeLocation("../fixed", in: url))
        _ = try directory.write("config/tab/settings.json", "{ broken")
        XCTAssertThrowsError(try TabConfig.setWorktreeLocation("~/c/{branch}", in: url))
        XCTAssertEqual(try directory.read("config/tab/settings.json"), "{ broken")
    }
}
