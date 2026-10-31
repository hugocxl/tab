import AppKit
import WebKit

/// An isolated preview has no script handlers, cookies, or access to the
/// conversation's bundle, attachment map, or other registered resources.
@MainActor
final class AgentConversationMediaWindow: NSWindowController, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private let resource: AgentConversationPreviewResource
    let webView: WKWebView

    convenience init(data: Data, name: String, mimeType: String) throws {
        let resource = AgentConversationRangedResource(length: UInt64(data.count), mimeType: mimeType, revision: UUID().uuidString, read: { offset, length in
            guard offset <= UInt64(data.count), UInt64(length) <= UInt64(data.count) - offset else { throw ModelError("Invalid preview byte range.") }
            return data.subdata(in: Int(offset)..<Int(offset) + Int(length))
        })
        try self.init(resource: resource, name: name)
    }

    init(resource value: AgentConversationRangedResource, name: String) throws {
        let resource = try AgentConversationPreviewResource(resource: value)
        self.resource = resource
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = WKUserContentController()
        configuration.setURLSchemeHandler(resource, forURLScheme: AgentConversationPreviewResource.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = name
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: resource.entryURL))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        var local = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        local?.fragment = nil
        if local?.url == resource.url || local?.url == resource.entryURL || url?.absoluteString == "about:blank" { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated, let url,
           ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
}

@MainActor
private final class AgentConversationPreviewResource: NSObject, WKURLSchemeHandler {
    static let scheme = "tab-media-preview"
    let url: URL
    let entryURL: URL
    let resource: AgentConversationRangedResource
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(resource: AgentConversationRangedResource) throws {
        guard let url = URL(string: Self.scheme + "://resource/" + UUID().uuidString.lowercased()) else { throw ModelError("Invalid media preview URL.") }
        self.url = url
        self.entryURL = resource.mimeType.hasPrefix("audio/") || resource.mimeType.hasPrefix("video/") ? url.appendingPathComponent("index.html") : url
        self.resource = resource
    }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard task.request.url == url || task.request.url == entryURL else { task.didFailWithError(ModelError("This resource does not belong to the preview.")); return }
        if entryURL != url, task.request.url == entryURL {
            let tag = resource.mimeType.hasPrefix("audio/") ? "audio" : "video"
            let html = "<!doctype html><meta name=viewport content='width=device-width'><style>body{margin:0;background:#171717;display:grid;place-items:center;min-height:100vh}video{max-width:100%;max-height:100vh}</style><\(tag) controls preload='metadata' src='\(url.absoluteString)'></\(tag)>"
            let bytes = Data(html.utf8)
            task.didReceive(URLResponse(url: entryURL, mimeType: "text/html", expectedContentLength: bytes.count, textEncodingName: "utf-8"))
            task.didReceive(bytes); task.didFinish(); return
        }
        let id = ObjectIdentifier(task)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks.removeValue(forKey: id) }
            do { try await self.resource.respond(to: task) }
            catch { if !Task.isCancelled { task.didFailWithError(error) } }
        }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { tasks.removeValue(forKey: ObjectIdentifier(task))?.cancel() }
}
