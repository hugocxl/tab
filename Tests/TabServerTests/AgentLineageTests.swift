import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabServer

/// A provider that works until the test says how its turn ends.
private final class TreeBox: @unchecked Sendable {
    var tree: [pid_t: AgentCallers.Process]
    init(_ tree: [pid_t: AgentCallers.Process]) { self.tree = tree }
}

private final class LineageRuntime: AgentSessionRuntime, @unchecked Sendable {
    let callback: @Sendable (AgentRuntimeEvent) -> Void
    private let lock = NSLock()
    private var sent: [String] = []
    var texts: [String] { lock.withLock { sent } }

    init(_ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void) { self.callback = callback }

    func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
        lock.withLock { sent.append(text) }
    }
    func steer(text: String, attachments: [StagedAgentAttachment]) async throws {
        lock.withLock { sent.append(text) }
    }
    func approve(request: String, allow: Bool) async throws { callback(.status(.working)) }
    func setAccess(_ mode: AgentAccessMode) async throws {}
    func interrupt() async throws { callback(.status(.idle)) }
    func stop() {}

    /// Ends the turn with `reply`.
    func finish(_ reply: String) {
        callback(.item(AgentChatItem(id: UUID().uuidString, kind: .assistant, text: reply)))
        callback(.status(.idle))
    }

    /// Asks the user to approve running `tool`.
    func ask(_ tool: String) {
        callback(.item(AgentChatItem(id: "approval-" + tool, kind: .approval, text: tool, isComplete: false)))
        callback(.status(.waiting))
    }
}

/// Each conversation's runtime, found by the `TAB_AGENT_ID` it was launched with.
private final class LineageRuntimes: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: LineageRuntime] = [:]
    private var byAgent: [SessionId: LineageRuntime] = [:]

    func runtime(_ agent: SessionId) -> LineageRuntime? { lock.withLock { byAgent[agent] } }

    func make(_ callback: @escaping @Sendable (AgentRuntimeEvent) -> Void) -> any AgentSessionRuntime {
        let runtime = LineageRuntime(callback)
        return Prepared(runtime: runtime) { [self] agent in lock.withLock { byAgent[agent] = runtime } }
    }

    /// Learns which conversation a runtime serves from the launch Tab prepares it with.
    private struct Prepared: AgentSessionRuntime {
        let runtime: LineageRuntime
        let named: @Sendable (SessionId) -> Void
        func send(text: String, model: String?, reasoningEffort: AgentReasoningEffort?) async throws {
            try await runtime.send(text: text, model: model, reasoningEffort: reasoningEffort)
        }
        func steer(text: String, attachments: [StagedAgentAttachment]) async throws {
            try await runtime.steer(text: text, attachments: attachments)
        }
        func approve(request: String, allow: Bool) async throws { try await runtime.approve(request: request, allow: allow) }
        func setAccess(_ mode: AgentAccessMode) async throws {}
        func interrupt() async throws { try await runtime.interrupt() }
        func stop() {}
        func prepare(_ launch: AgentLaunch) {
            if let agent = launch.environment["TAB_AGENT_ID"].flatMap(SessionId.init(string:)) { named(agent) }
        }
    }
}

final class AgentLineageTests: XCTestCase {
    // MARK: Access and parents

