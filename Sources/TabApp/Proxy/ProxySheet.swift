import AppKit
import TabCore

/// What the shell provides to set up and apply the proxy.
@MainActor
public protocol ProxyHost: AnyObject {
    /// The window the Set Up Proxy… sheet attaches to.
    var proxyWindow: NSWindow? { get }
    /// Whether this computer's server can start terminals with the proxy's
    /// environment (`Feature.sessionEnvironment`).
    var localServerSupportsProxy: Bool { get }
    /// Ends `pane`'s terminal and starts a new one in its place and folder,
    /// asking first if a program runs. The new terminal's environment comes
    /// from `ProxyModel.creationEnvironment(for:…)`, and its pane shows the
    /// proxy icon when that says `proxied`.
    func restartTerminal(_ pane: PaneId)
    /// The proxy was saved or removed: use `ProxyModel.sshCommand()` for
    /// remote servers (reconnecting those reached a new way),
    /// `ProxyModel.sessionConfiguration()` for downloads, and refresh menus.
    func proxyDidChange(_ model: ProxyModel)
    /// A short confirmation such as "Proxy saved".
    func showProxyNotice(_ message: String)
}

/// Why the sheet's fields can't be saved, as shown under them.
struct ProxyFormError: Error, Equatable {
    let message: String
}

/// Turns the sheet's fields into settings, or the message to show.
enum ProxyForm {
    static func settings(kind: ProxyKind, host: String, port: String, username: String, password: String,
                         bypass: String, global: Bool) -> Result<ProxySettings, ProxyFormError> {
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let portNumber = Int(trim(port)) else { return .failure(ProxyFormError(message: "Enter a port from 1 to 65535")) }
        let settings = ProxySettings(kind: kind, host: trim(host), port: portNumber, username: trim(username),
                                     password: password, bypass: trim(bypass), global: global)
        do {
            try settings.validate()
        } catch {
            if settings.host.isEmpty || settings.host.contains(where: { "/@ ".contains($0) }) {
                return .failure(ProxyFormError(message: "Enter the proxy's host name or address, without http://"))
            }
            if !(1...65535).contains(settings.port) { return .failure(ProxyFormError(message: "Enter a port from 1 to 65535")) }
            if settings.username.isEmpty && !settings.password.isEmpty {
                return .failure(ProxyFormError(message: "Enter the user name for this password"))
            }
            return .failure(ProxyFormError(message: "The proxy settings contain characters that can't be used"))
        }
        return .success(settings)
    }
}

/// The proxy's actions for the shell's menus: Set Up Proxy…, Apply Proxy
/// and Remove Proxy.
@MainActor
public final class ProxyController {
    public let model: ProxyModel
    public weak var host: ProxyHost?
    private var sheet: ProxySheet?

    public init(model: ProxyModel, host: ProxyHost) {
        self.model = model
        self.host = host
    }

    /// Shows the Set Up Proxy… sheet on the host's window.
    public func showSetUp() {
        guard sheet == nil, let host else { return }
        let sheet = ProxySheet(model: model, oldServer: !host.localServerSupportsProxy) { [weak self] outcome in
            self?.finish(outcome)
        }
        self.sheet = sheet
        sheet.present(on: host.proxyWindow)
    }

    /// Runs a terminal menu item for `pane`.
    public func perform(_ item: ProxyMenuItem, pane: PaneId) {
        switch item {
        case .setUp: showSetUp()
        case .apply(let enabled): restart(pane, proxy: true, enabled: enabled)
        case .remove(let enabled): restart(pane, proxy: false, enabled: enabled)
        }
    }

    private func restart(_ pane: PaneId, proxy: Bool, enabled: Bool) {
        guard enabled, let host else { return }
        model.choose(pane, proxy: proxy)
        host.restartTerminal(pane)
    }

    private func finish(_ outcome: ProxySheet.Outcome) {
        sheet = nil
        switch outcome {
        case .cancelled: return
        case .saved: host?.showProxyNotice("Proxy saved")
        case .removed: host?.showProxyNotice("Proxy removed")
        }
        host?.proxyDidChange(model)
    }
}

/// The Set Up Proxy… sheet: type, host, port, login, bypass list and
/// whether the whole app uses it.
@MainActor
final class ProxySheet: NSObject, NSWindowDelegate {
    enum Outcome { case saved, removed, cancelled }

    let window: NSWindow
    private let model: ProxyModel
    private let completion: (Outcome) -> Void
    private var kind: ProxyKind
    private let host: InsetTextField
    private let port: InsetTextField
    private let username: InsetTextField
    private let password: ProxyPasswordField
    private let bypass: InsetTextField
    private let global: Switch
    private let errorNote = NoteLabel("", error: true)
    private let globalNote = NoteLabel("")

