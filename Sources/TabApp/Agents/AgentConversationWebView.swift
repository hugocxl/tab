import AppKit
import CryptoKit
import TabProtocol
import TabCore
import WebKit

/// The pinned, offline conversation renderer. Providers and privileged actions
/// remain native; the page receives immutable snapshots and an explicit bridge.
@MainActor
final class AgentConversationWebView: NSView, WKNavigationDelegate, WKUIDelegate {
    static let bridgeVersion = 1
    static let scheme = "tab-conversation"
    static let allowedActions: Set<String> = [
        "openLink", "openFile", "copy", "runShellCommand", "cite", "navigateCitation",
        "loadMedia", "loadAttachment", "openAttachment", "downloadAttachment", "previewImages",
        "openToolDiff", "openTurnDiff", "approve", "interrupt", "searchProjectEntries",
        "filesystemMetadata", "reportFailure", "taskChange", "openThread", "loadTurnItem", "loadCommandOutput",
        "openEditor", "createAssetUrl", "openPreview", "expandImage", "respondToApproval",
        "pullRequestPreview",
        "useArtifactTemplate", "focusComposer",
        "writeProjectFile",
    ]
    var onAction: ((String, [String: Any]) async throws -> Any?)?
    var onReady: (() -> Void)?
    var onRendered: (() -> Void)?
    private(set) var hasRendered = false
    var onWillReload: (() -> Void)?
    var onCite: ((AgentAssistantCitation) -> Bool)?
    private(set) var supportsFullTimeline = false
    private(set) var supportsNativeViewport = false
    var supportsFullPaneComposition: Bool { supportsTransparentComposition && supportsNativeViewport }
    var onFailure: ((String) -> Void)?
    var onScrollState: ((Bool) -> Void)?
    var onModalChange: ((Bool) -> Void)?
    var onAnchor: ((AgentConversationAnchor) -> Void)?
    var onActionFailure: ((Error) -> Void)?
    private(set) var isModal = false
    private(set) var supportsTransparentComposition = false
    private var nativeComposerRect: NSRect?
    private var overlayRects: [NSRect] = []
    private var viewport: [String: Any]?
    var fetchAttachment: AgentAttachmentCache.Fetch? { didSet { assets.fetchAttachment = fetchAttachment } }
    private(set) var isReady = false
    private(set) var isAtBottom = true
    private(set) var lastDeliveredRevision: UInt64?
    private(set) var renderDiagnostics: [String] = []
    private(set) var renderNotices: [String] = []
    private let assets: AgentConversationAssets
    private let scriptHandler = AgentConversationScriptHandler()
    let webView: WKWebView
    let downloads = AgentConversationDownloadDelegate()
    private var pendingSnapshot: [String: Any]?
    private var deliveryTask: Task<Void, Never>?
    private var actionTasks: [String: Task<Void, Never>] = [:]
    private var evaluations: [UUID: Evaluation] = [:]
    private final class Evaluation {
        var continuation: CheckedContinuation<Any, Error>?
        var deadline: Task<Void, Never>?
        var onFinish: (() -> Void)?
        func finish(_ result: Result<Any, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            deadline?.cancel(); deadline = nil
            onFinish?(); onFinish = nil
            continuation.resume(with: result)
        }
    }
    private var sequence: UInt64 = 0
    private var disposed = false
    private var navigationGeneration: UInt64 = 0
    private var sequenceAtReset: UInt64 = 0
    private var firstRenderDeadline: Task<Void, Never>?
    private let initialRenderTimeout: Duration
    private var remoteFrameOwners: [String: Set<URL>] = [:]
    private var remoteFrameOrder: [String] = []
    private var snapshot: AgentChatSnapshot?
    private var themeName = "dark"
    private var conversationTheme: AgentConversationTheme?
    private var cwd: String?
    private var approvalsEnabled = true
    var capabilities: [String: Bool] = [:] { didSet { if oldValue != capabilities { enqueueSnapshot() } } }
    var project: [String: Any]? { didSet { enqueueSnapshot() } }
    var remote = false { didSet { if oldValue != remote { enqueueSnapshot() } } }
    var connectionState = "cached" { didSet { if oldValue != connectionState { enqueueSnapshot() } } }
    var retainedAssetDescriptorCount: Int { assets.retainedDescriptorCount }
    func prepareHtmlRenderAsset(attachmentID: String) async throws -> URL? {
        for candidate in AgentConversationMcpAsset.htmlRenderCandidates(attachmentID: attachmentID, items: Array(assets.items.values)) {
            // The actual source validates all tool aliases, failure envelopes,
            // and reference fields; native binds that result to retained bytes.
            let result = try await evaluate("return window.TabConversation.htmlRenderReference?.(toolName,output)??null",
                arguments: ["toolName": candidate.ownership.toolName, "output": candidate.ownership.output])
            guard let reference = result as? [String: Any], reference["attachmentId"] as? String == candidate.ownership.attachment.id else { continue }
            return try await prepareMcpAsset(candidate)
        }
        return nil
    }
    func prepareMcpAsset(_ match: AgentConversationMcpAsset.Match) async throws -> URL {
        let data = try await preparedMcpData(match)
        try Task.checkCancellation()
        guard match.ownership.isRetained(in: assets.items) else { throw ModelError("The MCP document is no longer retained.") }
        let revision = SHA256.hash(data: Data(match.ownership.output.utf8)).description
        let identity = "mcp:" + match.ownership.itemID + ":" + match.ownership.attachment.id + ":" + revision
        return try assets.register(data: data, mimeType: "text/html; charset=utf-8", identity: identity,
            refetch: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.preparedMcpData(match)
            }, mcpOwnership: match.ownership)
    }

    private func preparedMcpData(_ match: AgentConversationMcpAsset.Match) async throws -> Data {
        try Task.checkCancellation()
        guard !disposed, isReady, match.ownership.isRetained(in: assets.items), let fetchAttachment else {
            throw ModelError("The retained MCP document is unavailable.")
        }
        let generation = navigationGeneration
        let data = try await fetchAttachment(match.ownership.itemID, match.ownership.attachment)
        try Task.checkCancellation()
        guard !disposed, isReady, generation == navigationGeneration, match.ownership.isRetained(in: assets.items),
              data.count == match.ownership.attachment.byteCount,
              data.count <= (match.publishedHTML ? 25 * 1024 * 1024 : AgentConversationMcpAsset.maximumHTMLBytes),
              let html = String(data: data, encoding: .utf8) else { throw ModelError("The retained MCP HTML is unavailable or changed.") }
        // html_render bytes were prepared at publication by the source server.
        // Its bootstrap is not idempotent and must not be injected a second time.
        if match.publishedHTML { return data }
        let result = try await evaluate("if(typeof window.TabConversation.prepareMcpDocument!=='function')throw new Error('This renderer cannot prepare retained MCP documents');return window.TabConversation.prepareMcpDocument(html,app)",
            arguments: ["html": html, "app": match.reference])
        try Task.checkCancellation()
        guard !disposed, generation == navigationGeneration, match.ownership.isRetained(in: assets.items),
              let prepared = result as? String, let bytes = prepared.data(using: .utf8) else { throw ModelError("The retained MCP document changed during preparation.") }
        return bytes
    }
    func registeredAssetData(_ url: URL) async throws -> Data {
        guard !disposed else { throw ModelError("The conversation was closed.") }
        return try await assets.registeredAssetData(url)
    }
    func registerAsset(data: Data, mimeType: String) throws -> URL {
        try Task.checkCancellation()
        guard !disposed else { throw ModelError("The conversation was closed.") }
        return try assets.register(data: data, mimeType: mimeType, refetch: nil)
    }
    func registerAsset(data: Data, mimeType: String, identity: String? = nil, refetch: @escaping @MainActor () async throws -> Data) throws -> URL {
        try Task.checkCancellation()
        guard !disposed else { throw ModelError("The conversation was closed.") }
        return try assets.register(data: data, mimeType: mimeType, identity: identity, refetch: refetch)
    }
    func registerRangedAsset(length: UInt64, mimeType: String, revision: String,
                            identity: String? = nil,
                            read: @escaping AgentConversationRangedResource.Read) throws -> URL {
        try Task.checkCancellation()
        guard !disposed else { throw ModelError("The conversation was closed.") }
        return try assets.registerRanged(.init(length: length, mimeType: mimeType, revision: revision, read: read), identity: identity)
    }


    static var bundleRoot: URL? { Bundle.module.url(forResource: "ConversationRenderer", withExtension: nil) }
    static var isAvailable: Bool { bundleRoot.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) } ?? false }

    convenience init() { self.init(bundleRoot: Self.bundleRoot) }

    init(bundleRoot: URL?, initialRenderTimeout: Duration = .seconds(15)) {
        self.initialRenderTimeout = initialRenderTimeout
        assets = AgentConversationAssets(root: bundleRoot)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(assets, forURLScheme: Self.scheme)
        configuration.userContentController.add(scriptHandler, name: "tabConversation")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        scriptHandler.owner = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        downloads.onFailure = { [weak self] in self?.onActionFailure?($0) }
        // WebKit's macOS background accessor is not public API. This is the
        // pre-existing transparency mechanism, now guarded for compatibility;
        // opaque runtimes retain the body-only layout above the native composer.
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")),
           webView.responds(to: NSSelectorFromString("_drawsBackground")) {
            webView.setValue(false, forKey: "drawsBackground")
            supportsTransparentComposition = !webView.isOpaque
        }
        webView.setAccessibilityLabel("Agent conversation")
        addSubview(webView)
        guard bundleRoot != nil else { return }
        if let url = URL(string: "\(Self.scheme)://bundle/index.html") { webView.load(URLRequest(url: url)) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); webView.frame = bounds }

    func setViewport(composer: NSRect?) {
        nativeComposerRect = supportsFullPaneComposition ? composer : nil
        var next: [String: Any] = ["mode": nativeComposerRect == nil ? "conversation-body" : "full-pane",
                                   "width": bounds.width, "height": bounds.height]
        if let rect = nativeComposerRect {
            next["composer"] = ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
        }
        if !NSDictionary(dictionary: viewport ?? [:]).isEqual(to: next) {
            viewport = next; enqueueSnapshot()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !isModal, let composer = nativeComposerRect, composer.contains(local),
           !overlayRects.contains(where: { $0.contains(local) }) { return nil }
        return super.hitTest(point)
    }

    private func setOverlays(modal: Bool, rects: [NSRect]) {
        overlayRects = rects
        guard isModal != modal else { return }
        isModal = modal
        onModalChange?(modal)
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        setOverlays(modal: false, rects: [])
        resetPage()
        pendingSnapshot = nil; snapshot = nil
        assets.cancelAll()
        webView.stopLoading()
        webView.isHidden = true
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tabConversation")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        scriptHandler.owner = nil
    }

    func update(_ snapshot: AgentChatSnapshot, theme: AppTheme, cwd: String?) {
        guard !disposed else { return }
        if let bound = self.snapshot, bound.session != snapshot.session || bound.project != snapshot.project {
            // Pane controllers and their delegates are permanently session-scoped.
            // A different session must get a fresh host, not inherit these privileges.
            dispose()
            onFailure?("A different conversation requires a new renderer. The native conversation remains available.")
            return
        }
        self.snapshot = snapshot
        webView.underPageBackgroundColor = theme.card
        conversationTheme = AgentConversationTheme(theme)
        themeName = conversationTheme?.mode ?? "dark"
        self.cwd = cwd
        assets.items = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
        enqueueSnapshot()
    }
    func updateTheme(_ theme: AppTheme) {
        webView.underPageBackgroundColor = theme.card
        let next = AgentConversationTheme(theme)
        guard next != conversationTheme else { return }
        conversationTheme = next
        themeName = next.mode
        enqueueSnapshot()
    }
    func setApprovalsEnabled(_ enabled: Bool) {
        guard enabled != approvalsEnabled else { return }
        approvalsEnabled = enabled; enqueueSnapshot()
    }
    func scrollToEnd() {
        isAtBottom = true
        guard isReady else { return }
        webView.callAsyncJavaScript("window.TabConversation.scrollToEnd?.()", arguments: [:], in: nil, in: .page) { _ in }
    }

    private func enqueueSnapshot() {
        guard !disposed, let snapshot else { return }
        if !hasRendered, firstRenderDeadline == nil {
            let generation = navigationGeneration
            firstRenderDeadline = Task { [weak self, initialRenderTimeout] in
                do { try await Task.sleep(for: initialRenderTimeout) } catch { return }
                guard let self, !self.disposed, !self.hasRendered,
                      self.navigationGeneration == generation else { return }
                self.fail("The conversation renderer did not finish loading. The native conversation remains available.")
            }
        }
        do {
            sequence &+= 1
            var value = try Self.payload(snapshot, theme: themeName, cwd: cwd, sequence: sequence, approvalsEnabled: approvalsEnabled)
            value["capabilities"] = (["nativeActions": true, "approvals": approvalsEnabled, "attachments": true, "cite": true]).merging(capabilities) { _, latest in latest }
            if let conversationTheme { value["palette"] = conversationTheme.payload }
            value["remote"] = remote
            value["connectionState"] = connectionState
            if let viewport { value["viewport"] = viewport }
            if let project { value["projects"] = [project] }
            pendingSnapshot = value
            deliverPending()
        } catch { fail("The conversation snapshot could not be encoded: \(error.localizedDescription)") }
    }

    func evaluate(_ body: String, arguments: [String: Any] = [:], timeout: Duration = .seconds(15)) async throws -> Any {
        try Task.checkCancellation()
        guard !disposed else { throw CancellationError() }
        let evaluation = Evaluation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                evaluation.continuation = continuation
                evaluation.onFinish = { [weak self] in self?.evaluations.removeValue(forKey: id) }
                evaluations[id] = evaluation
                evaluation.deadline = Task { [weak evaluation] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    evaluation?.finish(.failure(ModelError("The conversation renderer did not finish this operation in time.")))
                }
                webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { [weak evaluation] result in
                    evaluation?.finish(result)
                }
            }
        } onCancel: {
            Task { @MainActor [weak evaluation] in evaluation?.finish(.failure(CancellationError())) }
        }
    }

    private func deliverPending() {
        guard isReady, !disposed, deliveryTask == nil, pendingSnapshot != nil else { return }
        let generation = navigationGeneration
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.navigationGeneration == generation { self.deliveryTask = nil } }
            while !Task.isCancelled, self.navigationGeneration == generation, self.isReady, let payload = self.pendingSnapshot {
                self.pendingSnapshot = nil
                do {
                    _ = try await self.evaluate("window.TabConversation.update(snapshot)", arguments: ["snapshot": payload])
                    guard !Task.isCancelled, self.navigationGeneration == generation else { return }
                    self.lastDeliveredRevision = (payload["revision"] as? NSNumber)?.uint64Value
                } catch {
                    guard !Task.isCancelled else { return }
                    self.fail("The conversation renderer could not update: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    static func payload(_ snapshot: AgentChatSnapshot, theme: String, cwd: String?, sequence: UInt64 = 0, approvalsEnabled: Bool = true) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(snapshot)
        guard var payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw ModelError("Invalid conversation snapshot.") }
        payload["bridgeVersion"] = bridgeVersion
        payload["sequence"] = sequence
        payload["sessionId"] = snapshot.session.description
        payload["projectId"] = snapshot.project.description
        payload["theme"] = theme
        if let cwd { payload["cwd"] = cwd }
        payload["turns"] = payload["turns"] ?? []
        if var items = payload["items"] as? [[String: Any]] {
            for index in items.indices {
                guard let id = items[index]["id"] as? String, var attachments = items[index]["attachments"] as? [[String: Any]] else { continue }
                for attachment in attachments.indices {
                    if let original = attachments[attachment]["id"] as? String {
                        attachments[attachment]["bridgeId"] = bridgeAttachmentID(item: id, attachment: original)
                    }
                }
                items[index]["attachments"] = attachments
            }
            payload["items"] = items
        }
        let formatter = ISO8601DateFormatter()
        let dates = Dictionary((snapshot.turns ?? []).map { ($0.userItemID, formatter.string(from: $0.startedAt)) }, uniquingKeysWith: { _, last in last })
        payload["messages"] = snapshot.items.compactMap { item -> [String: Any]? in
            guard item.kind == .user || item.kind == .assistant else { return nil }
            var message: [String: Any] = ["id": item.id, "role": item.kind == .user ? "user" : "assistant", "text": item.text, "isStreaming": !item.isComplete]
            if let date = dates[item.id] { message["createdAt"] = date }
            if let attachments = item.attachments {
                message["attachments"] = attachments.map { attachment in
                    ["id": bridgeAttachmentID(item: item.id, attachment: attachment.id), "nativeId": attachment.id,
                     "name": attachment.name, "mimeType": attachment.mimeType,
                     "byteCount": attachment.byteCount, "url": attachmentURL(item: item.id, attachment: attachment.id)?.absoluteString ?? ""] as [String: Any]
                }
            }
            return message
        }
        payload["font"] = ["interfaceSize": 16, "promptSize": 14, "codeSize": 13]
        payload["capabilities"] = ["nativeActions": true, "approvals": approvalsEnabled, "attachments": true]
        return payload
    }

    static func bundledAssetURL(_ url: URL, root: URL?) -> URL? { AgentConversationAssets.assetURL(url, root: root) }

    static func isRendererEntryURL(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == "bundle" && (url.path == "/index.html" || url.path == "/" || url.path.isEmpty)
    }

    static func bridgeAttachmentID(item: String, attachment: String) -> String {
        let key = "\(item.utf8.count):" + item + attachment
        return "tab-attachment-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func ownedAttachment(_ sourceID: String, itemID: String? = nil, snapshot: AgentChatSnapshot)
        -> (item: AgentChatItem, attachment: AgentChatAttachmentDescriptor)? {
        let owners = snapshot.items.filter { itemID == nil || $0.id == itemID }.flatMap { item in
            (item.attachments ?? []).map { (item: item, attachment: $0) }
        }
        if let exact = owners.first(where: { bridgeAttachmentID(item: $0.item.id, attachment: $0.attachment.id) == sourceID }) { return exact }
        // Older renderer pages used raw IDs; accept them only with unambiguous ownership.
        let legacy = owners.filter { $0.attachment.id == sourceID }
        return legacy.count == 1 ? legacy.first : nil
    }

    static func attachmentURL(item: String, attachment: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme; components.host = "bundle"; components.path = "/__attachment"
        components.queryItems = [.init(name: "item", value: item), .init(name: "attachment", value: attachment)]
        return components.url
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard !disposed, message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.request.url.map(Self.isRendererEntryURL) == true,
              let body = message.body as? [String: Any], body["bridgeVersion"] as? Int == Self.bridgeVersion,
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            guard (body["features"] as? [String: Any])?["fullTimeline"] as? Bool == true,
                  (body["features"] as? [String: Any])?["renderedHandshake"] as? Bool == true else {
                fail("The conversation renderer is incompatible. The native conversation remains available.")
                return
            }
            supportsFullTimeline = (body["features"] as? [String: Any])?["fullTimeline"] as? Bool == true
            supportsNativeViewport = (body["features"] as? [String: Any])?["nativeViewport"] as? Bool == true
            isReady = true
            onReady?()
            deliverPending()
        case "rendered":
            guard isReady, !hasRendered,
                  body["sessionId"] as? String == snapshot?.session.description,
                  let renderedSequence = (body["sequence"] as? NSNumber)?.uint64Value,
                  renderedSequence > sequenceAtReset, renderedSequence <= sequence else { return }
            hasRendered = true
            firstRenderDeadline?.cancel(); firstRenderDeadline = nil
            onRendered?()
        case "error": fail(body["message"] as? String ?? "The conversation renderer reported an error.")
        case "renderDiagnostic":
            let message = String((body["message"] as? String ?? "A source component used its fallback.").prefix(4096))
            let scope = body["scope"] as? String ?? "component"
            let scoped = "[" + scope + "] " + message
            if scope == "resize-observer" {
                renderNotices.append(scoped)
                if renderNotices.count > 16 { renderNotices.removeFirst(renderNotices.count - 16) }
                Log.app.debug("conversation layout notice: \(message)")
            } else {
                renderDiagnostics.append(scoped)
                if renderDiagnostics.count > 16 { renderDiagnostics.removeFirst(renderDiagnostics.count - 16) }
                Log.app.error("conversation component diagnostic: \(scoped)")
            }
        case "scroll", "atEnd":
            guard isReady else { return }
            if let value = (body["isAtBottom"] ?? body["isAtEnd"]) as? Bool { isAtBottom = value; onScrollState?(value) }
        case "overlays":
            guard isReady else { return }
            let rects = (body["rects"] as? [[String: Any]] ?? []).prefix(128).compactMap { value -> NSRect? in
                guard let x = value["x"] as? Double, let y = value["y"] as? Double,
                      let width = value["width"] as? Double, let height = value["height"] as? Double,
                      [x, y, width, height].allSatisfy(\.isFinite), width >= 0, height >= 0 else { return nil }
                return NSRect(x: x, y: y, width: width, height: height)
            }
            setOverlays(modal: body["modal"] as? Bool == true, rects: Array(rects))
        case "anchor":
            guard isReady else { return }
            if let anchor = AgentConversationAnchor(body) { onAnchor?(anchor) }
        case "height": break // The source renderer owns the full viewport, not a nested page-height surface.
        case "action":
            guard isReady else { return }
            guard let id = body["requestId"] as? String, !id.isEmpty, id.utf8.count <= 128,
                  let action = body["action"] as? [String: Any], let kind = action["kind"] as? String else { return }
            guard Self.allowedActions.contains(kind) else { reply(id, error: "Unsupported native action: \(kind)"); return }
            let generation = navigationGeneration
            let taskID = "\(generation):" + id
            guard actionTasks[taskID] == nil else { return }
            actionTasks[taskID] = Task { [weak self] in
                guard let self else { return }
                defer { self.actionTasks.removeValue(forKey: taskID) }
                do {
                    guard let handler = self.onAction else { throw ModelError("This conversation action is unavailable.") }
                    let result = try await handler(kind, action)
                    guard !Task.isCancelled, self.navigationGeneration == generation else { return }
                    self.reply(id, result: result)
                } catch {
                    if !Task.isCancelled, self.navigationGeneration == generation { self.reply(id, error: error.localizedDescription) }
                }
            }
        default: break
        }
    }
    private func reply(_ id: String, result: Any? = nil, error: String? = nil) {
        guard !disposed, isReady else { return }
        var payload: [String: Any] = ["requestId": id, "ok": error == nil]
        if let error { payload["error"] = error }
        else { payload["result"] = result ?? NSNull() }
        webView.callAsyncJavaScript("window.TabConversation.resolve(reply)", arguments: ["reply": payload], in: nil, in: .page) { _ in }
    }
    private func resetPage() {
        sequenceAtReset = sequence
        firstRenderDeadline?.cancel(); firstRenderDeadline = nil
        remoteFrameOwners.removeAll(); remoteFrameOrder.removeAll()
        setOverlays(modal: false, rects: [])
        downloads.cancelAll()
        navigationGeneration &+= 1
        isReady = false
        hasRendered = false
        supportsFullTimeline = false
        supportsNativeViewport = false
        lastDeliveredRevision = nil
        actionTasks.values.forEach { $0.cancel() }; actionTasks.removeAll()
        deliveryTask?.cancel(); deliveryTask = nil
        for evaluation in Array(evaluations.values) { evaluation.finish(.failure(CancellationError())) }
    }
    private func fail(_ message: String) {
        resetPage()
        onFailure?(message)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !disposed else { return }
        resetPage()
        onWillReload?()
        // A new realm has no state even if the old realm consumed the pending update.
        enqueueSnapshot()
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard !disposed, isReady, prompt == "__tab_conversation_cite_v1__", frame.isMainFrame,
              frame.request.url.map(Self.isRendererEntryURL) == true,
              let text = defaultText, text.utf8.count <= 160_000, let data = text.data(using: .utf8),
              let citation = try? JSONDecoder().decode(AgentAssistantCitation.self, from: data), citation.isValid else {
            completionHandler(nil); return
        }
        completionHandler(onCite?(citation) == true ? "true" : "false")
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }


    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.shouldPerformDownload, navigationAction.sourceFrame.isMainFrame,
           navigationAction.sourceFrame.request.url.map(Self.isRendererEntryURL) == true {
            decisionHandler(.download)
            return
        }
        let allowed = navigationAction.targetFrame?.isMainFrame == false
            ? allowsSubframe(url, source: navigationAction.sourceFrame)
            : Self.isRendererEntryURL(url)
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed, navigationAction.navigationType == .linkActivated {
            Task { [weak self] in
                guard let self else { return }
                do { _ = try await self.onAction?("openLink", ["kind": "openLink", "url": url.absoluteString]) }
                catch { self.onActionFailure?(error) }
            }
        }
    }
    private func allowsSubframe(_ url: URL, source: WKFrameInfo) -> Bool {
        if assets.owns(url) { return true }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !source.isMainFrame,
              let parent = source.request.url else { return false }
        let owners: Set<URL>
        if assets.isPreparedDocument(parent) { owners = [parent] }
        else { owners = Set((remoteFrameOwners[parent.absoluteString] ?? []).filter { assets.isPreparedDocument($0) }) }
        guard !owners.isEmpty else { return false }
        // The actual document CSP decides which declared origins may load.
        // Its HTTP/iframe sandbox propagates to descendants; no subframe may
        // bridge. Retain ownership ancestry where public WK frame URLs expose it.
        let key = url.absoluteString
        if remoteFrameOwners[key] == nil {
            remoteFrameOrder.append(key)
            if remoteFrameOrder.count > 1024 { remoteFrameOwners.removeValue(forKey: remoteFrameOrder.removeFirst()) }
        }
        remoteFrameOwners[key, default: []].formUnion(owners)
        return true
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = downloads
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = downloads
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        fail(error.localizedDescription)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        fail(error.localizedDescription)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        fail("The conversation renderer stopped. The native conversation is still available.")
    }
}

