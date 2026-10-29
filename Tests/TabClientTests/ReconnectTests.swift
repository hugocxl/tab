import TabProtocol
import XCTest
@testable import TabClient

final class ReconnectTests: XCTestCase {
    func testBackoffDoublesFromTwoSecondsUpToAMinute() {
        XCTAssertEqual((0 ..< 8).map(ReconnectBackoff.delay(afterFailures:)), [2, 4, 8, 16, 32, 60, 60, 60])
        XCTAssertEqual(ReconnectBackoff.delay(afterFailures: 1000), 60)
        XCTAssertEqual(ReconnectBackoff.delay(afterFailures: -1), 2)
    }

    func testPendingClosesKeepTheirOperationAndOrderAndSurviveAReload() throws {
        let first = SessionId()
        let second = SessionId()
        var closes = PendingCloses()
        closes.queue(first)
        let operation = try XCTUnwrap(closes.operation(for: first))
        closes.queue(second)
        closes.queue(first)
        XCTAssertEqual(closes.sessions, [first, second])
        XCTAssertEqual(closes.operation(for: first), operation, "a retried close reuses its operation")
        let reloaded = try JSONDecoder().decode(PendingCloses.self, from: JSONEncoder().encode(closes))
        XCTAssertEqual(reloaded, closes)
        closes.complete(first)
        XCTAssertEqual(closes.sessions, [second])
    }

    private struct Unreachable: Error {}

    func testReconnectingStopsWhenTheUserIsNeeded() async throws {
        let attempts = Counter()
        let reconnector = Reconnector(connect: {
            attempts.increment()
            if attempts.value < 3 { throw ClientError.disconnected }
            throw ClientError.remote(RemoteFailure(reason: .authenticationFailed, destination: "box", detail: ""))
        }, delay: { _ in 0.001 })
        guard case .needsUser(let error) = await reconnector.start().value else {
            return XCTFail("a refused login needs the user")
        }
        XCTAssertFalse(error.recoverable)
        XCTAssertEqual(attempts.value, 3, "recoverable failures retry; a refused login stops at once")
        XCTAssertEqual(reconnector.attempts, 3)
        XCTAssertFalse(reconnector.isRunning)
    }

    func testAMissingPasswordStopsBeforeConnecting() async {
        let attempts = Counter()
        let reconnector = Reconnector(connect: {
            attempts.increment()
            throw ClientError.disconnected
        }, needsPassword: { true }, delay: { _ in 0 })
        guard case .needsUser(.remote(let failure)) = await reconnector.start().value else {
            return XCTFail("a password login without a password needs the user")
        }
        XCTAssertEqual(failure.reason, .passwordNeeded)
        XCTAssertEqual(attempts.value, 0, "no failed login is tried")
    }

    func testWaitsGrowWithFailuresAndCancellingStops() async {
        let delays = Recorder()
        let reconnector = Reconnector(connect: { throw ClientError.timeout }, delay: { attempts in
            delays.record(attempts)
            return attempts < 3 ? 0.001 : 30
        })
        let task = reconnector.start()
        while delays.values.count < 4 { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(Array(delays.values.prefix(4)), [0, 1, 2, 3])
        reconnector.cancel()
        guard case .cancelled = await task.value else { return XCTFail("cancelled") }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    func record(_ value: Int) { lock.withLock { recorded.append(value) } }
    var values: [Int] { lock.withLock { recorded } }
}