    init(model: ProxyModel, oldServer: Bool, completion: @escaping (Outcome) -> Void) {
        self.model = model
        self.completion = completion
        let current = model.settings ?? ProxySettings(bypass: ProxySettings.defaultBypass)
        kind = current.kind
        host = InsetTextField(value: current.host, placeholder: "127.0.0.1", label: "Host", width: 220)
        port = InsetTextField(value: current.port == 0 ? "" : String(current.port), placeholder: "8080", label: "Port", width: 80)
        username = InsetTextField(value: current.username, placeholder: "optional", label: "User", width: 220)
        password = ProxyPasswordField(value: current.password, placeholder: "optional", label: "Password")
        bypass = InsetTextField(value: current.bypass, placeholder: ProxySettings.defaultBypass, label: "No proxy for", width: 220)
        global = Switch(isOn: current.global, label: "Use for the whole app")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        window.title = "Proxy"
        window.appearance = AppTheme.shared.nsAppearance
        window.delegate = self
        build(saved: model.settings != nil, oldServer: oldServer)
    }

    func present(on parent: NSWindow?) {
        guard let parent else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            return
        }
        parent.beginSheet(window)
    }

    private func build(saved: Bool, oldServer: Bool) {
        let background = ThemedBackground(color: { $0.raised })
        let title = makeLabel("Proxy", font: AppFont.title)
        let type = PopUp(items: [PopUp.Item(id: ProxyKind.http.rawValue, title: "HTTP"),
                                 PopUp.Item(id: ProxyKind.socks5.rawValue, title: "SOCKS5")],
                         selected: kind.rawValue, label: "Type") { [weak self] id in
            self?.kind = ProxyKind(rawValue: id) ?? .http
        }
        global.onChange = { [weak self] _ in self?.updateGlobalNote() }
        let card = Card(rows: [
            CardRow(id: "proxy.kind", label: "Type", control: type),
            CardRow(id: "proxy.host", label: "Host", control: host),
            CardRow(id: "proxy.port", label: "Port", control: port),
            CardRow(id: "proxy.username", label: "User", control: username),
            CardRow(id: "proxy.password", label: "Password", control: password),
            CardRow(id: "proxy.bypass", label: "No proxy for", control: bypass),
            CardRow(id: "proxy.global", label: "Use for the whole app", control: global),
        ])
        errorNote.isHidden = true
        updateGlobalNote()
        var views: [NSView] = [title, card, globalNote]
        if oldServer {
            views.append(NoteLabel("This computer's server is from an older Tab and starts terminals without the proxy. Restart the server to update it."))
        }
        views.append(errorNote)
        let cancel = PillButton("Cancel") { [weak self] in self?.close(.cancelled) }
        let save = PillButton("Save", style: .primary) { [weak self] in self?.save() }
        var footerViews: [NSView] = []
        if saved {
            footerViews.append(PillButton("Remove Proxy", style: .destructive) { [weak self] in self?.remove() })
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        footerViews += [spacer, cancel, save]
        let footer = NSStackView(views: footerViews)
        footer.orientation = .horizontal
        footer.spacing = Metrics.controlGap
        views.append(footer)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        background.addSubview(stack)
        stack.pinEdges(to: background, insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        for view in views where view !== title {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        background.widthAnchor.constraint(equalToConstant: 460).isActive = true
        window.contentView = background
        window.initialFirstResponder = host.field
        for field in [host, port, username, bypass] {
            field.onChange = { [weak self] _ in self?.errorNote.isHidden = true }
        }
        save.setAccessibilityIdentifier("proxy-save")
    }

    private func updateGlobalNote() {
        globalNote.label.stringValue = global.isOn
            ? "New terminals on this computer, Tab's own downloads, and SSH to remote servers use the proxy. Terminals already running keep their settings."
            : "Right-click a terminal and choose Apply Proxy to use it there. The terminal restarts in the same folder."
    }

    private func save() {
        let result = ProxyForm.settings(kind: kind, host: host.stringValue, port: port.stringValue,
                                        username: username.stringValue, password: password.stringValue,
                                        bypass: bypass.stringValue, global: global.isOn)
        switch result {
        case .failure(let error):
            show(error.message)
        case .success(let settings):
            do {
                try model.save(settings)
                close(.saved)
            } catch {
                show("Could not save the proxy: \(error)")
            }
        }
    }

    private func remove() {
        do {
            try model.save(nil)
            close(.removed)
        } catch {
            show("Could not remove the proxy: \(error)")
        }
    }

    private func show(_ message: String) {
        errorNote.label.stringValue = message
        errorNote.isHidden = false
    }

    private func close(_ outcome: Outcome) {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
        completion(outcome)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close(.cancelled)
        return false
    }
}

/// A native bezeled secure field for passwords.
@MainActor
final class ProxyPasswordField: NSView {
    let field = NSSecureTextField()

    init(value: String, placeholder: String, label: String, width: CGFloat = 220) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.stringValue = value
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.font = AppFont.body
        field.setAccessibilityLabel(label)
        addSubview(field)
        field.pinEdges(to: self)
        widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var stringValue: String { field.stringValue }
}
