import AppKit
import TabCore
import TabClient
import TabProtocol

/// Application services for the source renderer. Body actions use the session's
/// authoritative project/server and never a moved container or claimed path scope.
@MainActor
final class AgentConversationNativeActions {
    private weak var surface: AgentPaneView?
    private weak var model: AppModel?
    private let pane: PaneId
    private let session: SessionId
    private var owningScope: AgentConversationSessionScope
    private var preview: AgentConversationMediaWindow?
    private var metadataTask: Task<Void, Never>?
    private var metadataKey: String?

    private init(surface: AgentPaneView, model: AppModel, pane: PaneId, session: SessionId) {
        self.surface = surface; self.model = model; self.pane = pane; self.session = session
        owningScope = AgentConversationSessionScope(session: session)
    }

    static func install(surface: AgentPaneView, model: AppModel, pane: PaneId, session: SessionId) {
        let actions = Self(surface: surface, model: model, pane: pane, session: session)
        if let projectID = model.state.paneProject(pane), let project = model.state.project(projectID) {
            surface.conversationProject = ["id": project.id.description, "environmentId": project.id.description,
                                           "title": project.name, "workspaceRoot": project.directory.rawValue, "faviconPath": NSNull()]
            surface.conversationRemote = project.serverId != .local
            surface.conversationCapabilities.merge(["filesystem": true, "filesystemWrite": true, "preview": true, "filePreview": true, "pullRequestPreview": true, "useArtifactTemplate": true, "focusComposer": true]) { _, value in value }
        }
        surface.onConversationAction = { kind, payload in try await actions.perform(kind, payload: payload) }
        surface.onConversationProjectRefresh = { [weak actions] in actions?.refreshProjectMetadata() }
        actions.refreshProjectMetadata()
    }

    deinit { metadataTask?.cancel() }

    private func bindObservedScope() -> ProjectId? {
        guard let model, let surface, let identity = surface.conversationIdentity,
              case .agent(let retainedSession, _) = model.state.pane(pane)?.content,
              retainedSession == session,
              owningScope.bind(snapshotSession: identity.session, snapshotProject: identity.project,
                               containerProject: model.state.paneProject(pane)),
              let projectID = owningScope.project, let project = model.state.project(projectID) else { return nil }
        if surface.conversationProject?["id"] as? String != projectID.description {
            surface.conversationProject = ["id": project.id.description, "environmentId": project.id.description,
                                           "title": project.name, "workspaceRoot": project.directory.rawValue, "faviconPath": NSNull()]
            surface.conversationRemote = project.serverId != .local
            surface.citationEnvironmentId = projectID.description
        }
        return projectID
    }

    private func refreshProjectMetadata() {
        guard metadataTask == nil, let projectID = bindObservedScope(), let model,
              let client = model.sideClient(for: projectID), client.supports(.pullRequestPreview) else { return }
        let key = projectID.description + ":" + String(client.server.instance)
        guard metadataKey != key else { return }
        metadataKey = key
        metadataTask = Task { [weak self, weak model, weak surface] in
            guard let self else { return }
            defer { self.metadataTask = nil }
            do {
                guard case .repoInfo(let info) = try await client.git(.init(project: projectID, action: .repoInfo)) else { return }
                try Task.checkCancellation()
                guard let model, let surface, self.owningScope.project == projectID,
                      surface.conversationIdentity?.session == self.session, surface.conversationIdentity?.project == projectID,
                      model.state.project(projectID) != nil,
                      surface.conversationProject?["id"] as? String == projectID.description else { return }
                var projection = surface.conversationProject ?? [:]
                if let origin = info.originURL { projection["originURL"] = origin } else { projection.removeValue(forKey: "originURL") }
                surface.conversationProject = projection
            } catch let error as ClientError {
                switch error {
                case .disconnected, .timeout, .transport, .remote: self.metadataKey = nil
                default: break // Non-Git projects and older servers have no observed repository identity.
                }
            } catch {} // Missing repository identity keeps its body links ordinary links.
        }
    }

