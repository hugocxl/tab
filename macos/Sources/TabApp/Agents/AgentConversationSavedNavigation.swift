import Foundation
import TabProtocol

/// In-message links may expose only the session/project the server actually read.
@MainActor
enum AgentConversationSavedNavigation {
    static func read(session: SessionId, project: ProjectId,
                     request: (AgentChatRequest) async throws -> AgentChatSnapshot) async throws -> AgentChatSnapshot {
        let snapshot = try await request(.read(session: session))
        try Task.checkCancellation()
        guard snapshot.session == session, snapshot.project == project else {
            throw ModelError("The cited conversation does not belong to this project.")
        }
        return snapshot
    }

    /// Waits until `controller` shows `snapshot` or a newer revision of the same conversation.
    static func awaitTranscript(_ controller: AgentPaneController, snapshot: AgentChatSnapshot,
                                timeout: TimeInterval = 10) async throws {
        controller.refresh()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            guard controller.session == snapshot.session else {
                throw ModelError("The cited conversation changed while it was opening.")
            }
            if let current = controller.snapshot, current.project != snapshot.project {
                throw ModelError("The cited conversation changed projects while it was opening.")
            }
            if let current = controller.snapshot, current.session == snapshot.session,
               current.revision >= snapshot.revision { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ModelError("The cited conversation could not finish loading. Try its source link again.")
    }
}
