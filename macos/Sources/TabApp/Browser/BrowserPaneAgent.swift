import AppKit
import TabClient
import WebKit

/// What agents do to a browser pane: run the ref runtime, send real mouse
/// and keyboard events, wait for the page to settle, and take screenshots.
extension BrowserPaneController {
    static let logCaptureScript = WKUserScript(source: BrowserAgentScripts.logCapture, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false, in: .page)
    static let frameListenerScript = WKUserScript(source: BrowserAgentScripts.frameListener, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: BrowserAgentScripts.world)

    /// Marks the pane as driven by an agent: from now on its page logs are
    /// captured, starting with the page on screen.
    func beginAgentControl() {
        guard !agent.drive(), let webView = ensureWebView() else { return }
        webView.configuration.userContentController.addUserScript(Self.logCaptureScript)
        webView.evaluateJavaScript(BrowserAgentScripts.logCapture, in: nil, in: .page) { _ in }
    }

    /// Lets cross-origin frames answer `linkFrames`: every frame a page loads
    /// listens for its token.
    func listenToFrames(_ configuration: WKWebViewConfiguration) {
        configuration.userContentController.add(BrowserFrameHandler(pane: self), contentWorld: BrowserAgentScripts.world,
                                                name: BrowserAgentScripts.frameHandler)
        configuration.userContentController.addUserScript(Self.frameListenerScript)
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
    /// In `frame` when given, else in the page; `arguments` are the
    /// script's variables, for data too large to write into it.
    func agentRun(_ body: String, timeout: TimeInterval = 10, in frame: BrowserAgentState.AgentFrame? = nil,
                  arguments: [String: Any] = [:]) async throws -> AgentOutcome {
        guard let webView = ensureWebView() else { throw BrowserScripts.Failure("the built-in browser is disabled") }
        if let dialog = agent.dialog { throw Self.dialogOpen(dialog) }
        for _ in 0 ..< 2 {
            let outcome = try await runWatchingDialogs(BrowserAgentScripts.call(body), timeout: timeout, frame: frame,
                                                       arguments: arguments)
            guard case .value(let reply) = outcome else { return outcome }
            if reply["missing"] == .bool(true) {
                let start = frame.map { agent.frames[$0.number]?.nextRef ?? 1 } ?? agent.nextRef
                _ = try await BrowserPage.run(BrowserAgentScripts.install(start: start, frame: frame?.number), in: webView,
                                              timeout: timeout, world: BrowserAgentScripts.world, frame: frame?.info)
                continue
            }
            if case .int(let next) = reply["next"] {
                if let frame { agent.setNextRef(Int(next), frame: frame.number) } else { agent.nextRef = max(agent.nextRef, Int(next)) }
            }
            if let error = reply["error"]?.string { throw BrowserScripts.Failure(error) }
            return .value(reply["value"] ?? .null)
        }
        throw BrowserScripts.Failure("the page didn't take Tab's automation script")
    }

    /// `agentRun`, failing when a dialog opens instead.
    func agentValue(_ body: String, timeout: TimeInterval = 10, in frame: BrowserAgentState.AgentFrame? = nil,
                    arguments: [String: Any] = [:]) async throws -> JSONValue {
        switch try await agentRun(body, timeout: timeout, in: frame, arguments: arguments) {
        case .value(let value): return value
        case .dialog(let dialog): throw Self.dialogOpen(dialog)
        }
    }

    /// The frame whose runtime knows `target`: a frame ref's frame, else the page.
    func frame(for target: String?) throws -> BrowserAgentState.AgentFrame? {
        guard let target, let number = BrowserAgentScripts.refFrame(target) else { return nil }
        guard let frame = agent.frames[number] else {
            throw BrowserScripts.Failure("unknown ref \(target): its frame is gone or was never printed; run snapshot again")
        }
        return frame
    }

    // MARK: Snapshots

    struct Snapshot {
        var lines: [String] = []
        var nodes: [JSONValue] = []
        var truncated = false
    }

    /// The runtime's snapshot with `options` (a JavaScript object), with the
    /// elements of cross-origin frames, at most four deep, in their place.
    func snapshot(_ options: String, in frame: BrowserAgentState.AgentFrame? = nil, level: Int = 0) async throws -> Snapshot {
        await linkFrames(in: frame)
        let shot = try await agentValue("return A.snapshot(\(options));", in: frame)
        var result = Snapshot()
        if case .array(let lines)? = shot["lines"] { result.lines = lines.compactMap(\.string) }
        if case .array(let nodes)? = shot["nodes"] { result.nodes = nodes }
        result.truncated = shot["truncated"] == .bool(true)
        guard case .array(let frames)? = shot["frames"] else { return result }
        for entry in frames.reversed() {
            guard let token = entry["token"]?.string, let at = entry["at"]?.number.map(Int.init),
                  at <= result.lines.count else { continue }
            let line = entry["line"]?.number.map(Int.init) ?? -1
            let depth = entry["depth"]?.number.map(Int.init) ?? 0
            guard level < 4, let child = agent.frame(token: token),
                  let inner = try? await snapshot(options, in: child, level: level + 1), !inner.lines.isEmpty || line < 0
            else {
                if result.lines.indices.contains(line) { result.lines[line] += " (cross-origin, not shown)" }
                continue
            }
            let indent = String(repeating: "  ", count: options.contains("interactive: true") ? 0 : depth)
            result.lines.insert(contentsOf: inner.lines.map { indent + $0 }, at: at)
            result.nodes += inner.nodes
            result.truncated = result.truncated || inner.truncated
        }
        if result.lines.count > Self.snapshotLineLimit {
            result.lines.removeLast(result.lines.count - Self.snapshotLineLimit)
            result.truncated = true
        }
        return result
    }

    static let snapshotLineLimit = 2000

    /// Sends each cross-origin frame of `frame` its token, and waits briefly
    /// for the frames to answer.
    private func linkFrames(in frame: BrowserAgentState.AgentFrame?) async {
        guard case .array(let values)? = try? await agentValue("return A.linkFrames();", in: frame) else { return }
        let tokens = values.compactMap(\.string)
        guard !tokens.isEmpty else { return }
        agent.linked(tokens, in: frame?.number)
        let deadline = Date().addingTimeInterval(0.6)
        while tokens.contains(where: { agent.frame(token: $0) == nil }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Where `frame`'s viewport starts in the page's, in CSS pixels, and the
    /// page's viewport width; scrolls each frame into view on the way.
    func offset(of frame: BrowserAgentState.AgentFrame?) async throws -> (x: Double, y: Double, viewport: Double?) {
        var x = 0.0, y = 0.0
        var viewport: Double?
        var current = frame
        while let inner = current {
            let parent = try inner.parent.map { number in
                guard let found = agent.frames[number] else {
                    throw BrowserScripts.Failure("stale frame: the frame is gone from the page; run snapshot again")
                }
                return found
            }
            let box = try await agentValue("return A.frameBox(\(BrowserScripts.literal(inner.token)));", in: parent)
            x += box["x"]?.number ?? 0
            y += box["y"]?.number ?? 0
            viewport = box["viewport"]?.number
            current = parent
        }
        return (x, y, viewport)
    }

    enum AgentOutcome {
        case value(JSONValue)
        case dialog(PendingDialog)
    }

    static func dialogOpen(_ dialog: PendingDialog) -> BrowserScripts.Failure {
        BrowserScripts.Failure("the page shows a dialog: \(dialog.summary); answer it with tab browser dialog BROWSER accept|dismiss")
    }

    private func runWatchingDialogs(_ script: String, timeout: TimeInterval, frame: BrowserAgentState.AgentFrame?,
                                    arguments: [String: Any]) async throws -> AgentOutcome {
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
                    let value = try await BrowserPage.run(script, in: webView, timeout: timeout, world: BrowserAgentScripts.world,
                                                          frame: frame?.info, arguments: arguments)
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

    /// A point `prepare` returned, in the window's coordinates; a frame's
    /// point moves by the frame's `offset`.
    func windowPoint(_ prepared: JSONValue, offset: (x: Double, y: Double, viewport: Double?) = (0, 0, nil)) -> NSPoint? {
        guard let webView, webView.window != nil, let x = prepared["x"]?.number.map({ $0 + offset.x }),
              let y = prepared["y"]?.number.map({ $0 + offset.y }) else {
            return nil
        }
        let viewport = offset.viewport ?? prepared["viewport"]?.number ?? 0
        let scale = viewport > 0 ? webView.bounds.width / viewport : 1
        let local = NSPoint(x: x * scale, y: webView.isFlipped ? y * scale : webView.bounds.height - y * scale)
        return webView.convert(local, to: nil)
    }

    enum MouseButton { case left, right }

    func sendMouse(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1) {
        guard let webView, let window = webView.window,
              let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: clickCount,
                                             pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0)
        else { return }
        switch type {
        case .leftMouseDown: webView.mouseDown(with: event)
        case .leftMouseUp: webView.mouseUp(with: event)
        case .rightMouseDown: webView.rightMouseDown(with: event)
        case .rightMouseUp: webView.rightMouseUp(with: event)
        default: webView.mouseMoved(with: event)
        }
    }

    /// A click, or a double click as two clicks counting up as a user's do.
    func click(at point: NSPoint, clickCount: Int = 1, button: MouseButton = .left) {
        sendMouse(.mouseMoved, at: point)
        for count in 1 ... max(clickCount, 1) {
            sendMouse(button == .left ? .leftMouseDown : .rightMouseDown, at: point, clickCount: count)
            sendMouse(button == .left ? .leftMouseUp : .rightMouseUp, at: point, clickCount: count)
        }
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
