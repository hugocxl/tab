import TabProtocol
import XCTest
@testable import TabMobileKit

/// The card titles follow the desktop sidebar's reading of terminal titles.
@MainActor
final class TabListingTests: XCTestCase {
    func testIdleShellTitlesNameTheirFolder() {
        XCTAssertEqual(ServerModel.idleDirectory("~/repos/tabios"), "tabios")
        XCTAssertEqual(ServerModel.idleDirectory("hugo@mac:~/code/app/"), "app")
        XCTAssertEqual(ServerModel.idleDirectory("(mac) /usr/local"), "local")
        XCTAssertEqual(ServerModel.idleDirectory("/"), "/")
        XCTAssertNil(ServerModel.idleDirectory("npm run dev"))
        XCTAssertNil(ServerModel.idleDirectory("~/a b"))
    }

    func testIdleShellsKeepTheirFullFolder() {
        XCTAssertEqual(ServerModel.idlePath("hugo@mac:~/code/app/"), "~/code/app")
        XCTAssertEqual(ServerModel.idlePath("(mac) /usr/local"), "/usr/local")
        XCTAssertNil(ServerModel.idlePath("npm run dev"))
    }

    /// The title row stands for a lone pane, else the most pressing one, else
    /// the one the title names, without the folders and times its rows show.
    func testCardLeadIsTheMostPressingPane() {
        func row(_ title: String, _ status: CardPane.Status = .idle) -> CardPane {
            CardPane(id: PaneId(), icon: .bash, hue: .green, title: title, detail: "~/repos", status: status,
                     workingSince: status == .idle ? nil : Date(), topic: .command(title))
        }
        let lone = row("htop")
        XCTAssertEqual(TabCard.lead(rows: [lone], title: "htop"), lone)
        let working = row("build", .working)
        let blocked = row("deploy", .blocked)
        let lead = TabCard.lead(rows: [row("vim"), working, blocked], title: "vim")
        XCTAssertEqual(lead?.id, blocked.id)
        XCTAssertNil(lead?.detail)
        XCTAssertNil(lead?.workingSince)
        let named = row("tests")
        XCTAssertEqual(TabCard.lead(rows: [row("vim"), named], title: "tests")?.id, named.id)
        XCTAssertNil(TabCard.lead(rows: [], title: "Empty tab"))
    }

    func testAgentTaskDropsSpinnersAndBareNames() {
        XCTAssertEqual(ServerModel.taskTitle("✳ Fix the login bug", provider: .claude), "Fix the login bug")
        XCTAssertNil(ServerModel.taskTitle("✳ Claude Code", provider: .claude))
    }

    func testChatOpeningMessagesBecomeTitles() {
        XCTAssertEqual(ServerModel.chatTopic("can you write a lorem ipsum? thanks"), "Write a lorem ipsum")
        XCTAssertEqual(ServerModel.chatTopic("hey, please fix the login bug.\nmore"), "Fix the login bug")
        XCTAssertNil(ServerModel.chatTopic("hi"))
        XCTAssertEqual(ServerModel.command("htop — ~/repos"), "htop")
    }

    /// The card's title follows the desktop: a custom title, the lead agent's
    /// task, a worktree's branch, then the best other topic.
    func testCardTitlePrefersTheLeadAgent() {
        func row(_ title: String, _ topic: CardPane.Topic?, _ status: CardPane.Status = .idle) -> CardPane {
            CardPane(id: PaneId(), icon: .bash, hue: .green, title: title, status: status, topic: topic)
        }
        let shell = row("zsh", .folder("tabios"))
        let server = row("npm run dev", .command("npm run dev"))
        let idle = row("Write docs", .task("Write docs"))
        let waiting = row("Fix the build", .task("Fix the build"), .blocked)
        XCTAssertEqual(ServerModel.title(rows: [shell, idle, waiting], customTitle: nil, branch: "wt-1"), "Fix the build")
        XCTAssertEqual(ServerModel.title(rows: [shell, idle], customTitle: " Release ", branch: nil), "Release")
        XCTAssertEqual(ServerModel.title(rows: [shell, server], customTitle: nil, branch: "feature"), "feature")
        XCTAssertEqual(ServerModel.title(rows: [shell, server], customTitle: nil, branch: nil), "npm run dev")
        XCTAssertEqual(ServerModel.title(rows: [shell], customTitle: nil, branch: nil), "zsh")
        XCTAssertEqual(ServerModel.title(rows: [], customTitle: nil, branch: nil), "Empty tab")
        // A failed agent leads like one waiting for you.
        let failed = row("Ship it", .task("Ship it"), .error)
        XCTAssertEqual(ServerModel.title(rows: [idle, failed], customTitle: nil, branch: nil), "Ship it")
    }

