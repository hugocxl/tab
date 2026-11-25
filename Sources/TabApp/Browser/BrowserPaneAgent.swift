import AppKit
import TabClient
import WebKit

/// What agents do to a browser pane: run the ref runtime, send real mouse
/// and keyboard events, wait for the page to settle, and take screenshots.
extension BrowserPaneController {
    static let logCaptureScript = WKUserScript(source: BrowserAgentScripts.logCapture, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false, in: .page)

    /// Marks the pane as driven by an agent: from now on its page logs are
    /// captured, starting with the page on screen.
    func beginAgentControl() {
        guard !agent.drive(), let webView = ensureWebView() else { return }
        webView.configuration.userContentController.addUserScript(Self.logCaptureScript)
        webView.evaluateJavaScript(BrowserAgentScripts.logCapture, in: nil, in: .page) { _ in }
    }

    // MARK: Layout

    /// Pins the page to the pane, or to the viewport an agent set.
    func layOutWebView() {
        guard let webView, let content = webView.superview else { return }
        NSLayoutConstraint.deactivate(webViewConstraints)
        webView.translatesAutoresizingMaskIntoConstraints = false
        if let viewport {
            webViewConstraints = [
                webView.topAnchor.constraint(equalTo: content.topAnchor),
                webView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                webView.widthAnchor.constraint(equalToConstant: viewport.width),
                webView.heightAnchor.constraint(equalToConstant: viewport.height),
            ]
            content.clipsToBounds = true
        } else {
            webViewConstraints = [
                webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                webView.topAnchor.constraint(equalTo: content.topAnchor),
                webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(webViewConstraints)
        content.layoutSubtreeIfNeeded()
        if let viewport, webView.window == nil { webView.setFrameSize(viewport) }
    }

    /// Gives the page a fixed size in CSS pixels, or fills the pane again with `nil`.
    func setViewport(_ size: CGSize?) {
        guard ensureWebView() != nil else { return }
        viewport = size.map { CGSize(width: $0.width * zoom, height: $0.height * zoom) }
        layOutWebView()
    }

    // MARK: Runtime

    /// Runs `body` with the ref runtime as `A`, installing it first when the
    /// page has none, and returns its value. A dialog that opens meanwhile
    /// ends the call with `.dialog`.
    func agentRun(_ body: String, timeout: TimeInterval = 10) async throws -> AgentOutcome {
        guard let webView = ensureWebView() else { throw BrowserScripts.Failure("the built-in browser is disabled") }
        if let dialog = agent.dialog { throw Self.dialogOpen(dialog) }
        for _ in 0 ..< 2 {
            let outcome = try await runWatchingDialogs(BrowserAgentScripts.call(body), timeout: timeout)
            guard case .value(let reply) = outcome else { return outcome }
            if reply["missing"] == .bool(true) {
                _ = try await BrowserPage.run(BrowserAgentScripts.install(start: agent.nextRef), in: webView,
                                              timeout: timeout, world: BrowserAgentScripts.world)
                continue
            }
            if case .int(let next) = reply["next"] { agent.nextRef = max(agent.nextRef, Int(next)) }
            if let error = reply["error"]?.string { throw BrowserScripts.Failure(error) }
            return .value(reply["value"] ?? .null)
        }
        throw BrowserScripts.Failure("the page didn't take Tab's automation script")
    }

    /// `agentRun`, failing when a dialog opens instead.
    func agentValue(_ body: String, timeout: TimeInterval = 10) async throws -> JSONValue {
        switch try await agentRun(body, timeout: timeout) {
        case .value(let value): return value
        case .dialog(let dialog): throw Self.dialogOpen(dialog)
        }
    }

    enum AgentOutcome {
        case value(JSONValue)
        case dialog(PendingDialog)
    }

    static func dialogOpen(_ dialog: PendingDialog) -> BrowserScripts.Failure {
        BrowserScripts.Failure("the page shows a dialog: \(dialog.summary); answer it with tab browser dialog BROWSER accept|dismiss")
    }

    private func runWatchingDialogs(_ script: String, timeout: TimeInterval) async throws -> AgentOutcome {
        guard let webView = ensureWebView() else { throw BrowserScripts.Failure("the built-in browser is disabled") }
        let agent = agent
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            var token = 0
            token = agent.watchDialogs { dialog in
                guard once.claim() else { return }
                agent.unwatch(token)
                continuation.resume(returning: .dialog(dialog))
            }
            Task { @MainActor in
                do {
                    let value = try await BrowserPage.run(script, in: webView, timeout: timeout, world: BrowserAgentScripts.world)
                    guard once.claim() else { return }
                    agent.unwatch(token)
                    continuation.resume(returning: .value(value))
                } catch {
                    guard once.claim() else { return }
                    agent.unwatch(token)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Native input

    /// Whether mouse and keyboard events can go to the page: it must be in a window.
    var takesNativeInput: Bool { webView?.window != nil }

    /// A point `prepare` returned, in the window's coordinates.
    func windowPoint(_ prepared: JSONValue) -> NSPoint? {
        guard let webView, webView.window != nil, let x = prepared["x"]?.number, let y = prepared["y"]?.number else {
            return nil
        }
        let viewport = prepared["viewport"]?.number ?? 0
        let scale = viewport > 0 ? webView.bounds.width / viewport : 1
        let local = NSPoint(x: x * scale, y: webView.isFlipped ? y * scale : webView.bounds.height - y * scale)
        return webView.convert(local, to: nil)
    }

    func sendMouse(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1) {
        guard let webView, let window = webView.window,
              let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0)
        else { return }
        switch type {
        case .leftMouseDown: webView.mouseDown(with: event)
        case .leftMouseUp: webView.mouseUp(with: event)
        default: webView.mouseMoved(with: event)
        }
    }

    func click(at point: NSPoint) {
        sendMouse(.mouseMoved, at: point)
        sendMouse(.leftMouseDown, at: point)
        sendMouse(.leftMouseUp, at: point)
    }

    func sendKey(_ key: BrowserKey) {
        guard let webView, let window = webView.window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: key.modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: key.characters,
                                               charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                               isARepeat: false, keyCode: key.keyCode)
            else { continue }
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
    }

    // MARK: Settling

    /// Waits until a load the last action started finishes, the DOM stops
    /// changing and no fetch or XHR is pending, for at most `timeout`.
    func settle(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        for _ in 0 ..< 3 {
            let loads = page.loads
            while page.loading, Date() < deadline, agent.dialog == nil {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            guard agent.dialog == nil else { return }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.05 else { return }
            let limit = Int(min(remaining, 3) * 1000)
            _ = try? await agentRun("return await A.quiet(150, \(limit));", timeout: remaining)
            while agent.pendingRequests > 0, Date() < deadline, agent.dialog == nil {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            if !page.loading, page.loads == loads { return }
        }
    }

    // MARK: Screenshots

    struct ScreenshotOptions {
        var format = BrowserImage.Format.png
        var quality = 80
        var maxWidth: Int?
        var full = false
        /// The element's box in the page's viewport, in CSS pixels.
        var element: CGRect?
    }

    /// A picture of the page, its element, or all of it, one image pixel per CSS pixel unless narrower.
    func screenshot(_ options: ScreenshotOptions) async throws -> Data {
        guard let webView = ensureWebView() else { throw BrowserScripts.Failure("the built-in browser is disabled") }
        if webView.window == nil, webView.bounds.isEmpty {
            webView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        }
        let cssScale = webView.bounds.width > 0 ? max(zoom, 0.01) : 1
        var rect = webView.bounds
        if let element = options.element {
            let height = element.height * cssScale
            let top = element.minY * cssScale
            rect = NSRect(x: element.minX * cssScale, y: webView.isFlipped ? top : webView.bounds.height - top - height,
                          width: element.width * cssScale, height: height).intersection(webView.bounds)
            guard !rect.isEmpty else { throw BrowserScripts.Failure("the element is outside the visible page") }
        }
        let image: CGImage
        var pointWidth = rect.width
        if !options.full, webView.window?.isVisible == true,
           let snapshot = try? await takeSnapshot(webView, rect: rect),
           let cgImage = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            image = cgImage
        } else {
            let configuration = WKPDFConfiguration()
            configuration.rect = options.full ? nil : rect
            let data = try await BrowserPage.pdf(in: webView, configuration: configuration)
            guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
                  let page = document.page(at: 1)
            else { throw BrowserScripts.Failure("the screenshot could not be encoded") }
            let box = page.getBoxRect(.mediaBox)
            pointWidth = box.width
            let scale = window(of: webView)?.backingScaleFactor ?? 2
            let width = max(Int(box.width * scale), 1), height = max(Int(box.height * scale), 1)
            guard width * height <= 400_000_000,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw BrowserScripts.Failure("the page is too large for a screenshot") }
            let target = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor.white)
            context.fill(target)
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let rendered = context.makeImage() else { throw BrowserScripts.Failure("the screenshot could not be encoded") }
            image = rendered
        }
        let cssWidth = Int((pointWidth / cssScale).rounded())
        let width = min(options.maxWidth ?? cssWidth, max(cssWidth, 1))
        return try BrowserImage.encode(image, format: options.format, quality: options.quality, width: width)
    }

    private func window(of view: NSView) -> NSWindow? { view.window ?? NSApp.keyWindow ?? NSApp.windows.first }

    private func takeSnapshot(_ webView: WKWebView, rect: NSRect) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        return try await webView.takeSnapshot(configuration: configuration)
    }
}

/// A flag that lets the first of several racing callbacks through.
@MainActor
final class Once {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