@MainActor
private final class AgentConversationScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: AgentConversationWebView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}

@MainActor
private final class AgentConversationAssets: NSObject, WKURLSchemeHandler {
    let root: URL?
    var items: [String: AgentChatItem] = [:]
    var fetchAttachment: AgentAttachmentCache.Fetch?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private struct Resource {
        var bytes: Data?
        let mime: String
        let count: Int
        let digest: SHA256.Digest
        let refetch: (@MainActor () async throws -> Data)?
        let mcpOwnership: AgentConversationMcpAsset.Ownership?
    }
    private var registered: [String: Resource] = [:]
    private var registeredIdentity: [String: String] = [:]
    private var ranged: [String: AgentConversationRangedResource] = [:]
    private var rangedIdentity: [String: String] = [:]
    private static let metadataLimit = 4096
    var retainedDescriptorCount: Int { registered.count + ranged.count }
    private var registeredOrder: [String] = []
    private var resourceTasks: [String: Task<Data, Error>] = [:]
    private var generation: UInt64 = 0
    private static let byteLimit = 64 * 1024 * 1024

    func register(data: Data, mimeType: String, identity: String? = nil, refetch: (@MainActor () async throws -> Data)?,
                  mcpOwnership: AgentConversationMcpAsset.Ownership? = nil) throws -> URL {
        guard data.count <= Self.byteLimit else { throw ModelError("This conversation asset exceeds the preview limit.") }
        let digest = SHA256.hash(data: data)
        let key = identity.map { "\($0.utf8.count):" + $0 + ":" + mimeType + ":" + (mcpOwnership == nil ? "raw:" : "mcp:") + digest.description }
        if let key, let existing = registeredIdentity[key] { return try Self.resourceURL(existing) }
        guard registered.count + ranged.count < Self.metadataLimit else { throw ModelError("This conversation has reached its retained media limit. Reopen the conversation to load more media.") }
        let id = UUID().uuidString.lowercased()
        let record = Resource(bytes: nil, mime: mimeType, count: data.count, digest: digest, refetch: refetch, mcpOwnership: mcpOwnership)
        registered[id] = record
        do { try cache(data, for: id) }
        catch { registered.removeValue(forKey: id); throw error }
        if let key { registeredIdentity[key] = id }
        guard let url = URL(string: "tab-conversation://bundle/__resource/" + id) else { throw ModelError("Invalid conversation asset.") }
        return url
    }

