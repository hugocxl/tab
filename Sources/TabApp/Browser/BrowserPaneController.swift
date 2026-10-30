import AppKit
import TabClient
import TabCore
import UniformTypeIdentifiers
import WebKit

/// A browser pane: a toolbar over a `WKWebView` browsing with one profile's
/// website data store. The page keeps running while the pane is hidden.
/// The pane reports its address, profile, title and icon to its host, which
/// saves them; `tabId` is the ID `tab browser` names it by.
@MainActor
public final class BrowserPaneController: NSViewController {
    /// What the live page is doing.
    public struct PageState: Equatable, Sendable {
        public var url = ""
        public var title = ""
        public var loading = false
        public var progress = 0.0
        public var canGoBack = false
        public var canGoForward = false
        /// Loads started so far, for `waitForNavigation`.
        public var loads = 0
        public var error: LoadError?
    }

    public struct LoadError: Equatable, Sendable {
        public var url: String
        public var message: String
    }

    public let tabId: String
    public private(set) weak var host: BrowserHost?
    public private(set) var profile: BrowserProfile
    public private(set) var page = PageState()
    public private(set) var favicon: NSImage?
    public private(set) var zoom = 1.0
    public private(set) var webView: WKWebView?
    /// Whether the user is choosing an element to copy.
    public private(set) var selectingElement = false

    private let profiles: BrowserProfiles
    private let toolbar = BrowserToolbar()
    private let findBar = BrowserFindBar()
    private let content = FlippedView()
    private let placeholder = BrowserPlaceholder()
    private let suggestions = BrowserSuggestionsPanel()
    private var observations: [NSKeyValueObservation] = []
    private var settings: BrowserSettings
    private var initialURL: String?
    private var pickerGeneration = 0
    private var findQuery = ""

    /// A pane showing `state`'s address with its profile (the default
    /// profile when it has none or it is gone).
    public init(tabId: String, state: BrowserPane, host: BrowserHost) {
        self.tabId = tabId
        self.host = host
        profiles = host.browserProfiles
        settings = host.browserSettings
        profile = host.browserProfiles.profile(forSaved: state.profile)
        initialURL = state.url
        super.init(nibName: nil, bundle: nil)
        profiles.panes.register(self)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        suggestions.dismiss()
    }

    // MARK: View

    public override func loadView() {
        let root = BrowserPaneView()
        root.controller = self
        let theme = host?.theme ?? .shared
        root.theme = theme
        toolbar.theme = theme
        findBar.theme = theme
        placeholder.theme = theme
        content.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        let column = NSStackView(views: [toolbar, findBar, content])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .width
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addSubview(column)
        column.pinEdges(to: root)
        content.addSubview(placeholder)
        placeholder.pinEdges(to: content)
        view = root
        wireToolbar()
        apply(settings: settings)
    }

    private func wireToolbar() {
        toolbar.back.onPress = { [weak self] in self?.goBack() }
        toolbar.forward.onPress = { [weak self] in self?.goForward() }
        toolbar.reload.onPress = { [weak self] in
            guard let self else { return }
            page.loading ? stop() : reload()
        }
        toolbar.picker.onPress = { [weak self] in self?.toggleElementPicker() }
        toolbar.external.onPress = { [weak self] in self?.showExternalMenu() }
        toolbar.profile.onClick = { [weak self] in self?.showProfileMenu() }
        let address = toolbar.address
        address.onFocus = { [weak self] in
            guard let self else { return }
            address.field.currentEditor()?.selectAll(nil)
            updateSuggestions("")
        }
        address.onChange = { [weak self] text in self?.updateSuggestions(text) }
        address.onSubmit = { [weak self] text in
            guard let self else { return }
            let chosen = suggestions.isVisible ? suggestions.selected.map { self.suggestions.entries[$0].url } : nil
            submit(chosen ?? text)
        }
        address.onMove = { [weak self] down in self?.moveSuggestion(down: down) ?? false }
        address.onCancel = { [weak self] in
            guard let self else { return false }
            if suggestions.isVisible {
                suggestions.dismiss()
                return true
            }
            focusPage()
            return true
        }
        address.onEndEditing = { [weak self] in
            guard let self else { return }
            suggestions.dismiss()
            toolbar.address.text = Self.displayAddress(page.url)
        }
        suggestions.onChoose = { [weak self] row in
            guard let self, suggestions.entries.indices.contains(row) else { return }
            submit(suggestions.entries[row].url)
        }
        findBar.onChange = { [weak self] query in self?.find(query, backwards: false) }
        findBar.onStep = { [weak self] backwards in
            guard let self else { return }
            find(findBar.field.stringValue, backwards: backwards)
        }
        findBar.onClose = { [weak self] in self?.closeFind() }
        placeholder.onSearch = { [weak self] in self?.focusAddress() }
        placeholder.onRetry = { [weak self] in self?.reload() }
    }