    private func perform(_ kind: String, payload: [String: Any]) async throws -> Any? {
        try Task.checkCancellation()
        guard let model, let surface, let projectID = bindObservedScope(),
              let project = model.state.project(projectID) else {
            throw ModelError("The project server is offline.")
        }
        let scope = AgentConversationFileActions.Scope(project: projectID, session: session, directory: project.directory.rawValue)
        let input = payload["input"] as? [String: Any] ?? payload
        if ["filesystemMetadata", "searchProjectEntries", "createAssetUrl", "writeProjectFile"].contains(kind) {
            guard let client = model.sideClient(for: projectID) else { throw ModelError("The project server is offline.") }
            let registerRange: AgentConversationFileActions.RegisterRange? = client.supports(.fileByteRanges) ? { first, mime, path in
                try surface.conversationWebView.registerRangedAsset(length: first.totalSize, mimeType: mime, revision: first.revision, identity: path, read: { offset, length in
                    let chunk = try await client.readFileRange(projectID, path: ServerPath(path), offset: offset, length: length, expectedRevision: first.revision)
                    guard chunk.offset == offset, chunk.totalSize == first.totalSize, chunk.revision == first.revision,
                          chunk.bytes.count == Int(min(UInt64(length), first.totalSize - min(offset, first.totalSize))) else {
                        throw ModelError("The project server returned an inconsistent media range.")
                    }
                    return chunk.bytes
                })
            } : nil
            return try await AgentConversationFileActions.perform(kind, payload: payload, scope: scope,
                read: { try await client.files($0) }, register: { data, mime, path in
                    try surface.conversationWebView.registerAsset(data: data, mimeType: mime, identity: path, refetch: {
                        guard case .bytes(let file) = try await client.files(FilesRequest(project: projectID, action: .readBytes(ServerPath(path)))),
                              file.bytes.count <= AgentConversationFileActions.maximumAssetBytes else { throw ModelError("This conversation media resource is unavailable.") }
                        return file.bytes
                    })
                }, registerRange: registerRange, createWriteParents: client.supports(.fileWriteParents))
        }
        switch kind {
        case "focusComposer":
            guard surface.composer.isEditable, let window = surface.window, window.makeFirstResponder(surface.composer) else {
                throw ModelError("The composer cannot receive focus right now.")
            }
            return true
        case "useArtifactTemplate":
            return try AgentConversationTemplateAction.perform(payload, surface: surface)
        case "pullRequestPreview":
            guard let client = model.sideClient(for: projectID) else { throw ModelError("The project server is offline.") }
            guard client.supports(.pullRequestPreview) else { throw ModelError("Update this project’s server to enable inline pull-request previews.") }
            return try await AgentConversationPullRequestPreview.perform(payload, project: projectID, request: { try await client.git($0) })
        case "openEditor":
            guard let target = input["cwd"] as? String, let position = AgentConversationFileTarget.parse(target) else {
                throw ModelError("Invalid editor file target.")
            }
            let relative = try AgentConversationFileActions.resolve(position.path, scope: scope)
            if input["reveal"] as? Bool == true || input["editor"] as? String == "file-manager" {
                guard project.serverId == .local else { throw ModelError("Finder cannot reveal files on another server.") }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.directory.rawValue).appendingPathComponent(relative)])
            } else {
                guard model.openEditor(project: projectID, path: relative, line: position.line, column: position.column) != nil else { throw ModelError("The file could not be opened in Tab.") }
            }
            return true
        case "openPreview", "openLink":
            guard let raw = (input["url"] ?? payload["url"]) as? String,
                  let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  model.openBrowser(url: url.absoluteString, project: projectID) != nil else {
                throw ModelError("This link could not be opened in Tab’s browser.")
            }
            return true
        case "openFile":
            guard let client = model.sideClient(for: projectID) else { throw ModelError("The project server is offline.") }
            guard let path = payload["path"] as? String, payload["mode"] as? String == "preview" else {
                throw ModelError("Invalid file preview target.")
            }
            let relative = try AgentConversationFileActions.resolve(path, scope: scope)
            let next: AgentConversationMediaWindow
            if client.supports(.fileByteRanges) {
                let first = try await client.readFileRange(projectID, path: ServerPath(relative), offset: 0, length: 1)
                let resource = AgentConversationRangedResource(length: first.totalSize, mimeType: AgentConversationFileActions.mimeType(path: relative), revision: first.revision, read: { offset, length in
                    let chunk = try await client.readFileRange(projectID, path: ServerPath(relative), offset: offset, length: length, expectedRevision: first.revision)
                    guard chunk.offset == offset, chunk.totalSize == first.totalSize, chunk.revision == first.revision else { throw ModelError("This media file changed; refresh its preview.") }
                    return chunk.bytes
                })
                try Task.checkCancellation()
                next = try AgentConversationMediaWindow(resource: resource, name: (relative as NSString).lastPathComponent)
            } else {
                guard case .info(let info) = try await client.files(FilesRequest(project: projectID, action: .stat(ServerPath(relative)))),
                      !info.isDirectory, info.size <= UInt64(AgentConversationFileActions.maximumAssetBytes) else {
                    throw ModelError("This file exceeds the project server’s preview read limit.")
                }
                guard case .bytes(let file) = try await client.files(FilesRequest(project: projectID, action: .readBytes(ServerPath(relative)))) else {
                    throw ModelError("The file preview is unavailable.")
                }
                try Task.checkCancellation()
                next = try AgentConversationMediaWindow(data: file.bytes, name: (relative as NSString).lastPathComponent,
                                                        mimeType: AgentConversationFileActions.mimeType(path: relative))
            }
            preview?.close()
            preview = next
            preview?.showWindow(nil)
            return true
        case "openThread", "navigateCitation":
            let citation: AgentAssistantCitation?
            if kind == "navigateCitation" {
                guard let json = payload["citation"], JSONSerialization.isValidJSONObject(json) else { throw ModelError("Invalid citation navigation target.") }
                citation = try JSONDecoder().decode(AgentAssistantCitation.self, from: JSONSerialization.data(withJSONObject: json))
                guard citation?.isValid == true else { throw ModelError("Invalid assistant citation.") }
            } else { citation = nil }
            let targetID = citation?.threadId ?? payload["threadId"] as? String
            let environment = citation?.environmentId ?? payload["environmentId"] as? String ?? projectID.description
            guard let targetID, let targetSession = SessionId(string: targetID),
                  let targetProjectID = ProjectId(string: environment), model.state.project(targetProjectID) != nil else {
                throw ModelError("This conversation is unavailable on this Mac.")
            }
            guard let client = model.sideClient(for: targetProjectID) else { throw ModelError("The cited conversation’s server is offline.") }
            let target = try await AgentConversationSavedNavigation.read(session: targetSession, project: targetProjectID, request: { try await client.agentChat($0) })
            if let citation, !target.items.contains(where: { $0.id == citation.messageId && $0.kind == .assistant }) {
                throw ModelError("The quoted assistant message is no longer retained in this conversation.")
            }
            try Task.checkCancellation()
            guard let targetPane = model.openExistingAgent(target),
                  let controller = model.controller(for: targetPane) as? AgentPaneController else {
                throw ModelError("The cited conversation could not be opened.")
            }
            model.focusPane(targetPane)
            if let citation {
                try await AgentConversationSavedNavigation.awaitRenderer(controller, snapshot: target)
                let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(citation))
                guard try await controller.surface.conversationWebView.evaluate("return window.TabConversation.navigateCitation(citation)", arguments: ["citation": json]) as? Bool == true else {
                    throw ModelError("The quoted text could not be located in this conversation.")
                }
            }
            return true
        default:
            throw ModelError("This conversation action is unavailable: " + kind)
        }
    }
}