    func registerRanged(_ resource: AgentConversationRangedResource, identity: String?) throws -> URL {
        let key = identity.map { "\($0.utf8.count):" + $0 + ":" + resource.revision + ":" + resource.mimeType + ":" + String(resource.length) }
        if let key, let existing = rangedIdentity[key] { return try Self.resourceURL(existing) }
        guard registered.count + ranged.count < Self.metadataLimit else { throw ModelError("This conversation has reached its retained media limit. Reopen the conversation to load more media.") }
        let id = UUID().uuidString.lowercased()
        ranged[id] = resource
        if let key { rangedIdentity[key] = id }
        return try Self.resourceURL(id)
    }

    private static func resourceURL(_ id: String) throws -> URL {
        guard let url = URL(string: "tab-conversation://bundle/__resource/" + id) else {
            throw ModelError("Invalid conversation asset.")
        }
        return url
    }

    private static func resourceID(_ url: URL) -> String? {
        guard url.scheme == AgentConversationWebView.scheme else { return nil }
        if url.host == "resource" { return String(url.path.dropFirst()) }
        if url.host == "bundle", url.path.hasPrefix("/__resource/") { return String(url.path.dropFirst("/__resource/".count)) }
        return nil
    }

    func owns(_ url: URL) -> Bool {
        guard url.scheme == AgentConversationWebView.scheme else { return false }
        if let id = Self.resourceID(url) {
            if let resource = registered[id] { return resource.mcpOwnership?.isRetained(in: items) ?? true }
            return ranged[id] != nil
        }
        guard url.host == "attachment" || (url.host == "bundle" && url.path == "/__attachment") else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let itemID = query.first(where: { $0.name == "item" })?.value,
              let attachmentID = query.first(where: { $0.name == "attachment" })?.value else { return false }
        return items[itemID]?.attachments?.contains(where: { $0.id == attachmentID }) == true
    }
    func isPreparedDocument(_ url: URL) -> Bool {
        guard let id = Self.resourceID(url), let owner = registered[id]?.mcpOwnership else { return false }
        return owner.isRetained(in: items)
    }