    /// Applies changed browser settings: the search engine, and whether the
    /// built-in browser is on at all.
    public func apply(settings: BrowserSettings) {
        self.settings = settings
        guard isViewLoaded else { return }
        guard settings.enabled else {
            suggestions.dismiss()
            findBar.isHidden = true
            tearDownWebView()
            toolbar.isHidden = true
            placeholder.kind = .disabled
            placeholder.isHidden = false
            return
        }
        toolbar.isHidden = false
        if webView == nil { makeWebView(loading: initialURL) }
        refreshChrome()
    }

    private func makeWebView(loading url: String?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profiles.dataStore(for: profile)
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = BrowserWebView(frame: content.bounds, configuration: configuration)
        webView.controller = self
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.pageZoom = zoom
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(webView, positioned: .below, relativeTo: placeholder)
        webView.pinEdges(to: content)
        self.webView = webView
        observe(webView)
        toolbar.profile.name = profile.name
        if let url, !BrowserAddress.isBlank(url) {
            load(url)
        } else {
            page = PageState()
            refreshChrome()
        }
    }

    private func tearDownWebView() {
        cancelElementPicker()
        observations.removeAll()
        guard let webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        initialURL = page.url.isEmpty ? initialURL : page.url
        self.webView = nil
    }

    private func observe(_ webView: WKWebView) {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.urlChanged(view.url?.absoluteString) }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.titleChanged(view.title ?? "") }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.page.loading = view.isLoading
                    self.refreshChrome()
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.page.progress = view.estimatedProgress
                    self.toolbar.setProgress(self.page.progress, loading: self.page.loading)
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.page.canGoBack = view.canGoBack
                    self?.refreshChrome()
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.page.canGoForward = view.canGoForward
                    self?.refreshChrome()
                }
            },
        ]
    }

    private func urlChanged(_ url: String?) {
        let url = url ?? ""
        guard url != page.url else { return }
        page.url = url
        if !toolbar.address.editing { toolbar.address.text = Self.displayAddress(url) }
        reportState()
        refreshChrome()
    }

    private func titleChanged(_ title: String) {
        page.title = title
        if !page.url.isEmpty { profiles.history(for: profile).updateTitle(url: page.url, title: title) }
        reportTitle()
    }

    private func refreshChrome() {
        guard isViewLoaded else { return }
        toolbar.back.isEnabled = page.canGoBack
        toolbar.forward.isEnabled = page.canGoForward
        toolbar.reload.icon = page.loading ? .close : .refresh
        toolbar.reload.toolTip = page.loading ? "Stop" : "Reload"
        toolbar.reload.setAccessibilityLabel(page.loading ? "Stop" : "Reload")
        toolbar.picker.isEnabled = !isBlank && page.error == nil
        toolbar.picker.isActive = selectingElement
        toolbar.external.isEnabled = !isBlank
        toolbar.profile.name = profile.name
        toolbar.setProgress(page.progress, loading: page.loading)
        guard settings.enabled else { return }
        if let error = page.error {
            placeholder.kind = .error(url: error.url, message: error.message)
            placeholder.isHidden = false
        } else if isBlank && !page.loading {
            placeholder.kind = .start(engine: settings.searchEngine.name)
            placeholder.isHidden = false
        } else {
            placeholder.isHidden = true
        }
    }

    /// Whether the pane shows the start page.
    public var isBlank: Bool { BrowserAddress.isBlank(page.url) }

    /// The pane's title: the page title, else its host; `nil` on the start page.
    public var pageTitle: String? { BrowserAddress.displayTitle(page.title, url: page.url) }

    /// What the pane saves.
    public var state: BrowserPane { BrowserPane(url: page.url.isEmpty ? initialURL : page.url, profile: profile.id) }

    private func reportState() {
        host?.browserPane(self, didChange: state)
    }

    private func reportTitle() {
        host?.browserPane(self, didChangeTitle: pageTitle, favicon: favicon)
    }

    // MARK: Navigation

    /// Loads what was typed in the address bar: an address or a search.
    public func submit(_ input: String) {
        guard let url = settings.resolve(input) else { return }
        suggestions.dismiss()
        load(url)
        focusPage()
    }

    /// Loads `url`, which should already be an address.
    public func load(_ url: String) {
        page.error = nil
        guard let webView else {
            initialURL = url
            return
        }
        guard let address = URL(string: url) else {
            page.error = LoadError(url: url, message: "The address is not valid.")
            refreshChrome()
            return
        }
        if !BrowserAddress.engineLoads(url) {
            openExternally(address)
            return
        }
        webView.load(URLRequest(url: address))
        page.loading = true
        toolbar.address.text = Self.displayAddress(url)
        refreshChrome()
    }

    public func reload() {
        if let error = page.error {
            page.error = nil
            load(error.url)
            return
        }
        webView?.reload()
    }

    public func stop() {
        webView?.stopLoading()
        page.loading = false
        refreshChrome()
    }

    public func goBack() {
        page.error = nil
        webView?.goBack()
        refreshChrome()
    }

    public func goForward() {
        page.error = nil
        webView?.goForward()
        refreshChrome()
    }

    public func zoomIn() { setZoom(BrowserAddress.zoomIn(zoom)) }
    public func zoomOut() { setZoom(BrowserAddress.zoomOut(zoom)) }
    public func resetZoom() { setZoom(1) }

    private func setZoom(_ value: Double) {
        zoom = min(max(value, BrowserAddress.minimumZoom), BrowserAddress.maximumZoom)
        webView?.pageZoom = zoom
    }

    /// Copies the page's address.
    public func copyAddress() {
        guard !isBlank else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(page.url, forType: .string)
        host?.showToast("Copied!", isError: false)
    }

    /// Focuses the address bar and selects its text (Cmd+L).
    public func focusAddress() {
        guard settings.enabled else { return }
        toolbar.address.focus()
    }

    /// Gives the keyboard to the page.
    public func focusPage() {
        guard let webView else { return }
        view.window?.makeFirstResponder(webView)
    }

    /// Browses with `profile` from now on: the page loads again in its data store.
    public func switchProfile(to profile: BrowserProfile) {
        guard profile.id != self.profile.id else { return }
        let url = page.url.isEmpty ? initialURL : page.url
        self.profile = profile
        tearDownWebView()
        page = PageState()
        if settings.enabled, isViewLoaded { makeWebView(loading: url) }
        reportState()
    }

    /// Refreshes a renamed profile without replacing its page or data store.
    func updateProfileName(_ name: String) {
        profile.name = name
        refreshChrome()
    }

    // MARK: Web Inspector

    /// Shows or hides the Web Inspector (Cmd+Opt+I). WebKit has no public
    /// call for this, so the inspector object is reached through the
    /// `_inspector` property only when the running WebKit answers to it;
    /// otherwise the user is told to use Safari's Develop menu, which can
    /// inspect the page because it is `isInspectable`.
    public func toggleWebInspector() {
        guard let webView else { return }
        let inspectorSelector = NSSelectorFromString("_inspector")
        guard webView.responds(to: inspectorSelector),
              let inspector = webView.perform(inspectorSelector)?.takeUnretainedValue() as? NSObject
        else {
            host?.showToast("Open the Web Inspector from Safari's Develop menu", isError: false)
            return
        }
        let visible = inspector.responds(to: NSSelectorFromString("isVisible"))
            && (inspector.value(forKey: "isVisible") as? Bool ?? false)
        let action = NSSelectorFromString(visible ? "close" : "show")
        guard inspector.responds(to: action) else { return }
        inspector.perform(action)
    }

    // MARK: Suggestions

    private func updateSuggestions(_ query: String) {
        let entries = profiles.history(for: profile).suggestions(for: query.trimmingCharacters(in: .whitespaces))
        suggestions.show(entries, under: toolbar.address, theme: host?.theme ?? .shared)
    }

    /// Moves the highlighted suggestion; past either end, none is.
    private func moveSuggestion(down: Bool) -> Bool {
        guard suggestions.isVisible, !suggestions.entries.isEmpty else { return false }
        let count = suggestions.entries.count
        switch (suggestions.selected, down) {
        case (nil, true): suggestions.selected = 0
        case (nil, false): suggestions.selected = count - 1
        case (let index?, true): suggestions.selected = index + 1 < count ? index + 1 : nil
        case (let index?, false): suggestions.selected = index > 0 ? index - 1 : nil
        }
        return true
    }

    // MARK: Find

    /// Shows the find bar (Cmd+F).
    public func showFind() {
        guard webView != nil else { return }
        findBar.isHidden = false
        findBar.focus()
    }

    public func closeFind() {
        findBar.isHidden = true
        findBar.notFound = false
        findQuery = ""
        focusPage()
    }

    private func find(_ query: String, backwards: Bool) {
        guard let webView, !query.isEmpty else {
            findBar.notFound = false
            return
        }
        findQuery = query
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(query, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.findQuery == query else { return }
                self.findBar.notFound = !result.matchFound
            }
        }
    }

    // MARK: Menus

    private func showExternalMenu() {
        guard !isBlank, let url = URL(string: page.url) else { return }
        let menu = NSMenu()
        menu.addItem(BrowserMenuItem("Open in Default Browser") { [weak self] in self?.openExternally(url) })
        let browsers = Self.installedBrowsers()
        if !browsers.isEmpty { menu.addItem(.separator()) }
        for app in browsers {
            menu.addItem(BrowserMenuItem(app.deletingPathExtension().lastPathComponent) { [weak self] in
                self?.openExternally(url, application: app)
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: toolbar.external.bounds.height + 4), in: toolbar.external)
    }

    private func showProfileMenu() {
        let menu = NSMenu()
        for candidate in profiles.ordered {
            let item = BrowserMenuItem(candidate.name) { [weak self] in self?.switchProfile(to: candidate) }
            item.state = candidate.id == profile.id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(BrowserMenuItem("Manage Profiles…") { [weak self] in self?.host?.manageBrowserProfiles() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: toolbar.profile.bounds.height + 4), in: toolbar.profile)
    }

    /// Apps that open web pages, by name, as the system lists them.
    static func installedBrowsers() -> [URL] {
        guard let sample = URL(string: "https://example.com") else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: sample)
            .filter { seen.insert($0.deletingPathExtension().lastPathComponent.lowercased()).inserted }
            .filter { $0.lastPathComponent != Bundle.main.bundleURL.lastPathComponent }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    func openExternally(_ url: URL, application: URL? = nil) {
        guard let application else {
            if !NSWorkspace.shared.open(url) { host?.showToast("Could not open link: \(url.absoluteString)", isError: true) }
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.host?.showToast("Could not open link: \(error.localizedDescription)", isError: true)
            }
        }
    }

    // MARK: Element picker

    /// Starts or cancels choosing an element whose HTML and text are copied.
    public func toggleElementPicker() {
        guard let webView else { return }
        if selectingElement {
            cancelElementPicker()
            return
        }
        guard !isBlank, page.error == nil else { return }
        pickerGeneration += 1
        let generation = pickerGeneration
        selectingElement = true
        refreshChrome()
        let script = BrowserScripts.elementPicker(accent: Self.hex(host?.theme.accent ?? .controlAccentColor))
        Task { [weak self] in
            let result = try? await BrowserPage.run(script, in: webView, timeout: 3600)
            guard let self, pickerGeneration == generation else { return }
            selectingElement = false
            refreshChrome()
            guard let result, result != .null, let text = BrowserScripts.elementClipboardText(result) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            host?.showToast("Copied!", isError: false)
        }
    }

    private func cancelElementPicker() {
        guard selectingElement, let webView else { return }
        selectingElement = false
        pickerGeneration += 1
        refreshChrome()
        Task { _ = try? await BrowserPage.run(BrowserScripts.cancelElementPicker, in: webView, timeout: 5) }
    }

    static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    // MARK: Keys

    /// Routes catalog actions from the shell, including remapped shortcuts
    /// and menu or palette actions, to this browser pane.
    public func perform(_ action: ShortcutId) -> Bool {
        guard settings.enabled else { return false }
        switch action {
        case .browserFocusAddress: focusAddress()
        case .browserReload: reload()
        case .browserBack: goBack()
        case .browserForward: goForward()
        case .find: showFind()
        case .findNext: find(findBar.field.stringValue, backwards: false)
        case .findPrevious: find(findBar.field.stringValue, backwards: true)
        case .browserZoomIn, .increaseFontSize: zoomIn()
        case .browserZoomOut, .decreaseFontSize: zoomOut()
        case .browserZoomReset: resetZoom()
        case .browserCopyUrl: copyAddress()
        case .browserInspect: toggleWebInspector()
        default: return false
        }
        return true
    }

    /// Browser shortcuts while the pane has the keyboard.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard settings.enabled else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch (flags, key) {
        case ([.command], "l"): focusAddress()
        case ([.command], "r"): reload()
        case ([.command], "["): goBack()
        case ([.command], "]"): goForward()
        case ([.command], "f"): showFind()
        case ([.command], "="), ([.command, .shift], "="), ([.command, .shift], "+"), ([.command], "+"): zoomIn()
        case ([.command], "-"): zoomOut()
        case ([.command], "0"): resetZoom()
        case ([.command, .shift], "c"): copyAddress()
        case ([.command, .option], "i"): toggleWebInspector()
        case ([.command], "g"): find(findBar.field.stringValue, backwards: false)
        case ([.command, .shift], "g"): find(findBar.field.stringValue, backwards: true)
        default: return false
        }
        return true
    }

    func pageEscape() {
        if selectingElement { cancelElementPicker() }
        if !findBar.isHidden { closeFind() }
    }

    static func displayAddress(_ url: String) -> String {
        BrowserAddress.isBlank(url) ? "" : url
    }

    // MARK: Favicon

    private static var favicons: [String: NSImage] = [:]

    private func loadFavicon() {
        guard let webView else { return }
        let script = """
        const link = document.querySelector('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]');
        return link ? link.href : new URL('/favicon.ico', location.href).href;
        """
        let pageURL = page.url
        Task { [weak self] in
            guard let value = try? await BrowserPage.run(script, in: webView, timeout: 5, world: .defaultClient),
                  let href = value.string, let url = URL(string: href),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  self?.webView === webView, self?.page.url == pageURL
            else { return }
            if let cached = Self.favicons[href] {
                self?.setFavicon(cached)
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
            image.size = NSSize(width: 16, height: 16)
            Self.favicons[href] = image
            guard self?.webView === webView, self?.page.url == pageURL else { return }
            self?.setFavicon(image)
        }
    }

    private func setFavicon(_ image: NSImage?) {
        favicon = image
        toolbar.address.favicon = image
        reportTitle()
    }

    // MARK: Automation

    /// Runs `body` as an async function in the page and returns what it
    /// returned, as JSON. A page that hasn't answered within `timeout` fails.
    public func run(_ body: String, timeout: TimeInterval = BrowserCommand.maxWait) async throws -> JSONValue {
        guard let webView = ensureWebView() else { throw BrowserScripts.Failure("the built-in browser is disabled") }
        return try await BrowserPage.run(body, in: webView, timeout: timeout)
    }

    /// The page, created hidden when the pane's view was never loaded.
    func ensureWebView() -> WKWebView? {
        _ = view
        if webView == nil, settings.enabled { makeWebView(loading: initialURL) }
        return webView
    }

    /// A PNG picture of the page.
    public func screenshot() async throws -> Data {
        guard let webView = ensureWebView() else { throw BrowserScripts.Failure("the built-in browser is disabled") }
        if webView.window == nil, webView.bounds.isEmpty {
            webView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        }
        if webView.window?.isVisible == true {
            if let image = try? await webView.takeSnapshot(configuration: nil),
               let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) { return png }
        }
        let configuration = WKPDFConfiguration()
        configuration.rect = webView.bounds
        let data = try await BrowserPage.pdf(in: webView, configuration: configuration)
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1),
              let context = CGContext(data: nil, width: max(Int(webView.bounds.width), 1),
                                      height: max(Int(webView.bounds.height), 1), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw BrowserScripts.Failure("the screenshot could not be encoded") }
        let rect = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        context.setFillColor(CGColor.white)
        context.fill(rect)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw BrowserScripts.Failure("the screenshot could not be encoded") }
        return png
    }

    /// The cookies of the pane's profile.
    public var cookieStore: WKHTTPCookieStore { profiles.dataStore(for: profile).httpCookieStore }
}