    func testAgentsStartChildrenWithTheirOwnAccessAndNeverMore() async throws {
        let (sessions, _) = try make()
        let parent = try await create(sessions)
        let read1 = try await sessions.handle(.read(session: parent))
        XCTAssertNil(read1.parent)
        let read2 = try await sessions.handle(.read(session: parent))
        XCTAssertEqual(read2.accessMode, .fullAccess,
                       "Conversations the user starts keep their Full access default")
        _ = try await sessions.handle(.setAccess(session: parent, mode: .standard))

        let child = try await create(sessions, caller: parent)
        let started = try await sessions.handle(.read(session: child))
        XCTAssertEqual(started.parent, parent)
        XCTAssertEqual(started.accessMode, .standard, "A child inherits its parent's access")

        let asking = try await create(sessions, caller: parent, options: AgentStartOptions(model: "small", accessMode: .ask))
        let narrowed = try await sessions.handle(.read(session: asking))
        XCTAssertEqual(narrowed.accessMode, .ask)
        XCTAssertEqual(narrowed.model, "small")

        await assertRefused("more access than the agent asking") {
            _ = try await self.create(sessions, caller: parent, options: AgentStartOptions(accessMode: .fullAccess))
        }
        await assertRefused("raising a child above its parent") {
            _ = try await sessions.handle(.setAccess(session: child, mode: .fullAccess), caller: parent)
        }
        await assertRefused("raising itself") {
            _ = try await sessions.handle(.setAccess(session: parent, mode: .fullAccess), caller: parent)
        }
        _ = try await sessions.handle(.setAccess(session: child, mode: .ask), caller: parent)
        let read3 = try await sessions.handle(.read(session: child))
        XCTAssertEqual(read3.accessMode, .ask, "Lowering a child is fine")
    }

    func testAnAgentsForkIsItsChildWithAtMostItsAccess() async throws {
        let (sessions, _) = try make()
        let source = try await create(sessions)  // Full access, the user's.
        let agent = try await create(sessions)
        _ = try await sessions.handle(.setAccess(session: agent, mode: .ask))
        let fork = try await sessions.handle(.fork(session: SessionId(), from: source), caller: agent)
        XCTAssertEqual(fork.parent, agent, "Whoever forks owns the fork, whatever the source")
        XCTAssertEqual(fork.accessMode, .ask)

        let userFork = try await sessions.handle(.fork(session: SessionId(), from: fork.session))
        XCTAssertNil(userFork.parent, "A fork the user makes belongs to no agent, though its source did")
    }

    func testAgentsCantDriveApproveOrManageWhatIsntTheirs() async throws {
        let (sessions, _) = try make()
        let strong = try await create(sessions)  // Full access.
        let weak = try await create(sessions)
        _ = try await sessions.handle(.setAccess(session: weak, mode: .standard))
        let stranger = try await create(sessions)
        _ = try await sessions.handle(.setAccess(session: stranger, mode: .ask))

        await assertRefused("giving work to an agent with more access") {
            _ = try await sessions.handle(.send(session: strong, text: "rm -rf", model: nil), caller: weak)
        }
        await assertRefused("queueing work for it") {
            _ = try await sessions.handle(.submit(session: strong, prompt: AgentPrompt(text: "x", model: nil, effort: nil,
                                                                                       provider: .claude, planMode: false)),
                                          caller: weak)
        }
        await assertRefused("approving for any agent, even its own child") {
            let child = try await self.create(sessions, caller: weak)
            _ = try await sessions.handle(.approve(session: child, request: "r", allow: true), caller: weak)
        }
        await assertRefused("stopping an agent it didn't start") {
            _ = try await sessions.handle(.stop(session: stranger, descendants: true), caller: weak)
        }
        await assertRefused("closing an agent it didn't start") {
            _ = try await sessions.handle(.close(session: stranger), caller: weak)
        }
        await assertRefused("reverting files for the user") {
            _ = try await sessions.conversation(.revert(session: stranger, checkpoint: UUID().uuidString, paths: nil, force: false),
                                                caller: weak)
        }
        // Reading anything, and giving work to an agent with no more access, stay open.
        _ = try await sessions.handle(.read(session: strong), caller: weak)
        _ = try await sessions.handle(.send(session: stranger, text: "Look at this", model: nil), caller: weak)
        _ = try await sessions.handle(.send(session: strong, text: "Anything", model: nil))
    }