    private func cache(_ data: Data, for id: String) throws {
        var cost = registered.values.reduce(0) { $0 + ($1.bytes?.count ?? 0) }
        cost -= registered[id]?.bytes?.count ?? 0
        while cost + data.count > Self.byteLimit {
            guard let candidate = registeredOrder.first(where: { $0 != id && registered[$0]?.refetch != nil }),
                  var resource = registered[candidate] else { throw ModelError("The conversation asset cache is full.") }
            cost -= resource.bytes?.count ?? 0
            resource.bytes = nil
            registered[candidate] = resource
            registeredOrder.removeAll { $0 == candidate }
        }
        registered[id]?.bytes = data
        registeredOrder.removeAll { $0 == id }
        registeredOrder.append(id)
    }

    func registeredAssetData(_ url: URL) async throws -> Data {
        guard let id = Self.resourceID(url) else { throw ModelError("Unknown conversation asset.") }
        if let resource = ranged[id] {
            guard resource.length <= UInt64(Self.byteLimit) else { throw ModelError("This asset is too large to copy into memory.") }
            var data = Data(), offset: UInt64 = 0
            while offset < resource.length {
                try Task.checkCancellation()
                let count = UInt32(min(UInt64(AgentConversationRangedResource.chunkSize), resource.length - offset))
                let bytes = try await resource.read(offset, count)
                guard bytes.count == Int(count) else { throw ModelError("Incomplete media range.") }
                data.append(bytes); offset += UInt64(count)
            }
            return data
        }
        return try await resourceData(id)
    }

