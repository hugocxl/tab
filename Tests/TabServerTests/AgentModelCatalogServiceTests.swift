import Darwin
import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentModelCatalogServiceTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tab-model-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeCache(_ models: [[String: Any]], root: URL, name: String = "models_cache.json") throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["models": models]).write(to: root.appendingPathComponent(name))
    }

    private func row(_ id: String, priority: Int = 0, visibility: String = "list") -> [String: Any] {
        ["slug": id, "display_name": id.uppercased(), "priority": priority, "visibility": visibility,
         "supported_reasoning_levels": [["effort": "max"], ["effort": "ultra"], ["effort": "future"]],
         "default_reasoning_level": "ultra"]
    }

    private func launch(_ fixture: AgentRuntimeFixture) -> AgentProcess.Launch {
        .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [fixture.script.path, fixture.log.path],
              environment: AgentProcess.environment())
    }

    func testCacheFiltersVisibilitySortsPriorityAndPreservesDynamicEfforts() throws {
        let home = try root(), cache = home.appendingPathComponent(".codex")
        try writeCache([row("late", priority: 9), row("hidden", visibility: "hide"),
                        row("first", priority: 1), row("tie", priority: 1), row("first", priority: 2)], root: cache)
        let reply = try XCTUnwrap(AgentModelCatalogService.readCache(home: home, environment: [:]))
        XCTAssertEqual(reply.models.map(\.id), ["first", "tie", "late"])
        XCTAssertEqual(reply.models[0].reasoningEfforts, [.max, .ultra, .init(rawValue: "future")])
        XCTAssertEqual(reply.models[0].defaultReasoningEffort, .ultra)
        XCTAssertFalse(reply.models[0].isDefault)
        try reply.validate()
    }

    func testOnlyActiveStandardCacheAndCodexHomeAreRead() throws {
        let home = try root(), alternate = try root()
        try writeCache([row("wrong-account")], root: home.appendingPathComponent(".codex"),
                       name: "models_cache.codex_work_desktop.json")
        XCTAssertNil(AgentModelCatalogService.readCache(home: home, environment: [:]))
        try writeCache([row("active")], root: alternate)
        let reply = AgentModelCatalogService.readCache(home: home, environment: ["CODEX_HOME": alternate.path])
        XCTAssertEqual(reply?.models.map(\.id), ["active"])
    }

    func testCacheRejectsOversizedNonregularAndSymlinkFiles() throws {
        let home = try root(), cache = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent("models_cache.json")
        try Data(repeating: 32, count: AgentModelCatalogService.maxCacheBytes + 1).write(to: file)
        XCTAssertNil(AgentModelCatalogService.readCache(home: home, environment: [:]))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertNil(AgentModelCatalogService.readCache(home: home, environment: [:]))
        try FileManager.default.removeItem(at: file)
        let target = home.appendingPathComponent("target.json")
        try Data("{\"models\":[]}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertNil(AgentModelCatalogService.readCache(home: home, environment: [:]))
    }

    func testCatalogLimitsAndMalformedRows() throws {
        let rows = (0..<300).map { row("model-\($0)", priority: $0) }
        XCTAssertEqual(AgentModelCatalogService.descriptors(rows, cache: true).count, AgentModelCatalogReply.maxModels)
        var invalid = row("bad\0id")
        invalid["display_name"] = String(repeating: "x", count: 513)
        XCTAssertTrue(AgentModelCatalogService.descriptors([invalid], cache: true).isEmpty)
    }

    func testFreshCacheReturnsImmediatelyWithoutLaunchingHungCLI() async throws {
        let home = try root()
        try writeCache([row("available")], root: home.appendingPathComponent(".codex"))
        let fixture = try AgentRuntimeFixture("take\nhold")
        defer { fixture.remove() }
        let service = AgentModelCatalogService(home: home, environment: [:], launch: launch(fixture),
                                              projectDirectory: { _ in home })
        let reply = try await service.handle(.init(project: ProjectId(), provider: .codex))
        XCTAssertEqual(reply.models.map(\.id), ["available"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
    }

    func testCodexHandshakePaginationAndThirtySecondMemoryCache() async throws {
        let home = try root()
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"data":[{"id":"transport-id","model":"first","displayName":"First","supportedReasoningEfforts":[{"reasoningEffort":"ultra"}],"defaultReasoningEffort":"ultra","isDefault":true}],"nextCursor":"page-two"}}'
        take
        emit '{"id":3,"result":{"data":[{"id":"second","model":"second","supportedReasoningEfforts":[{"reasoningEffort":"future"}]}],"nextCursor":null}}'
        hold
        """)
        defer { fixture.remove() }
        let service = AgentModelCatalogService(home: home, environment: [:], launch: launch(fixture),
                                              projectDirectory: { _ in home })
        let request = AgentModelCatalogRequest(project: ProjectId(), provider: .codex)
        let reply = try await service.handle(request)
        XCTAssertEqual(reply.source, "live")
        XCTAssertEqual(reply.models.map(\.id), ["first", "second"])
        XCTAssertTrue(reply.models[0].isDefault)
        XCTAssertEqual(reply.models[1].reasoningEfforts, [.init(rawValue: "future")])
        let cached = try await service.handle(request)
        XCTAssertEqual(cached, reply)
        let sent = try fixture.messages()
        XCTAssertEqual(sent.compactMap { $0["method"] as? String }, ["initialize", "initialized", "model/list", "model/list"])
        XCTAssertEqual((sent[2]["params"] as? [String: Any])?["includeHidden"] as? Bool, false)
        XCTAssertEqual((sent[3]["params"] as? [String: Any])?["cursor"] as? String, "page-two")
        XCTAssertEqual(try fixture.launches().count, 1)
    }

    func testClaudeInitializationUsesAdvertisedAliasesCapabilitiesAndDefaultIdentity() async throws {
        let home = try root()
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{"models":[{"value":"default","resolvedModel":"claude-future"},{"value":"opus","resolvedModel":"claude-future","displayName":"Future Opus","supportsEffort":true,"supportedEffortLevels":["high","next-generation"]},{"value":"small","displayName":"Small","supportsEffort":false}]}}}'
        hold
        """)
        defer { fixture.remove() }
        let service = AgentModelCatalogService(home: home, environment: [:], launch: launch(fixture),
                                              projectDirectory: { _ in home })
        let reply = try await service.handle(.init(project: ProjectId(), provider: .claude))
        XCTAssertEqual(reply.models.map(\.id), ["opus", "small"])
        XCTAssertEqual(reply.models[0].resolvedModel, "claude-future")
        XCTAssertTrue(reply.models[0].isDefault)
        XCTAssertEqual(reply.models[0].reasoningEfforts, [.high, .init(rawValue: "next-generation")])
        XCTAssertNil(reply.models[0].defaultReasoningEffort)
        XCTAssertTrue(reply.models[1].reasoningEfforts.isEmpty)
        let sent = try fixture.messages()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual((sent[0]["request"] as? [String: Any])?["subtype"] as? String, "initialize")
    }

    func testRepeatedPaginationCursorFailsClosedInsteadOfLooping() async throws {
        let home = try root()
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"data":[{"model":"first"}],"nextCursor":"repeat"}}'
        take
        emit '{"id":3,"result":{"data":[{"model":"second"}],"nextCursor":"repeat"}}'
        hold
        """)
        defer { fixture.remove() }
        let service = AgentModelCatalogService(home: home, environment: [:], launch: launch(fixture),
                                              projectDirectory: { _ in home })
        let reply = try await service.handle(.init(project: ProjectId(), provider: .codex))
        XCTAssertTrue(reply.models.isEmpty)
        XCTAssertEqual(try fixture.messages().count, 4)
    }

    func testStaleCacheReturnsWithoutWaitingForFailedBackgroundRefresh() async throws {
        let home = try root(), cache = home.appendingPathComponent(".codex")
        try writeCache([row("offline-model")], root: cache)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: cache.appendingPathComponent("models_cache.json").path)
        let fixture = try AgentRuntimeFixture("take\nhold")
        defer { fixture.remove() }
        let service = AgentModelCatalogService(home: home, environment: [:], launch: launch(fixture), timeout: 0.2,
                                              projectDirectory: { _ in home })
        let request = AgentModelCatalogRequest(project: ProjectId(), provider: .codex)
        let start = Date()
        let reply = try await service.handle(request)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        XCTAssertEqual(reply.models.map(\.id), ["offline-model"])
        try await Task.sleep(for: .seconds(0.5))
        let retained = try await service.handle(request)
        XCTAssertEqual(retained.models, reply.models)
    }

    func testHungDiscoveryTimesOutAndKillsIgnoringTerminateProcess() async throws {
        let home = try root()
        let fixture = try AgentRuntimeFixture("""
        trap '' TERM
        printf '%s' "$$" > "$log.pid"
        take
        while :; do :; done
        """)
        defer { fixture.remove() }
        let service = AgentModelCatalogService(home: home, environment: [:], launch: launch(fixture), timeout: 0.2,
                                              projectDirectory: { _ in home })
        let start = Date()
        let reply = try await service.handle(.init(project: ProjectId(), provider: .codex))
        XCTAssertTrue(reply.models.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: fixture.log.path + ".pid", encoding: .utf8)))
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testPersistedSuccessfulCatalogIsAvailableOfflineWithoutInventedFallbacks() async throws {
        let home = try root(), saved = home.appendingPathComponent("saved")
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{"models":[{"value":"new-model","displayName":"New model","supportedEffortLevels":["future"]}]}}}'
        hold
        """)
        defer { fixture.remove() }
        let online = AgentModelCatalogService(home: home, environment: [:], launch: launch(fixture),
            cacheDirectory: saved, projectDirectory: { _ in home })
        let request = AgentModelCatalogRequest(project: ProjectId(), provider: .claude)
        let live = try await online.handle(request)
        let offline = AgentModelCatalogService(home: home, environment: ["PATH": ""],
            cacheDirectory: saved, projectDirectory: { _ in home })
        let reply = try await offline.handle(request)
        XCTAssertEqual(reply.models, live.models)
        XCTAssertEqual(reply.source, "saved")
    }

    func testForcedRefreshPropagatesNewModelsAndBypassesFreshMemory() async throws {
        let home = try root()
        let fixture = try AgentRuntimeFixture("""
        if [ -f "$log.seen" ]; then model='new'; else model='old'; fi
        touch "$log.seen"
        take
        emit '{"id":1,"result":{}}'
        take
        take
        printf '{"id":2,"result":{"data":[{"model":"%s","supportedReasoningEfforts":[{"reasoningEffort":"future"}]}]}}\n' "$model"
        hold
        """)
        defer { fixture.remove() }
        let service = AgentModelCatalogService(home: home, environment: [:], launch: launch(fixture),
                                              projectDirectory: { _ in home })
        let project = ProjectId()
        let old = try await service.handle(.init(project: project, provider: .codex))
        XCTAssertEqual(old.models.map(\.id), ["old"])
        let normal = try await service.handle(.init(project: project, provider: .codex))
        XCTAssertEqual(normal.models.map(\.id), ["old"])
        let fresh = try await service.handle(.init(project: project, provider: .codex, forceRefresh: true))
        XCTAssertEqual(fresh.models.map(\.id), ["new"])
        XCTAssertEqual(try fixture.launches().count, 2)
    }

    func testForcedTimeoutReturnsLastKnownCatalogInsteadOfEmptyResult() async throws {
        let home = try root()
        try writeCache([row("cached")], root: home.appendingPathComponent(".codex"))
        let fixture = try AgentRuntimeFixture("take\nhold")
        defer { fixture.remove() }
        let service = AgentModelCatalogService(home: home, environment: [:], launch: launch(fixture), timeout: 0.2,
                                              projectDirectory: { _ in home })
        let project = ProjectId()
        let prior = try await service.handle(.init(project: project, provider: .codex))
        let forced = try await service.handle(.init(project: project, provider: .codex, forceRefresh: true))
        XCTAssertEqual(forced.models, prior.models)
        XCTAssertEqual(try fixture.messages().count, 1)
    }

    func testExpiredLiveMemoryIsNotReplacedByOlderCLIFile() async throws {
        let home = try root()
        try writeCache([row("old-disk")], root: home.appendingPathComponent(".codex"))
        let fixture = try AgentRuntimeFixture("""
        take
        emit '{"id":1,"result":{}}'
        take
        take
        emit '{"id":2,"result":{"data":[{"model":"latest-live"}]}}'
        hold
        """)
        defer { fixture.remove() }
        let clock = ModelCatalogTestClock()
        let service = AgentModelCatalogService(home: home, environment: [:], launch: launch(fixture),
            now: { clock.now }, projectDirectory: { _ in home })
        let project = ProjectId()
        let fresh = try await service.handle(.init(project: project, provider: .codex, forceRefresh: true))
        XCTAssertEqual(fresh.models.map(\.id), ["latest-live"])
        clock.advance(31)
        let expired = try await service.handle(.init(project: project, provider: .codex))
        XCTAssertEqual(expired.models.map(\.id), ["latest-live"])
        XCTAssertEqual(expired.source, "live")
        // Join any background refresh before removing the executable fixture.
        _ = try await service.handle(.init(project: project, provider: .codex, forceRefresh: true))
    }

    func testProjectSpecificClaudeDefaultsAreIsolatedInMemoryAndPersistence() async throws {
        let home = try root(), saved = home.appendingPathComponent("saved")
        let one = home.appendingPathComponent("one"), two = home.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
        let first = ProjectId(), second = ProjectId()
        let directory: @Sendable (ProjectId) throws -> URL = { $0 == first ? one : two }
        let fixture = try AgentRuntimeFixture("""
        take
        name="${PWD##*/}"
        printf '{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{"models":[{"value":"default","resolvedModel":"%s"},{"value":"%s","resolvedModel":"%s","displayName":"Project model"}]}}}\n' "$name" "$name" "$name"
        hold
        """)
        defer { fixture.remove() }
        let service = AgentModelCatalogService(home: home, environment: [:], launch: launch(fixture),
            cacheDirectory: saved, projectDirectory: directory)
        async let firstCatalog = service.handle(.init(project: first, provider: .claude))
        async let secondCatalog = service.handle(.init(project: second, provider: .claude))
        let (firstResult, secondResult) = try await (firstCatalog, secondCatalog)
        XCTAssertEqual(firstResult.models.map(\.id), ["one"])
        XCTAssertEqual(secondResult.models.map(\.id), ["two"])
        XCTAssertTrue(firstResult.models[0].isDefault)
        XCTAssertTrue(secondResult.models[0].isDefault)
        let offline = AgentModelCatalogService(home: home, environment: ["PATH": ""], cacheDirectory: saved,
                                              projectDirectory: directory)
        let savedFirst = try await offline.handle(.init(project: first, provider: .claude))
        let savedSecond = try await offline.handle(.init(project: second, provider: .claude))
        XCTAssertEqual(savedFirst.models, firstResult.models)
        XCTAssertEqual(savedSecond.models, secondResult.models)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: saved.path).count, 2)
    }
}

private final class ModelCatalogTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}
