import TabProtocol
import XCTest
@testable import TabApp

final class AgentConversationSessionScopeTests: XCTestCase {
    func testFirstAuthoritativeHomeRemapBindsThenContainerChangesCannotRetargetBodyActions() {
        let session = SessionId(), serverHome = ProjectId(), movedContainer = ProjectId()
        var scope = AgentConversationSessionScope(session: session)
        XCTAssertTrue(scope.bind(snapshotSession: session, snapshotProject: serverHome, containerProject: serverHome))
        XCTAssertEqual(scope.project, serverHome)
        XCTAssertTrue(scope.bind(snapshotSession: session, snapshotProject: serverHome, containerProject: movedContainer))
        XCTAssertEqual(scope.project, serverHome, "A container move cannot change a saved conversation’s file/server authority")
        XCTAssertFalse(scope.bind(snapshotSession: session, snapshotProject: movedContainer, containerProject: movedContainer))
        XCTAssertEqual(scope.project, serverHome)
    }

    func testWrongSessionOrUnrelatedFirstProjectCannotClaimScope() {
        let session = SessionId(), project = ProjectId()
        var scope = AgentConversationSessionScope(session: session)
        XCTAssertFalse(scope.bind(snapshotSession: SessionId(), snapshotProject: project, containerProject: project))
        XCTAssertFalse(scope.bind(snapshotSession: session, snapshotProject: ProjectId(), containerProject: project))
        XCTAssertNil(scope.project)
    }
}