    private func resourceData(_ id: String) async throws -> Data {
        guard let resource = registered[id] else { throw ModelError("This conversation asset is no longer owned by the page.") }
        if let owner = resource.mcpOwnership, !owner.isRetained(in: items) { throw ModelError("This MCP document is no longer retained.") }
        if let bytes = resource.bytes {
            registeredOrder.removeAll { $0 == id }; registeredOrder.append(id)
            return bytes
        }
        if let pending = resourceTasks[id] { return try await pending.value }
        guard let refetch = resource.refetch else { throw ModelError("This conversation asset cannot be reloaded.") }
        let epoch = generation
        let task = Task {
            let bytes = try await refetch()
            try Task.checkCancellation()
            guard bytes.count == resource.count, SHA256.hash(data: bytes) == resource.digest else {
                throw ModelError("This file changed after its preview was opened. Refresh the preview to load the new version.")
            }
            return bytes
        }
        resourceTasks[id] = task
        defer { if generation == epoch { resourceTasks.removeValue(forKey: id) } }
        let bytes = try await task.value
        guard generation == epoch, registered[id] != nil else { throw CancellationError() }
        try cache(bytes, for: id)
        return bytes
    }
    init(root: URL?) { self.root = root?.resolvingSymlinksInPath().standardizedFileURL }
    func cancelAll() {
        generation &+= 1
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        resourceTasks.values.forEach { $0.cancel() }; resourceTasks.removeAll()
        registered.removeAll(); registeredIdentity.removeAll(); registeredOrder.removeAll(); ranged.removeAll(); rangedIdentity.removeAll()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel() }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks.removeValue(forKey: id) }
            do {
                guard let url = urlSchemeTask.request.url else { throw ModelError("Invalid conversation asset URL.") }
                let data: Data, mime: String
                if let resourceID = Self.resourceID(url) {
                    if let resource = self.ranged[resourceID] {
                        try await resource.respond(to: urlSchemeTask)
                        return
                    }
                    guard let resource = self.registered[resourceID] else { throw ModelError("This asset is no longer retained.") }
                    data = try await self.resourceData(resourceID); mime = resource.mime
                } else if url.host == "attachment" || (url.host == "bundle" && url.path == "/__attachment") {
                    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    guard let itemID = query.first(where: { $0.name == "item" })?.value,
                          let attachmentID = query.first(where: { $0.name == "attachment" })?.value,
                          let descriptor = self.items[itemID]?.attachments?.first(where: { $0.id == attachmentID }),
                          let fetch = self.fetchAttachment else { throw ModelError("This attachment does not belong to a retained message.") }
                    data = try await fetch(itemID, descriptor)
                    mime = descriptor.mimeType
                } else if url.host == "bundle" {
                    guard let file = Self.assetURL(url, root: self.root) else { throw ModelError("The conversation asset is outside its bundle.") }
                    data = try await Task.detached(priority: .utility) { try Data(contentsOf: file) }.value
                    mime = Self.mimeType(file.pathExtension)
                } else { throw ModelError("Unknown conversation asset.") }
                guard !Task.isCancelled else { return }
                let owned = url.host != "bundle" || url.path.hasPrefix("/__")
                var headers = ["Content-Type": mime, "Content-Length": String(data.count), "X-Content-Type-Options": "nosniff"]
                if owned {
                    headers["Cache-Control"] = "private, no-store"
                    // Same-origin byte fetches are needed by source copy/save.
                    // An owned HTML file must still be inert if embedded directly.
                    headers["Content-Security-Policy"] = "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data: blob: tab-conversation:"
                    if let resourceID = Self.resourceID(url), self.registered[resourceID]?.mcpOwnership != nil {
                        // Exact pinned HTML sandbox header. The source helper
                        // inserted the app's stricter document CSP before scripts;
                        // McpAppFrame further excludes popup/download permissions.
                        headers["Content-Security-Policy"] = "sandbox allow-scripts allow-forms allow-popups allow-downloads"
                    }
                }
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { throw ModelError("Invalid asset response.") }
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch { if !Task.isCancelled { urlSchemeTask.didFailWithError(error) } }
        }
    }
    static func assetURL(_ url: URL, root: URL?) -> URL? {
        guard let root, url.scheme == AgentConversationWebView.scheme, url.host == "bundle" else { return nil }
        let path = url.path.isEmpty || url.path == "/" ? "index.html" : String(url.path.dropFirst())
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
    private static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json", "map": return "application/json"
        case "wasm": return "application/wasm"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}
