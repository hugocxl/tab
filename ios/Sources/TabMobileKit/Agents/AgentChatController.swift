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
    /// Each provider's models, as its CLI on the Mac reports them.
    public private(set) var models: [AgentChatProvider: [AgentModelDescriptor]] = [:]
    /// The provider and model the next message goes to; nil model is the provider's default.
    public private(set) var selection: (provider: AgentChatProvider, model: String?)
    public private(set) var effort: AgentReasoningEffort?
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
        selection = (provider, nil)
    }

    /// The provider stays open to change until the conversation starts, as on the desktop.
    public var canChangeProvider: Bool { snapshot?.providerSession == nil }

    /// The model the next message uses: the chosen one, the conversation's, or the default.
    public var effectiveModel: String? {
        selection.model ?? (selection.provider == snapshot?.provider ? snapshot?.resolvedModel ?? snapshot?.model : nil)
            ?? models[selection.provider]?.first(where: \.isDefault)?.id
    }

    public var selectedModel: AgentModelDescriptor? {
        models[selection.provider]?.first { $0.id == effectiveModel }
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
        let first = snapshot == nil
        snapshot = next
        provider = next.provider
        // The conversation's own provider and model win, unless this pane chose others for its first message.
        if first || !canChangeProvider {
            selection = (next.provider, next.model)
            effort = next.reasoningEffort
        }
        error = nil
    }

    private func loadModels() {
        guard let client = server?.client else { return }
        for provider in AgentChatProvider.allCases where models[provider] == nil {
            let request = AgentModelCatalogRequest(project: project, provider: provider, forceRefresh: false)
            Task {
                guard let reply = try? await client.agentModelCatalog(request) else { return }
                models[provider] = reply.models
            }
        }
    }

    // MARK: Commands

    /// Sends a message, with the chat's current model and effort.
    public func send(_ text: String, attachments: [AgentChatAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        run(.send(session: session, text: trimmed, model: selection.model, reasoningEffort: effort,
                  provider: selection.provider == snapshot?.provider ? nil : selection.provider,
                  attachments: attachments.isEmpty ? nil : attachments))
    }

    /// Chooses the provider and model for the next message.
    public func select(provider: AgentChatProvider, model: String?) {
        guard canChangeProvider || provider == snapshot?.provider else { return }
        selection = (provider, model)
        let supported = models[provider]?.first { $0.id == effectiveModel }?.reasoningEfforts ?? []
        if let effort, !supported.contains(effort) { self.effort = nil }
    }

    public func select(effort: AgentReasoningEffort?) {
        self.effort = effort
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
