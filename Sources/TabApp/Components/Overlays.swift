import AppKit

/// A short message that floats at the bottom of a view and fades away.
public final class Toast: ThemedView {
    public enum Style: Sendable {
        case info, error
    }

    private let label: NSTextField
    public let style: Style

    init(_ message: String, style: Style) {
        label = makeLabel(message, font: AppFont.body)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.pinEdges(to: self, insets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(message)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var message: String { label.stringValue }

    public override func themeDidChange() {
        label.textColor = style == .error ? theme.danger : theme.fg
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.cardRadius, yRadius: Metrics.cardRadius)
        theme.raised.setFill()
        path.fill()
        theme.cardBorder.setStroke()
        path.stroke()
    }

    /// Shows `message` at the bottom of `view` for `duration` seconds.
    @discardableResult
    public static func show(_ message: String, style: Style = .info, in view: NSView, duration: TimeInterval = 3) -> Toast {
        view.subviews.compactMap { $0 as? Toast }.forEach { $0.removeFromSuperview() }
        let toast = Toast(message, style: style)
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            toast.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        NSAccessibility.post(
            element: toast,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak toast] in
            guard let toast else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                toast.removeFromSuperview()
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                toast.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { toast.removeFromSuperview() }
            })
        }
        return toast
    }
}

/// A confirmation asked as a sheet on a window, or as a modal alert when
/// there is no window.
@MainActor
public enum ConfirmSheet {
    /// Asks `title`; `completion` gets whether the user confirmed.
    public static func present(
        on window: NSWindow?,
        title: String,
        message: String,
        confirm: String,
        destructive: Bool = false,
        theme: AppTheme? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        let theme = theme ?? .shared
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .critical : .warning
        let button = alert.addButton(withTitle: confirm)
        button.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        alert.window.appearance = theme.nsAppearance
        guard let window else {
            completion(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }
}