    func testTreesStopGrowingAtTheirLimits() async throws {
        let (sessions, _) = try make()
        var caller = try await create(sessions)
        for _ in 1 ..< AgentSessions.maxLineageDepth { caller = try await create(sessions, caller: caller) }
        await assertRefused("nesting deeper", code: .badRequest) {
            _ = try await self.create(sessions, caller: caller)
        }

        let busy = try await create(sessions)
        var children: [SessionId] = []
        for _ in 0 ..< AgentSessions.maxOpenChildren { children.append(try await create(sessions, caller: busy)) }
        await assertRefused("too many open at once", code: .badRequest) {
            _ = try await self.create(sessions, caller: busy)
        }
        _ = try await sessions.handle(.close(session: children[0]), caller: busy)
        _ = try await create(sessions, caller: busy)
    }

    // MARK: Stop

    func testStopReachesTheWholeTreeWithoutReportingToWhoStoppedIt() async throws {
        let (sessions, runtimes) = try make()
        let root = try await create(sessions)
        let child = try await create(sessions, caller: root)
        let grandchild = try await create(sessions, caller: child)
        let bystander = try await create(sessions)
        for (id, caller) in [(root, nil), (child, root), (grandchild, child), (bystander, nil)] as [(SessionId, SessionId?)] {
            _ = try await sessions.handle(.send(session: id, text: "Work", model: nil), caller: caller)
        }
        _ = try await sessions.handle(.stop(session: child, descendants: true), caller: root)
        for id in [child, grandchild] {
            let stopped = try await until(sessions, id) { $0.status == .idle }
            XCTAssertEqual(stopped.turns?.last?.outcome, .interrupted)
            XCTAssertEqual(stopped.queuePaused, true, "Stop holds the queue, as Stop in the pane does")
        }
        let read4 = try await sessions.handle(.read(session: root))
        XCTAssertEqual(read4.status, .working)
        let read5 = try await sessions.handle(.read(session: bystander))
        XCTAssertEqual(read5.status, .working)
        // Long enough for a report to be queued, had one been due.
        try await Task.sleep(for: .milliseconds(200))
        let read6 = try await sessions.handle(.read(session: root))
        XCTAssertEqual(read6.queuedPrompts ?? [], [])
        let read7 = try await sessions.handle(.read(session: child))
        XCTAssertEqual(read7.queuedPrompts ?? [], [])
        XCTAssertEqual(runtimes.runtime(root)?.texts, ["Work"])
    }

    func testStopOnlyLeavesTheTreeBelowRunning() async throws {
        let (sessions, _) = try make()
        let parent = try await create(sessions)
        let child = try await create(sessions, caller: parent)
        _ = try await sessions.handle(.send(session: parent, text: "Work", model: nil))
        _ = try await sessions.handle(.send(session: child, text: "Work", model: nil), caller: parent)
        _ = try await sessions.handle(.stop(session: parent, descendants: false))
        _ = try await until(sessions, parent) { $0.status == .idle }
        let read8 = try await sessions.handle(.read(session: child))
        XCTAssertEqual(read8.status, .working)
    }

    // MARK: Reports