    /// As on the desktop, a terminal shows a spinner while a program works on
    /// its own, not while one waits for typing.
    func testTerminalsRunCommandsButNotInteractivePrograms() {
        XCTAssertTrue(ServerModel.runsCommand(ForegroundProcess(name: "/usr/local/bin/npm", isShell: false)))
        XCTAssertTrue(ServerModel.runsCommand(ForegroundProcess(name: "swift-build", isShell: false)))
        XCTAssertFalse(ServerModel.runsCommand(ForegroundProcess(name: "vim", isShell: false)))
        XCTAssertFalse(ServerModel.runsCommand(ForegroundProcess(name: "-zsh", isShell: true)))
        XCTAssertFalse(ServerModel.runsCommand(ForegroundProcess(name: "claude", isShell: false)))
        XCTAssertFalse(ServerModel.runsCommand(nil))
    }

    /// Grouping by project keeps Home first, then the server's project order,
    /// with a worktree's tab under its project and the Open Tabs order within.
    func testGroupingByProjectFollowsTheProjectOrder() {
        let home = ProjectDescriptor(home: true, directory: ServerPath("/Users/me"), name: "Home")
        let app = ProjectDescriptor(directory: ServerPath("/app"), name: "app")
        let site = ProjectDescriptor(directory: ServerPath("/site"), name: "site")
        let empty = ProjectDescriptor(directory: ServerPath("/empty"), name: "empty")
        let worktree = ProjectDescriptor(directory: ServerPath("/app-wt"), name: "wt", kind: .worktree, parentId: app.id)
        func card(_ project: ProjectDescriptor, root: ProjectDescriptor?) -> TabCard {
            TabCard(server: ServerId(), project: project, tab: Tab(pane: Pane(content: .terminal(session: nil))),
                    title: project.name, rows: [], primary: false, status: .idle,
                    projectName: root?.name, iconProject: root?.id, panes: [])
        }
        let cards = [card(site, root: site), card(worktree, root: app), card(home, root: nil), card(app, root: app)]
        let groups = ServerModel.groups(cards, projects: [home, app, site, empty, worktree])
        XCTAssertEqual(groups.map(\.project?.name), [nil, "app", "site"])
        XCTAssertEqual(groups[1].cards.map(\.project.name), ["wt", "app"])
        XCTAssertTrue(ServerModel.groups([], projects: [home, app]).isEmpty)
    }

    func testElapsedTimeReadsLikeTheDesktop() {
        XCTAssertEqual(ServerModel.elapsedText(43), "43s")
        XCTAssertEqual(ServerModel.elapsedText(185), "3m")
        XCTAssertEqual(ServerModel.elapsedText(3780), "1h 3m")
        XCTAssertEqual(ServerModel.secondsUntilElapsedChanges(61.5), 58.5, accuracy: 0.001)
    }

    func testTheHostThatAnsweredLastIsTriedFirst() {
        var server = PairedServer(id: ServerId(), name: "Mac", hosts: ["192.168.1.2", "100.64.0.3", "mac.local"],
                                  port: 7419, fingerprint: Data(count: 32), device: DeviceId())
        XCTAssertEqual(server.orderedHosts, ["192.168.1.2", "100.64.0.3", "mac.local"])
        server.lastHost = "100.64.0.3"
        XCTAssertEqual(server.orderedHosts, ["100.64.0.3", "192.168.1.2", "mac.local"])
        server.lastHost = "gone.local"
        XCTAssertEqual(server.orderedHosts.first, "192.168.1.2")
    }
}
