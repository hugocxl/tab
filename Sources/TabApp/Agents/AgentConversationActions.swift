import AppKit
import TabClient
import TabCore
import TabProtocol

/// What a conversation body can ask the app to do. Every target is checked against
/// the retained snapshot (items, attachments, approvals, turns) before anything
/// opens; project reads go through `project`, bound to the session's own project.
@MainActor
final class AgentConversationActions {
    weak var surface: AgentPaneView?
    var pasteboard: NSPasteboard = .general
    /// Services that need the app model and the session's project server.
    var project: AgentConversationProjectActions?
    /// Resolves a pending approval and returns once the server acknowledged it.
    var onApprove: ((String, Bool) async throws -> Void)?
    var onInterrupt: (() -> Void)?
    /// Puts a preview window on screen; tests place it offscreen instead.
    var presentWindow: (NSWindowController) -> Void = { $0.showWindow(nil) }

    private var snapshot: AgentChatSnapshot? { surface?.snapshot }
    /// The open HTML document preview, if any.
    private(set) var htmlPreview: AgentConversationMediaWindow?
    /// The open gallery of assistant Markdown images, if any.
    private(set) var markdownMediaPreview: AgentMediaPreviewWindow?
    /// The open player of assistant Markdown video or audio, if any.
    private(set) var markdownMediaPlayer: AgentConversationMediaWindow?

    private func retained(_ id: String) throws -> AgentChatItem {
        guard let item = snapshot?.items.first(where: { $0.id == id }) else { throw ModelError("This message is no longer retained.") }
        return item
    }

    private func projectActions() throws -> AgentConversationProjectActions {
        guard let project else { throw ModelError("The project server is offline.") }
        return project
    }

    // MARK: Clipboard

    /// Writes one clipboard item; `flavors` adds MIME types beyond plain text and HTML.
    func copy(text: String?, html: String? = nil, flavors: [String: String] = [:], png: Data? = nil) throws {
        var all = flavors
        if let text { all["text/plain"] = text }
        if let html { all["text/html"] = html }
        try AgentConversationClipboard.write(flavors: all, png: png, to: pasteboard)
    }

    // MARK: Links, files and commands

    /// A Markdown link destination: an assistant citation, a project file or a web page.
    func openLink(_ destination: String) async throws {
        if let citation = AgentAssistantCitation.parse(destination) {
            try await navigateCitation(citation)
            return
        }
        guard let link = AgentResponseLink.parse(destination) else { throw ModelError("This link cannot be opened.") }
        switch link {
        case .external(let url): guard NSWorkspace.shared.open(url) else { throw ModelError("No application could open this link.") }
        case .file(let path, let line): try openFile(path, line: line)
        case .fragment: throw ModelError("This link points inside the message.")
        }
    }

    /// Opens an http(s) page in a Tab browser pane of the session's project.
    func openPreview(_ url: URL) throws { try projectActions().openBrowser(url) }

    func openFile(_ path: String, line: Int? = nil) throws {
        guard let open = surface?.onOpenFile else { throw ModelError("The project editor is unavailable.") }
        open(path, line)
    }

    /// Shows a project file in an isolated media preview window.
    func previewFile(_ path: String) async throws { try await projectActions().previewFile(path) }

    /// `target` may carry a `:line:column` or `#L12C3` suffix; `reveal` shows it in Finder.
    func openEditor(_ target: String, reveal: Bool = false) throws { try projectActions().openEditor(target, reveal: reveal) }

    /// Opens an HTML file of a local project in the default browser.
    func openFileInBrowser(_ path: String) throws { try projectActions().openFileInBrowser(path) }

    /// Whether the session's project lives on this Mac; false while the server is offline.
    var isLocalProject: Bool { project?.isLocal ?? false }