    func testWorkTheParentAskedForIsReportedBackAsATurnNobodyTyped() async throws {
        let (sessions, runtimes) = try make()
        let parent = try await create(sessions)
        let child = try await create(sessions, caller: parent)
        _ = try await sessions.handle(.send(session: child, text: "Find the slow query", model: nil), caller: parent)
        try XCTUnwrap(runtimes.runtime(child)).finish("It's the N+1 in OrdersController.")

        let reported = try await until(sessions, parent) { $0.items.contains(where: \.isAgentReport) }
        let report = try XCTUnwrap(reported.items.first(where: \.isAgentReport))
        XCTAssertTrue(report.isAutomaticTurn)
        XCTAssertTrue(report.text.contains(child.description))
        XCTAssertTrue(report.text.contains("finished."))
        XCTAssertTrue(report.text.contains("It's the N+1 in OrdersController."))
        XCTAssertEqual(reported.status, .working, "The report starts the idle parent's next turn")
        for _ in 0 ..< 100 where runtimes.runtime(parent)?.texts.isEmpty != false { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(runtimes.runtime(parent)?.texts, [report.text], "The parent's provider gets the report itself")

        // The same outcome is never reported twice.
        try await Task.sleep(for: .milliseconds(200))
        let read9 = try await sessions.handle(.read(session: parent))
        XCTAssertEqual(read9.items.filter(\.isAgentReport).count, 1)
    }

    func testABusyParentGetsOneReportPerChildHoldingItsLatestOutcome() async throws {
        let (sessions, runtimes) = try make()
        let parent = try await create(sessions)
        let child = try await create(sessions, caller: parent)
        _ = try await sessions.handle(.send(session: parent, text: "Coordinate", model: nil))
        _ = try await sessions.handle(.send(session: child, text: "Deploy", model: nil), caller: parent)

        try XCTUnwrap(runtimes.runtime(child)).ask("Bash")
        let blocked = try await until(sessions, parent) { $0.queuedPrompts?.count == 1 }
        XCTAssertTrue(try XCTUnwrap(blocked.queuedPrompts?.first).text.contains("waiting for the user to approve Bash"))

        _ = try await sessions.handle(.approve(session: child, request: "approval-Bash", allow: true))
        try XCTUnwrap(runtimes.runtime(child)).finish("Deployed.")
        let finished = try await until(sessions, parent) { $0.queuedPrompts?.first?.text.contains("Deployed.") == true }
        XCTAssertEqual(finished.queuedPrompts?.count, 1, "A newer outcome replaces the report still queued")

        try XCTUnwrap(runtimes.runtime(parent)).finish("Waiting on the deploy.")
        let delivered = try await until(sessions, parent) {
            $0.items.contains(where: \.isAgentReport) && ($0.queuedPrompts ?? []).isEmpty
        }
        XCTAssertEqual(delivered.items.filter(\.isAgentReport).count, 1)
        XCTAssertEqual(delivered.queuedPrompts ?? [], [])
    }

    func testAnAgentWaitingOnItsOwnAgentsReportsOnlyWhenItIsDone() async throws {
        let (sessions, runtimes) = try make()
        let top = try await create(sessions)
        let middle = try await create(sessions, caller: top)
        _ = try await sessions.handle(.send(session: top, text: "Coordinate", model: nil))
        _ = try await sessions.handle(.send(session: middle, text: "Split the migration", model: nil), caller: top)
        let bottom = try await create(sessions, caller: middle)
        _ = try await sessions.handle(.send(session: bottom, text: "Migrate the users table", model: nil), caller: middle)

        // The middle agent ends its turn to wait on its own: that isn't finishing.
        try XCTUnwrap(runtimes.runtime(middle)).finish("Started one agent; waiting for it.")
        _ = try await until(sessions, middle) { $0.status == .idle }
        try await Task.sleep(for: .milliseconds(200))
        let waiting = try await sessions.handle(.read(session: top))
        XCTAssertEqual(waiting.queuedPrompts ?? [], [], "No report while its agent works for it")

        // Its agent's report starts its next turn; ending that one is finishing.
        try XCTUnwrap(runtimes.runtime(bottom)).finish("Users table migrated.")
        _ = try await until(sessions, middle) { $0.items.contains(where: \.isAgentReport) && $0.status == .working }
        try XCTUnwrap(runtimes.runtime(middle)).finish("The migration is done.")
        let reported = try await until(sessions, top) { $0.queuedPrompts?.count == 1 }
        XCTAssertTrue(try XCTUnwrap(reported.queuedPrompts?.first).text.contains("The migration is done."))
    }

    func testCollectingTheChildFirstWithdrawsItsReport() async throws {
        let (sessions, runtimes) = try make()
        let parent = try await create(sessions)
        let child = try await create(sessions, caller: parent)
        _ = try await sessions.handle(.send(session: parent, text: "Coordinate", model: nil))
        _ = try await sessions.handle(.send(session: child, text: "Check", model: nil), caller: parent)
        try XCTUnwrap(runtimes.runtime(child)).finish("All green.")
        _ = try await until(sessions, parent) { $0.queuedPrompts?.count == 1 }

        // Another agent collecting it, or the parent only reading it, as to send it more,
        // changes nothing; the parent collecting it is the news.
        let other = try await create(sessions)
        _ = try await sessions.handle(.collect(session: child), caller: other)
        _ = try await sessions.handle(.read(session: child), caller: parent)
        let kept = try await sessions.handle(.read(session: parent))
        XCTAssertEqual(kept.queuedPrompts?.count, 1)
        _ = try await sessions.handle(.collect(session: child), caller: parent)
        let withdrawn = try await sessions.handle(.read(session: parent))
        XCTAssertEqual(withdrawn.queuedPrompts ?? [], [])
    }

    func testAPromptTheParentQueuedIsReportedWhenItsTurnEndsNotBefore() async throws {
        let (sessions, runtimes) = try make()
        let parent = try await create(sessions)
        let child = try await create(sessions, caller: parent)
        _ = try await sessions.handle(.send(session: parent, text: "Coordinate", model: nil))
        _ = try await sessions.handle(.send(session: child, text: "My own task", model: nil))
        _ = try await sessions.handle(.submit(session: child, prompt: AgentPrompt(text: "The parent's task", model: nil, effort: nil,
                                                                                  provider: .claude, planMode: false)),
                                      caller: parent)
        // The user's turn ends; the parent's prompt starts next. Neither is news yet.
        try XCTUnwrap(runtimes.runtime(child)).finish("Mine is done.")
        _ = try await until(sessions, child) { $0.status == .working && ($0.queuedPrompts ?? []).isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        let quiet = try await sessions.handle(.read(session: parent))
        XCTAssertEqual(quiet.queuedPrompts ?? [], [], "The user's turn isn't reported to the parent")

        try XCTUnwrap(runtimes.runtime(child)).finish("Yours is done.")
        let reported = try await until(sessions, parent) { $0.queuedPrompts?.count == 1 }
        XCTAssertTrue(try XCTUnwrap(reported.queuedPrompts?.first).text.contains("Yours is done."))
    }

    func testAParentSendThatFailsOwesNoReport() async throws {
        let (sessions, runtimes) = try make()
        let parent = try await create(sessions)
        let child = try await create(sessions, caller: parent)
        _ = try await sessions.handle(.send(session: parent, text: "Coordinate", model: nil))
        _ = try await sessions.handle(.send(session: child, text: "Mine", model: nil))
        // A model change can't join the running turn, so the parent's message is refused.
        do {
            _ = try await sessions.handle(.send(session: child, text: "Switch", model: "other"), caller: parent)
            XCTFail("A model change mid-turn is refused")
        } catch {}
        try XCTUnwrap(runtimes.runtime(child)).finish("Done with mine.")
        _ = try await until(sessions, child) { $0.status == .idle }
        try await Task.sleep(for: .milliseconds(200))
        let quiet = try await sessions.handle(.read(session: parent))
        XCTAssertEqual(quiet.queuedPrompts ?? [], [])
    }

    func testAgentsShortOfFullAccessTypeOnlyIntoTheirOwnTerminals() async throws {
        let (sessions, _) = try make()
        let full = try await create(sessions)
        let auto = try await create(sessions)
        _ = try await sessions.handle(.setAccess(session: auto, mode: .standard))
        let child = try await create(sessions, caller: auto)
        XCTAssertTrue(sessions.mayType(full, into: nil), "Full access may run anything anyway")
        XCTAssertFalse(sessions.mayType(auto, into: nil), "Not into the user's terminals")
        XCTAssertFalse(sessions.mayType(auto, into: full))
        XCTAssertTrue(sessions.mayType(auto, into: auto))
        XCTAssertTrue(sessions.mayType(auto, into: child), "Into a terminal an agent below it started")
        XCTAssertFalse(sessions.mayType(child, into: auto), "But not the other way up")
    }

    func testClearingAChildKeepsItInItsTree() async throws {
        let (sessions, _) = try make()
        let parent = try await create(sessions)
        let child = try await create(sessions, caller: parent)
        let current = try await sessions.handle(.read(session: child))
        let cleared = try await sessions.handle(.clear(session: child, archive: SessionId(), expectedRevision: current.revision),
                                                caller: parent)
        XCTAssertEqual(cleared.parent, parent)
        _ = try await sessions.handle(.stop(session: child, descendants: true), caller: parent)
    }

    func testWorkTheUserGivesAChildIsntReported() async throws {
        let (sessions, runtimes) = try make()
        let parent = try await create(sessions)
        let child = try await create(sessions, caller: parent)
        _ = try await sessions.handle(.send(session: child, text: "Something of my own", model: nil))
        try XCTUnwrap(runtimes.runtime(child)).finish("Done.")
        _ = try await until(sessions, child) { $0.status == .idle }
        try await Task.sleep(for: .milliseconds(200))
        let unchanged = try await sessions.handle(.read(session: parent))
        XCTAssertFalse(unchanged.items.contains(where: \.isAgentReport))
        XCTAssertEqual(unchanged.queuedPrompts ?? [], [])
    }

    func testAReportOwedWhenTheServerStoppedIsQueuedAfterRestart() async throws {
        let root = try temporaryRoot()
        let runtimes = LineageRuntimes()
        let first = try AgentSessions(root: root, projectDirectory: { _ in root.path },
                                      factory: { _, _, _, callback in runtimes.make(callback) })
        let parent = try await create(first)
        let child = try await create(first, caller: parent)
        _ = try await first.handle(.send(session: parent, text: "Coordinate", model: nil))
        _ = try await first.handle(.send(session: child, text: "Long job", model: nil), caller: parent)
        first.shutdown()

        let second = try AgentSessions(root: root, projectDirectory: { _ in root.path },
                                       factory: { _, _, _, callback in runtimes.make(callback) })
        defer { second.shutdown() }
        let loaded = try await second.handle(.read(session: parent))
        XCTAssertEqual(loaded.queuedPrompts ?? [], [], "Nothing is queued before the server is set up")
        second.reportWorkEndedByRestart()
        let recovered = try await until(second, parent) { $0.queuedPrompts?.count == 1 }
        let report = try XCTUnwrap(recovered.queuedPrompts?.first)
        XCTAssertTrue(report.text.contains("failed: Agent interrupted when the server stopped"))
        XCTAssertEqual(recovered.status, .failed, "A parent the restart stopped waits for the user, report and all")
        let reloadedChild = try await second.handle(.read(session: child))
        XCTAssertEqual(reloadedChild.parent, parent)
    }

    func testTheSidebarShowsAParentWorkingUntilItsChildrenReport() async throws {
        let (sessions, runtimes) = try make()
        let parent = try await create(sessions)
        let child = try await create(sessions, caller: parent)
        _ = try await sessions.handle(.send(session: child, text: "Index the repo\nthoroughly", model: nil), caller: parent)
        let listed = sessions.queue.sync { sessions.activitySnapshot(try! XCTUnwrap(sessions.entries[parent])) }
        let tab = try XCTUnwrap(listed.subagents?.first)
        XCTAssertEqual(tab.agentType, AgentSessions.tabAgentType)
        XCTAssertEqual(tab.status, .running)
        XCTAssertEqual(tab.description, "Index the repo")
        XCTAssertEqual(Activity.chatState(listed).0, .working, "An idle parent waits on its child")

        try XCTUnwrap(runtimes.runtime(child)).finish("Indexed.")
        _ = try await until(sessions, parent) { $0.items.contains(where: \.isAgentReport) && ($0.queuedPrompts ?? []).isEmpty }
        let after = sessions.queue.sync { sessions.activitySnapshot(try! XCTUnwrap(sessions.entries[parent])) }
        XCTAssertNil(after.subagents, "Delivered, the report takes the child off the list")
    }

    // MARK: Callers

    func testCallersAreFoundFromTheProcessTreeBelowTheServer() {
        // 900 → 800 → 700 (the agent's provider) → 600 → 100 (the server)
        let box = TreeBox([
            900: .init(parent: 800, started: timeval(tv_sec: 9, tv_usec: 0)),
            800: .init(parent: 700, started: timeval(tv_sec: 8, tv_usec: 0)),
            700: .init(parent: 600, started: timeval(tv_sec: 7, tv_usec: 0)),
            600: .init(parent: 100, started: timeval(tv_sec: 6, tv_usec: 0)),
            100: .init(parent: 1, started: timeval(tv_sec: 1, tv_usec: 0)),
        ])
        let callers = AgentCallers(describe: { box.tree[$0] })
        let agent = SessionId()
        callers.register(700, agent: agent)
        XCTAssertEqual(callers.agent(for: 900, below: 100), agent)
        XCTAssertEqual(callers.agent(for: 700, below: 100), agent)
        XCTAssertNil(callers.agent(for: 600, below: 100), "Not below the agent")
        // A server an agent happened to start doesn't make everything below it the agent's.
        XCTAssertNil(callers.agent(for: 900, below: 800))

        // The provider exited and the kernel gave its PID to an unrelated process.
        box.tree[700] = .init(parent: 600, started: timeval(tv_sec: 70, tv_usec: 0))
        XCTAssertNil(callers.agent(for: 900, below: 100), "A reused PID isn't the agent")

        let other = SessionId()
        callers.register(700, agent: other)  // Tab started another agent on that PID.
        callers.unregister(700, agent: agent)  // The first owner's late cleanup.
        XCTAssertEqual(callers.agent(for: 900, below: 100), other)
        callers.unregister(700, agent: other)
        XCTAssertNil(callers.agent(for: 900, below: 100))
    }

    func testCallersFollowTheKernelsProcessTree() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate() }
        XCTAssertEqual(AgentCallers.process(process.processIdentifier)?.parent, getpid())
        let callers = AgentCallers()
        let agent = SessionId()
        callers.register(getpid(), agent: agent)
        XCTAssertEqual(callers.agent(for: process.processIdentifier, below: 0), agent)
        XCTAssertNil(AgentCallers().agent(for: process.processIdentifier, below: 0))
    }