// MARK: - Delegates

extension BrowserPaneController: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url else { return (.cancel, preferences) }
        if !BrowserAddress.engineLoads(url.absoluteString) {
            let byUser = navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .formSubmitted
            if byUser { openExternally(url) }
            return (.cancel, preferences)
        }
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        if navigationAction.modifierFlags.contains(.command), navigationAction.navigationType == .linkActivated {
            host?.openBrowserPane(url: url.absoluteString, profile: profile.id, from: self)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        if selectingElement { cancelElementPicker() }
        page.loads += 1
        page.loading = true
        page.error = nil
        page.title = ""
        setFavicon(nil)
        refreshChrome()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        page.loading = false
        page.progress = 1
        let url = webView.url?.absoluteString ?? page.url
        profiles.history(for: profile).recordVisit(url: url, title: webView.title)
        refreshChrome()
        loadFavicon()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        failed(error, url: (error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        failed(error, url: nil)
    }

    private func failed(_ error: any Error, url: String?) {
        page.loading = false
        let error = error as NSError
        let interrupted = error.domain == "WebKitErrorDomain" && error.code == 102
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled), !interrupted else {
            refreshChrome()
            return
        }
        page.error = LoadError(url: url ?? page.url, message: error.localizedDescription)
        refreshChrome()
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        Self.downloadDestination(for: suggestedFilename)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        let name = download.progress.fileURL?.lastPathComponent ?? "file"
        host?.showToast("Downloaded \(name)", isError: false)
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        host?.showToast("Download failed: \(error.localizedDescription)", isError: true)
    }

    /// A free name for `suggested` in ~/Downloads: `name 2.ext` and so on.
    static func downloadDestination(for suggested: String, in folder: URL? = nil) -> URL {
        let downloads = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let clean = suggested.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let name = clean.isEmpty || clean.hasPrefix(".") ? "download\(clean)" : clean
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = downloads.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url?.absoluteString, BrowserAddress.engineLoads(url) else { return nil }
        host?.openBrowserPane(url: url, profile: profile.id, from: self)
        return nil
    }

    public func webViewDidClose(_ webView: WKWebView) {
        host?.browserPaneRequestsClose(self)
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async {
        let alert = dialog(message, frame: frame)
        alert.addButton(withTitle: "OK")
        _ = await present(alert)
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = dialog(message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                        defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = dialog(prompt, frame: frame)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = view.window else { return panel.runModal() == .OK ? panel.urls : nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    private func dialog(_ message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        alert.window.appearance = host?.theme.nsAppearance
        return alert
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = view.window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }
}

/// Runs scripts in a page and reads back their results as JSON.
@MainActor
enum BrowserPage {
    static func run(_ body: String, in webView: WKWebView, timeout: TimeInterval, world: WKContentWorld? = nil) async throws -> JSONValue {
        let wrapped = BrowserScripts.jsonWrapped(body)
        let text: String = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            webView.callAsyncJavaScript(wrapped, arguments: [:], in: nil, in: world ?? .page) { result in
                MainActor.assumeIsolated {
                    guard !finished else { return }
                    finished = true
                    switch result {
                    case .success(let value):
                        if let text = value as? String {
                            continuation.resume(returning: text)
                        } else {
                            continuation.resume(throwing: BrowserScripts.Failure("script error: the script's result could not be read as JSON"))
                        }
                    case .failure(let error): continuation.resume(throwing: BrowserScripts.Failure(Self.message(error)))
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated {
                    guard !finished else { return }
                    finished = true
                    continuation.resume(throwing: BrowserScripts.Failure("the page did not answer in time"))
                }
            }
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        } catch {
            throw BrowserScripts.Failure("the page's answer is not JSON")
        }
    }

    static func pdf(in webView: WKWebView, configuration: WKPDFConfiguration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            webView.createPDF(configuration: configuration) { result in
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                MainActor.assumeIsolated {
                    guard !finished else { return }
                    finished = true
                    continuation.resume(throwing: BrowserScripts.Failure("webkit backend: snapshot timed out"))
                }
            }
        }
    }

    static func message(_ error: any Error) -> String {
        "script error: " + error.localizedDescription
    }
}

/// The pane's root view: it routes the browser's shortcuts while the pane
/// has the keyboard.
final class BrowserPaneView: ThemedView {
    weak var controller: BrowserPaneController?

    override func draw(_ dirtyRect: NSRect) {
        theme.card.setFill()
        bounds.fill()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self),
              let controller
        else { return super.performKeyEquivalent(with: event) }
        return controller.handleKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.pageEscape()
    }
}

/// The page view, which adds Web Inspector to the page's context menu and
/// hands Escape to the pane.
final class BrowserWebView: WKWebView {
    weak var controller: BrowserPaneController?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menu.addItem(.separator())
        menu.addItem(BrowserMenuItem("Web Inspector") { [weak self] in self?.controller?.toggleWebInspector() })
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, controller?.selectingElement == true || controller?.findVisible == true {
            controller?.pageEscape()
            return
        }
        super.keyDown(with: event)
    }
}

extension BrowserPaneController {
    var findVisible: Bool { isViewLoaded && !findBar.isHidden }
}

/// A menu item that runs a closure.
final class BrowserMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
