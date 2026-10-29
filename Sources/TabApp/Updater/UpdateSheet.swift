import AppKit
import TabCore

/// The "Update available" sheet: what installing the new version does to
/// running terminals, and the choices that fit.
@MainActor
final class UpdateSheet {
    private let version: String
    private let offer: UpdateOffer
    private var panel: SheetPanel?
    private var parent: NSWindow?
    private var completion: ((UpdateChoice) -> Void)?
    private var restartServer = false

    init(version: String, offer: UpdateOffer) {
        self.version = version
        self.offer = offer
    }

    var message: String {
        let app = Release.appName
        switch offer {
        case .installNow:
            return "Install \(app) \(version) and restart the app? Running terminals keep going, and the server updates once every terminal has ended."
        case .needsNewServer:
            return "\(app) \(version) needs a new server. It can install once every terminal has ended, or now by ending them. Terminal panes close; other panes and settings stay."
        case .waitingForSessions(let sessions):
            let count = sessions == 1 ? "1 terminal is" : "\(sessions) terminals are"
            return "\(app) \(version) installs and restarts the app once every terminal has ended. \(count) still running, including idle and detached ones. Keep \(app) open to finish the update."
        }
    }

    func present(on window: NSWindow?, completion: @escaping (UpdateChoice) -> Void) {
        self.completion = completion
        let panel = SheetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 10),
            styleMask: [.titled, .docModalWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = "\(Release.appName) Update"
        panel.appearance = AppTheme.shared.nsAppearance
        panel.onCancel = { [weak self] in self?.finish(.later) }
        panel.contentView = makeContent()
        self.panel = panel
        parent = window
        guard let window else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        window.beginSheet(panel)
    }

    private func makeContent() -> NSView {
        let root = ThemedBackground(color: { $0.raised })
        let title = makeLabel("\(Release.appName) \(version) is available", font: AppFont.title)
        let body = makeLabel(message, font: AppFont.body)
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 0
        body.preferredMaxLayoutWidth = 392
        body.textColor = AppTheme.shared.fgMuted
        var rows: [NSView] = [title, body]
        if offer == .installNow {
            let toggle = Switch(isOn: false, label: "Also restart the server") { [weak self] isOn in
                self?.restartServer = isOn
            }
            let label = makeLabel("Also restart the server", font: AppFont.body)
            let note = makeLabel("Ends every terminal on this Mac now, including ones other apps show.", font: AppFont.footnote)
            note.textColor = AppTheme.shared.fgMuted
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 0
            note.preferredMaxLayoutWidth = 340
            let text = NSStackView(views: [label, note])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            let row = NSStackView(views: [toggle, text])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = Metrics.controlGap
            rows.append(row)
        }
        let buttons = NSStackView(views: makeButtons())
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.controlGap
        let footer = NSStackView(views: [NSView(), buttons])
        footer.orientation = .horizontal
        footer.distribution = .fill
        rows.append(footer)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        root.translatesAutoresizingMaskIntoConstraints = false
        stack.pinEdges(to: root, insets: NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24))
        root.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return root
    }

    private func makeButtons() -> [NSView] {
        switch offer {
        case .installNow:
            return [
                PillButton("Not Now") { [weak self] in self?.finish(.later) },
                PillButton("Update and Restart App", style: .primary) { [weak self] in
                    guard let self else { return }
                    self.finish(.install(restartServer: self.restartServer))
                },
            ]
        case .needsNewServer:
            return [
                PillButton("Not Now") { [weak self] in self?.finish(.later) },
                PillButton("Update and End Terminals…", style: .destructive) { [weak self] in self?.confirmEndingSessions() },
                PillButton("Update When Terminals End", style: .primary) { [weak self] in self?.finish(.waitForSessions) },
            ]
        case .waitingForSessions:
            return [
                PillButton("Cancel Scheduled Update") { [weak self] in self?.finish(.cancelWaiting) },
                PillButton("Update and End Terminals…", style: .destructive) { [weak self] in self?.confirmEndingSessions() },
                PillButton("Keep Waiting", style: .primary) { [weak self] in self?.finish(.later) },
            ]
        }
    }

    private func confirmEndingSessions() {
        let parent = parent
        close()
        ConfirmSheet.present(
            on: parent,
            title: "Update and End All Terminals?",
            message: "Every terminal on this Mac ends, including ones other apps show. Terminal panes close; other panes and settings stay.",
            confirm: "Update and End Terminals",
            destructive: true
        ) { [weak self] confirmed in
            self?.deliver(confirmed ? .endSessions : .later)
        }
    }

    private func finish(_ choice: UpdateChoice) {
        close()
        deliver(choice)
    }

    private func close() {
        guard let panel else { return }
        self.panel = nil
        if let sheetParent = panel.sheetParent {
            sheetParent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
    }

    private func deliver(_ choice: UpdateChoice) {
        let completion = completion
        self.completion = nil
        completion?(choice)
    }
}

/// A panel that reports Escape.
private final class SheetPanel: NSPanel {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
