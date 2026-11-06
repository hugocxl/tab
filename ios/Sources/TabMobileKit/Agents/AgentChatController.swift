import Foundation
import Observation
import TabProtocol
import TabShared

/// One agent pane's conversation. The server runs the agent and sends whole
/// snapshots: this reads the newest one when the server says the chat
/// changed, at most one read at a time, and never goes back to an older one.
@MainActor
@Observable
public final class AgentChatController {
    public nonisolated let session: SessionId
    public let project: ProjectId
    public private(set) var provider: AgentChatProvider
    public private(set) var snapshot: AgentChatSnapshot?
    public private(set) var models: [AgentModelDescriptor] = []
    /// A command is on its way; sending again waits for it.
    public private(set) var busy = false
    public private(set) var error: String?

    @ObservationIgnored private weak var server: ServerModel?
    @ObservationIgnored private var created = false
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var readAgain = false
    @ObservationIgnored private var wanted = false

    init(session: SessionId, project: ProjectId, provider: AgentChatProvider, server: ServerModel) {
        self.session = session
        self.project = project
        self.provider = provider
        self.server = server
    }

    public var status: AgentChatStatus { snapshot?.status ?? .idle }
    public var items: [AgentChatItem] { snapshot?.items ?? [] }
    public var isRunning: Bool { status == .working || status == .waiting }

    /// Starts following the chat: creates it on the server if it's new.
    public func open() {
        wanted = true
        refresh()
        loadModels()
    }

    public func close() {
        wanted = false
    }

    func connectionRestored(_ client: ServerClient) {
        guard wanted else { return }
        refresh()
    }

    func changed(revision: UInt64) {
        guard wanted, revision > (snapshot?.revision ?? 0) else { return }
        refresh()
    }

    private func refresh() {
        guard !reading else {
            readAgain = true
            return
        }
        guard let client = server?.client else { return }
        reading = true
        Task {
            defer { reading = false }
            repeat {
                readAgain = false
                let request: AgentChatRequest = created
                    ? .read(session: session)
                    : .create(session: session, project: project, provider: provider)
                do {
                    accept(try await client.agentChat(request))
                    created = true
                } catch let failure as ClientError {
                    error = failure.description
                    return
                } catch {
                    return
                }
            } while readAgain
        }
    }

    private func accept(_ next: AgentChatSnapshot) {
        guard next.revision >= (snapshot?.revision ?? 0) else { return }
        snapshot = next
        provider = next.provider
        error = nil
    }

    private func loadModels() {
        guard models.isEmpty, let client = server?.client else { return }
        let request = AgentModelCatalogRequest(project: project, provider: provider, forceRefresh: false)
        Task { models = (try? await client.agentModelCatalog(request))?.models ?? [] }
    }

    // MARK: Commands

    /// Sends a message, with the chat's current model and effort.
    public func send(_ text: String, attachments: [AgentChatAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        run(.send(session: session, text: trimmed, model: snapshot?.model, reasoningEffort: snapshot?.reasoningEffort,
                  provider: nil, attachments: attachments.isEmpty ? nil : attachments))
    }

    public func setModel(_ model: String?, effort: AgentReasoningEffort?) {
        // The model applies to the next message; keep it until then.
        guard var snapshot else { return }
        snapshot.model = model
        snapshot.reasoningEffort = effort
        self.snapshot = snapshot
    }

    public func approve(_ item: AgentChatItem, allow: Bool) {
        run(.approve(session: session, request: item.id, allow: allow))
    }

    public func setAccess(_ mode: AgentAccessMode) {
        run(.setAccess(session: session, mode: mode))
    }

    public func interrupt() {
        guard isRunning else { return }
        run(.interrupt(session: session))
    }

    private func run(_ request: AgentChatRequest) {
        guard let client = server?.client else {
            error = "Not connected."
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                accept(try await client.agentChat(request))
            } catch let failure as ClientError {
                error = failure.description
            } catch {}
        }
    }
}