    func testSocketPeersAreTheConnectingProcess() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        XCTAssertEqual(AgentCallers.peer(of: pair[0]), getpid())
    }

    // MARK: Helpers

    private func make() throws -> (AgentSessions, LineageRuntimes) {
        let root = try temporaryRoot()
        let runtimes = LineageRuntimes()
        let sessions = try AgentSessions(root: root, projectDirectory: { _ in root.path },
                                         factory: { _, _, _, callback in runtimes.make(callback) })
        addTeardownBlock { sessions.shutdown() }
        return (sessions, runtimes)
    }

    private func create(_ sessions: AgentSessions, caller: SessionId? = nil,
                        options: AgentStartOptions? = nil) async throws -> SessionId {
        let id = SessionId()
        _ = try await sessions.handle(.create(session: id, project: ProjectId(), provider: .claude, options: options),
                                      caller: caller)
        return id
    }

    /// `session`'s snapshot once `condition` holds, failing after two seconds.
    private func until(_ sessions: AgentSessions, _ session: SessionId,
                       _ condition: (AgentChatSnapshot) -> Bool) async throws -> AgentChatSnapshot {
        var snapshot = try await sessions.handle(.read(session: session))
        for _ in 0 ..< 100 where !condition(snapshot) {
            try await Task.sleep(for: .milliseconds(20))
            snapshot = try await sessions.handle(.read(session: session))
        }
        XCTAssertTrue(condition(snapshot), "condition never held")
        return snapshot
    }

    private func assertRefused(_ what: String, code: ErrorCode = .unauthorized,
                               _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("Should refuse \(what)")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, code, what)
        } catch {
            XCTFail("Refused \(what) with \(error)")
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lineage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