    /// The link context-menu actions, bound to this conversation.
    var linkMenuActions: AgentLinkMenu.Actions {
        AgentLinkMenu.Actions(
            openEditor: { [weak self] target, reveal in
                guard let self else { throw ModelError("The conversation was closed.") }
                try self.openEditor(target, reveal: reveal)
            },
            previewFile: { [weak self] path in
                guard let self else { throw ModelError("The conversation was closed.") }
                try await self.previewFile(path)
            },
            openFileInBrowser: { [weak self] path in
                guard let self else { throw ModelError("The conversation was closed.") }
                try self.openFileInBrowser(path)
            },
            openPreview: { [weak self] url in
                guard let self else { throw ModelError("The conversation was closed.") }
                try self.openPreview(url)
            },
            copy: { [weak self] text in
                guard let self else { throw ModelError("The conversation was closed.") }
                try self.copy(text: text)
            })
    }

    func runShellCommand(_ command: String) throws {
        guard let run = surface?.onRunShellCommand else { throw ModelError("A project terminal is unavailable.") }
        run(command)
    }

    // MARK: Turn control

    /// Answers a pending approval by its item id, with or without the `approval:` prefix.
    func approve(requestID: String, allow: Bool) async throws {
        guard let pending = snapshot?.items.first(where: {
            $0.kind == .approval && !$0.isComplete && ($0.id == requestID || $0.id == "approval:" + requestID)
        }) else { throw ModelError("This approval is no longer pending.") }
        guard let approve = onApprove else { throw ModelError("Approval controls are unavailable.") }
        try await approve(pending.id, allow)
    }

    func interrupt() throws {
        guard let interrupt = onInterrupt else { throw ModelError("This conversation cannot be stopped from here.") }
        interrupt()
    }

    func openToolDiff(itemID: String) throws {
        guard let activity = try retained(itemID).tool, let open = surface?.onOpenToolDiff else {
            throw ModelError("The recorded tool diff is unavailable.")
        }
        open(itemID, activity)
    }

    /// The checkpoint diff of the turn started by `userItemID`, optionally one file.
    func openTurnDiff(userItemID: String, filePath: String? = nil) throws {
        guard let checkpoint = snapshot?.turns?.first(where: { $0.userItemID == userItemID })?.checkpoint,
              let open = surface?.onOpenCheckpoint else { throw ModelError("The recorded turn diff is unavailable.") }
        open(checkpoint.id, filePath)
    }

    func loadTurnItem(_ itemID: String) throws -> AgentChatItem { try retained(itemID) }

    func loadCommandOutput(_ itemID: String) throws -> String {
        guard let output = try retained(itemID).tool?.output else { throw ModelError("This command has no recorded output.") }
        return output
    }

    // MARK: Attachments and images

    /// The attachment, only when it belongs to the retained message `itemID`.
    func ownedAttachment(itemID: String, attachmentID: String) throws -> AgentChatAttachmentDescriptor {
        guard let attachment = try retained(itemID).attachments?.first(where: { $0.id == attachmentID }) else {
            throw ModelError("This attachment does not belong to a retained message.")
        }
        return attachment
    }

    func loadAttachment(itemID: String, attachmentID: String) async throws -> Data {
        let attachment = try ownedAttachment(itemID: itemID, attachmentID: attachmentID)
        guard let fetch = surface?.fetchAttachment else { throw ModelError("The attachment is unavailable.") }
        return try await fetch(itemID, attachment)
    }

    func openAttachment(itemID: String, attachmentID: String) throws {
        try openAttachment(itemID: itemID, attachmentID: attachmentID, download: false)
    }

    func downloadAttachment(itemID: String, attachmentID: String) throws {
        try openAttachment(itemID: itemID, attachmentID: attachmentID, download: true)
    }

    private func openAttachment(itemID: String, attachmentID: String, download: Bool) throws {
        let attachment = try ownedAttachment(itemID: itemID, attachmentID: attachmentID)
        guard let open = surface?.onOpenAttachment else { throw ModelError("The attachment viewer is unavailable.") }
        open(itemID, attachment, download)
    }

    /// The message's images in the media viewer, starting at `index`.
    func previewImages(itemID: String, index: Int) throws {
        let images = (try retained(itemID).attachments ?? []).filter { $0.mimeType.hasPrefix("image/") }
        guard images.indices.contains(index), let preview = surface?.onPreviewAttachments else { throw ModelError("The image preview is unavailable.") }
        preview(itemID, images, index)
    }

