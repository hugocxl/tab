import TabProtocol

/// Bootstrap Home can be remapped before the first authoritative snapshot.
/// Afterwards body actions remain attached to that session's observed project.
struct AgentConversationSessionScope {
    let session: SessionId
    private(set) var project: ProjectId?
    init(session: SessionId) { self.session = session }

    mutating func bind(snapshotSession: SessionId, snapshotProject: ProjectId, containerProject: ProjectId?) -> Bool {
        guard snapshotSession == session else { return false }
        if let project { return project == snapshotProject }
        guard containerProject == snapshotProject else { return false }
        project = snapshotProject
        return true
    }
}
