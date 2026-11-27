import Foundation
import TabClient
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AppSocketOwnershipTests: XCTestCase {
    func testFailedSecondListenerAndCloseLeaveTheRunningSocketReachable() async throws {
        let dirs = try ModelFixtures.profile()
        let model = AppModel(dirs: dirs)
        let first = AppSocketHandler(model: model)
        try first.listen()
        defer { first.close() }
        try first.listen()
        let second = AppSocketHandler(model: model)
        XCTAssertThrowsError(try second.listen())
        second.close()
        let reply = await Task.detached {
            try AppSocket.call(socket: dirs.appSocket, .unknown("probe"), timeout: 1)
        }.result
        switch reply {
        case .success: XCTFail("an unknown command must fail")
        case .failure(let error): XCTAssertEqual(error as? AppSocketError, .failed("unknown command probe"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirs.appSocket.path))
    }

    func testClosingAnOldListenerDoesNotUnlinkItsReplacement() throws {
        let dirs = try ModelFixtures.profile()
        let model = AppModel(dirs: dirs)
        let first = AppSocketHandler(model: model)
        try first.listen()
        try FileManager.default.removeItem(at: dirs.appSocket)
        let replacement = AppSocketHandler(model: model)
        try replacement.listen()
        defer { replacement.close() }
        first.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirs.appSocket.path))
    }

    func testLockedProfileWithoutAnAnswerFailsAfterBoundedStartupRetries() async throws {
        let dirs = try ModelFixtures.profile()
        var instance = try SingleInstance.claim(folder: nil, dirs: dirs)
        XCTAssertNotNil(instance)
        let started = ProcessInfo.processInfo.systemUptime
        let result = await Task.detached {
            Result { try SingleInstance.claim(folder: nil, dirs: dirs, patience: 0.1) }
        }.value
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        switch result {
        case .success: XCTFail("an unanswered lock owner must prevent startup")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.hasPrefix("Tab is already running but did not answer: "))
        }
        instance = nil
        let replacement = try SingleInstance.claim(folder: nil, dirs: dirs)
        XCTAssertNotNil(replacement)
        withExtendedLifetime(replacement) {}
    }

    func testSecondLaunchRetriesUntilTheOwnersSocketStarts() async throws {
        let dirs = try ModelFixtures.profile()
        let instance = try XCTUnwrap(SingleInstance.claim(folder: nil, dirs: dirs))
        defer { withExtendedLifetime(instance) {} }
        let second = Task.detached { try SingleInstance.claim(folder: nil, dirs: dirs, patience: 1) == nil }
        try await Task.sleep(for: .milliseconds(60))
        let model = AppModel(dirs: dirs)
        let handler = AppSocketHandler(model: model)
        try handler.listen()
        defer { handler.close() }
        let handed = try await second.value
        XCTAssertTrue(handed)
    }

    func testAnOwnerThatAcceptsButDoesNotAnswerFailsTheHandoff() async throws {
        let dirs = try ModelFixtures.profile()
        let instance = try XCTUnwrap(SingleInstance.claim(folder: nil, dirs: dirs))
        defer { withExtendedLifetime(instance) {} }
        let server = try AppSocketServer(socket: dirs.appSocket) { _ in
            try? await Task.sleep(for: .milliseconds(250))
            return .ok(.bool(true))
        }
        defer { server.close() }
        let result = await Task.detached {
            Result { try SingleInstance.claim(folder: nil, dirs: dirs, patience: 0.05) }
        }.value
        switch result {
        case .success: XCTFail("an app that accepts but stalls must prevent startup")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.hasPrefix("Tab is already running but did not answer: "))
        }
    }

    func testUnexpectedHandoffReplyFailsInsteadOfStartingAnotherInstance() async throws {
        let dirs = try ModelFixtures.profile()
        let instance = try XCTUnwrap(SingleInstance.claim(folder: nil, dirs: dirs))
        defer { withExtendedLifetime(instance) {} }
        let server = try AppSocketServer(socket: dirs.appSocket) { _ in .ok(.null) }
        defer { server.close() }
        let result = await Task.detached {
            Result { try SingleInstance.claim(folder: nil, dirs: dirs, patience: 0.1) }
        }.value
        switch result {
        case .success: XCTFail("an unexpected reply must prevent startup")
        case .failure(let error):
            XCTAssertEqual(error.localizedDescription, "Tab is already running but did not answer: unexpected reply")
        }
    }

    func testReleasedProfileCanBeClaimedAgainWithAStaleSocket() throws {
        let dirs = try ModelFixtures.profile()
        var instance = try SingleInstance.claim(folder: nil, dirs: dirs)
        XCTAssertNotNil(instance)
        instance = nil
        var stale: UnixSocketListener? = try UnixSocketListener(path: dirs.appSocket.path)
        XCTAssertNotNil(stale)
        stale = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirs.appSocket.path))
        let next = try XCTUnwrap(SingleInstance.claim(folder: nil, dirs: dirs))
        defer { withExtendedLifetime(next) {} }
        let model = AppModel(dirs: dirs)
        let handler = AppSocketHandler(model: model)
        try handler.listen()
        handler.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirs.appSocket.path))
    }
}