    func expandImage(itemID: String, attachmentID: String) throws {
        let images = (try retained(itemID).attachments ?? []).filter { $0.mimeType.hasPrefix("image/") }
        guard let index = images.firstIndex(where: { $0.id == attachmentID }) else { throw ModelError("The image preview is unavailable.") }
        try previewImages(itemID: itemID, index: index)
    }

    /// The bytes of a retained MCP app or `html_render` document, only while the tool
    /// call that produced it is still retained and unchanged.
    func htmlDocument(attachmentID: String) async throws -> (data: Data, match: AgentConversationMcpAsset.Match) {
        guard let items = snapshot?.items,
              let match = AgentConversationMcpAsset.match(attachmentID: attachmentID, items: items)
                ?? AgentConversationMcpAsset.htmlRenderCandidates(attachmentID: attachmentID, items: items).first else {
            throw ModelError("This HTML document has no matching retained tool resource.")
        }
        guard let fetch = surface?.fetchAttachment else { throw ModelError("The retained HTML document is unavailable.") }
        let data = try await fetch(match.ownership.itemID, match.ownership.attachment)
        try Task.checkCancellation()
        let current = Dictionary((snapshot?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        guard match.ownership.isRetained(in: current), data.count == match.ownership.attachment.byteCount,
              data.count <= match.maximumBytes, String(data: data, encoding: .utf8) != nil else {
            throw ModelError("The retained HTML document is unavailable or changed.")
        }
        return (data, match)
    }

    /// Shows the retained HTML document in an isolated preview window. Its scripts run only
    /// inside the sandbox of the response; navigation away from it is blocked.
    func previewHTMLDocument(attachmentID: String, title: String? = nil) async throws {
        let document = try await htmlDocument(attachmentID: attachmentID)
        let name = title ?? AgentHtmlDocumentReference.title(in: document.data) ?? document.match.ownership.toolName
        let next = try AgentConversationMediaWindow.htmlDocument(data: document.data, name: name)
        next.onOpenLink = { [weak self] url in
            Task { @MainActor in
                do { try await self?.openLink(url.absoluteString) } catch { NSWorkspace.shared.open(url) }
            }
        }
        htmlPreview?.close()
        htmlPreview = next
        presentWindow(next)
    }

    /// Shows assistant Markdown images in the zoomable preview, loaded through the
    /// conversation's media loader; arrows move through `gallery`.
    func previewMarkdownMedia(_ gallery: [AgentMarkdownMedia], index: Int) throws {
        guard let surface, gallery.indices.contains(index) else { throw ModelError("The image preview is unavailable.") }
        let loader = surface.mediaLoader
        let descriptors = gallery.enumerated().map { offset, media in
            AgentChatAttachmentDescriptor(id: String(offset), name: media.name, mimeType: media.mimeType, byteCount: 0)
        }
        let preview = AgentMediaPreviewWindow(item: "markdown-media", attachments: descriptors, index: index, fetch: { _, descriptor in
            guard let offset = Int(descriptor.id), gallery.indices.contains(offset) else { throw ModelError("This image is unavailable.") }
            return try await loader.entry(for: gallery[offset]).data
        }, theme: surface.theme)
        markdownMediaPreview?.close()
        markdownMediaPreview = preview
        preview.present(in: surface.window)
    }

    /// Plays assistant Markdown video or audio: project files and `data:` URIs in the
    /// isolated media window, web media in the browser.
    func playMarkdownMedia(_ media: AgentMarkdownMedia) async throws {
        guard let source = AgentMediaSource(media.source) else { throw ModelError("This media link is not supported.") }
        let next: AgentConversationMediaWindow
        switch source {
        case .remote(let url):
            try await openLink(url.absoluteString)
            return
        case .data(let raw):
            let decoded = try await Task.detached(priority: .userInitiated) { try AgentMediaLoader.decodeDataURI(raw) }.value
            next = try AgentConversationMediaWindow(data: decoded.data, name: media.name, mimeType: decoded.mimeType)
        case .file(let path):
            let file = try await workspaceMedia(path)
            next = try AgentConversationMediaWindow(resource: file.resource, name: media.name)
        }
        try Task.checkCancellation()
        markdownMediaPlayer?.close()
        markdownMediaPlayer = next
        presentWindow(next)
    }

    /// Copies the retained HTML document's source text.
    func copyHTMLDocument(attachmentID: String) async throws {
        let document = try await htmlDocument(attachmentID: attachmentID)
        guard let text = String(data: document.data, encoding: .utf8) else { throw ModelError("The HTML document is not valid UTF-8.") }
        try copy(text: text)
    }

    // MARK: Composer

    /// Inserts a quotation of an assistant message of this conversation at the composer selection.
    @discardableResult
    func cite(_ citation: AgentAssistantCitation) -> Bool { surface?.insertCitation(citation) == true }

    func focusComposer() throws {
        guard let surface, surface.composer.isEditable, let window = surface.window, window.makeFirstResponder(surface.composer) else {
            throw ModelError("The composer cannot receive focus right now.")
        }
    }

    func composerPrompt() throws -> String {
        guard let surface else { throw ModelError("The conversation was closed.") }
        return try AgentConversationTemplateAction.prompt(surface: surface)
    }

    /// Appends a template prompt when the draft still equals `expectedPrompt`.
    func useArtifactTemplate(_ text: String, expectedPrompt: String) throws {
        guard let surface else { throw ModelError("The conversation was closed.") }
        try AgentConversationTemplateAction.append(text, expectedPrompt: expectedPrompt, surface: surface)
    }

    // MARK: Project

    func searchProjectEntries(_ query: String, limit: Int) async throws -> AgentConversationFileActions.Entries {
        try await projectActions().searchProjectEntries(query, limit: limit)
    }

    func filesystemMetadata(_ paths: [String]) async throws -> [AgentConversationFileActions.Metadata?] {
        try await projectActions().filesystemMetadata(paths)
    }

    func workspaceMedia(_ path: String, cwd: String? = nil) async throws -> AgentConversationFileActions.Media {
        try await projectActions().workspaceMedia(path, cwd: cwd)
    }

    /// Returns the project-relative path the server wrote.
    func writeProjectFile(_ relativePath: String, contents: String, cwd: String? = nil) async throws -> String {
        try await projectActions().writeProjectFile(relativePath, contents: contents, cwd: cwd)
    }

    func pullRequestPreview(_ url: URL) async throws -> GitPullRequestPreview {
        try await projectActions().pullRequestPreview(url)
    }

    /// Opens another saved conversation, of this project unless `project` names another.
    func openThread(_ session: SessionId, project: ProjectId? = nil) async throws {
        try await projectActions().openConversation(session, project: project, citation: nil)
    }

    /// Opens the cited conversation and scrolls to the quoted assistant message.
    func navigateCitation(_ citation: AgentAssistantCitation) async throws {
        guard citation.isValid, let session = SessionId(string: citation.threadId),
              let project = ProjectId(string: citation.environmentId) else { throw ModelError("Invalid assistant citation.") }
        try await projectActions().openConversation(session, project: project, citation: citation)
    }
}

/// Conversation services that need the app model. They act only for the pane's
/// session and the project its first authoritative snapshot was bound to.
@MainActor
final class AgentConversationProjectActions {
    private weak var surface: AgentPaneView?
    private weak var model: AppModel?
    private let pane: PaneId
    private let session: SessionId
    private var owningScope: AgentConversationSessionScope
    private var preview: AgentConversationMediaWindow?
    private var metadataTask: Task<Void, Never>?
    private var metadataKey: String?
    /// The `origin` remote of the project's repository, when it has one.
    private(set) var repositoryOriginURL: String?

    private init(surface: AgentPaneView, model: AppModel, pane: PaneId, session: SessionId) {
        self.surface = surface; self.model = model; self.pane = pane; self.session = session
        owningScope = AgentConversationSessionScope(session: session)
    }

    static func install(surface: AgentPaneView, model: AppModel, pane: PaneId, session: SessionId) {
        let actions = Self(surface: surface, model: model, pane: pane, session: session)
        surface.actions.project = actions
        actions.refreshProjectMetadata()
    }

    deinit { metadataTask?.cancel() }

    private func bindObservedScope() -> ProjectId? {
        guard let model, let surface, let snapshot = surface.snapshot,
              case .agent(let retainedSession, _) = model.state.pane(pane)?.content,
              retainedSession == session,
              owningScope.bind(snapshotSession: snapshot.session, snapshotProject: snapshot.project,
                               containerProject: model.state.paneProject(pane)),
              let projectID = owningScope.project, model.state.project(projectID) != nil else { return nil }
        if surface.citationEnvironmentId != projectID.description { surface.citationEnvironmentId = projectID.description }
        return projectID
    }

    private func context() throws -> (model: AppModel, project: Project, client: ServerAPI, scope: AgentConversationFileActions.Scope) {
        try Task.checkCancellation()
        guard let model, let projectID = bindObservedScope(), let project = model.state.project(projectID),
              let client = model.sideClient(for: projectID) else { throw ModelError("The project server is offline.") }
        return (model, project, client, .init(project: projectID, session: session, directory: project.directory.rawValue))
    }

    /// Reads the repository identity once per project server connection.
    func refreshProjectMetadata() {
        guard metadataTask == nil, let projectID = bindObservedScope(), let model,
              let client = model.sideClient(for: projectID), client.supports(.pullRequestPreview) else { return }
        let key = projectID.description + ":" + String(client.server.instance)
        guard metadataKey != key else { return }
        metadataKey = key
        metadataTask = Task { [weak self, weak model] in
            guard let self else { return }
            defer { self.metadataTask = nil }
            do {
                guard case .repoInfo(let info) = try await client.git(.init(project: projectID, action: .repoInfo)) else { return }
                try Task.checkCancellation()
                guard let model, self.owningScope.project == projectID, model.state.project(projectID) != nil,
                      self.surface?.snapshot?.session == self.session else { return }
                self.repositoryOriginURL = info.originURL
                self.surface?.linkServices.pullRequestHosts = AgentPullRequestLink.hosts(origin: info.originURL)
            } catch let error as ClientError {
                switch error {
                case .disconnected, .timeout, .transport, .remote: self.metadataKey = nil
                default: break // Non-Git projects and older servers have no repository identity.
                }
            } catch {} // Missing repository identity keeps pull-request links ordinary links.
        }
    }

    func searchProjectEntries(_ query: String, limit: Int) async throws -> AgentConversationFileActions.Entries {
        let context = try context()
        return try await AgentConversationFileActions.searchProjectEntries(query, limit: limit, scope: context.scope,
                                                                           read: { try await context.client.files($0) })
    }

    func filesystemMetadata(_ paths: [String]) async throws -> [AgentConversationFileActions.Metadata?] {
        let context = try context()
        return try await AgentConversationFileActions.filesystemMetadata(paths, scope: context.scope,
                                                                         read: { try await context.client.files($0) })
    }

    func workspaceMedia(_ path: String, cwd: String?) async throws -> AgentConversationFileActions.Media {
        let context = try context(), client = context.client
        return try await AgentConversationFileActions.media(path, cwd: cwd, scope: context.scope,
                                                            ranged: client.supports(.fileByteRanges), read: { try await client.files($0) })
    }

    func writeProjectFile(_ relativePath: String, contents: String, cwd: String?) async throws -> String {
        let context = try context()
        return try await AgentConversationFileActions.writeProjectFile(relativePath, contents: contents, cwd: cwd, scope: context.scope,
            createParents: context.client.supports(.fileWriteParents), read: { try await context.client.files($0) })
    }

    func pullRequestPreview(_ url: URL) async throws -> GitPullRequestPreview {
        let context = try context()
        guard context.client.supports(.pullRequestPreview) else { throw ModelError("Update this project’s server to enable inline pull-request previews.") }
        guard let target = AgentConversationPullRequestPreview.target(from: url) else { throw ModelError("This is not a pull-request link.") }
        return try await AgentConversationPullRequestPreview.perform(target, project: context.scope.project, request: { try await context.client.git($0) })
    }

    func openEditor(_ target: String, reveal: Bool) throws {
        let context = try context()
        guard let position = AgentConversationFileTarget.parse(target) else { throw ModelError("Invalid editor file target.") }
        let relative = try AgentConversationFileActions.resolve(position.path, scope: context.scope)
        if reveal {
            guard context.project.serverId == .local else { throw ModelError("Finder cannot reveal files on another server.") }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: context.project.directory.rawValue).appendingPathComponent(relative)])
            return
        }
        guard context.model.openEditor(project: context.scope.project, path: relative, line: position.line, column: position.column) != nil else {
            throw ModelError("The file could not be opened in Tab.")
        }
    }

    /// Whether the bound project is on this Mac.
    var isLocal: Bool { (try? context())?.project.serverId == .local }

    func openFileInBrowser(_ path: String) throws {
        let context = try context()
        guard context.project.serverId == .local else { throw ModelError("Files on another server cannot open in a browser.") }
        let relative = try AgentConversationFileActions.resolve(path, scope: context.scope)
        let url = URL(fileURLWithPath: context.project.directory.rawValue).appendingPathComponent(relative)
        guard ["html", "htm"].contains(url.pathExtension.lowercased()) else { throw ModelError("Only HTML files open in a browser.") }
        guard NSWorkspace.shared.open(url) else { throw ModelError("No browser could open this file.") }
    }

    func openBrowser(_ url: URL) throws {
        let context = try context()
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              context.model.openBrowser(url: url.absoluteString, project: context.scope.project) != nil else {
            throw ModelError("This link could not be opened in Tab’s browser.")
        }
    }

    func previewFile(_ path: String) async throws {
        let context = try context(), client = context.client
        let relative = try AgentConversationFileActions.resolve(path, scope: context.scope)
        guard case .info(let info) = try await client.files(FilesRequest(project: context.scope.project, action: .stat(ServerPath(relative)))),
              !info.isDirectory else { throw ModelError("The file preview is unavailable.") }
        let loaded = try await AgentConversationFileActions.resource(relative, size: info.size, mimeType: AgentConversationFileActions.mimeType(path: relative),
            scope: context.scope, ranged: client.supports(.fileByteRanges), read: { try await client.files($0) })
        try Task.checkCancellation()
        let next = try AgentConversationMediaWindow(resource: loaded.resource, name: (relative as NSString).lastPathComponent)
        preview?.close()
        preview = next
        next.showWindow(nil)
    }

    /// Opens `target` (a saved conversation) in its pane; with a citation, the quoted
    /// assistant message must still be retained and is scrolled into view.
    func openConversation(_ target: SessionId, project: ProjectId?, citation: AgentAssistantCitation?) async throws {
        let context = try context(), model = context.model
        let targetProjectID = project ?? context.scope.project
        guard model.state.project(targetProjectID) != nil else { throw ModelError("This conversation is unavailable on this Mac.") }
        guard let client = model.sideClient(for: targetProjectID) else { throw ModelError("The cited conversation’s server is offline.") }
        let snapshot = try await AgentConversationSavedNavigation.read(session: target, project: targetProjectID, request: { try await client.agentChat($0) })
        if let citation, !snapshot.items.contains(where: { $0.id == citation.messageId && $0.kind == .assistant }) {
            throw ModelError("The quoted assistant message is no longer retained in this conversation.")
        }
        try Task.checkCancellation()
        guard let targetPane = model.openExistingAgent(snapshot),
              let controller = model.controller(for: targetPane) as? AgentPaneController else {
            throw ModelError("The cited conversation could not be opened.")
        }
        model.focusPane(targetPane)
        guard let citation else { return }
        try await AgentConversationSavedNavigation.awaitTranscript(controller, snapshot: snapshot)
        guard controller.surface.revealCitation(citation) else {
            throw ModelError("The quoted text could not be located in this conversation.")
        }
    }
}
