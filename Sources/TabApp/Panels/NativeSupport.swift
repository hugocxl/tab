import AppKit
import TabClient
import TabCore
import TabProtocol

/// The project a native panel or pane works in. One controller serves one
/// project for its whole life.
public struct NativeProject: Equatable, Sendable {
    public var id: ProjectId
    public var name: String
    /// The project's folder on its server.
    public var path: String
    public var serverId: ServerId
    /// Whether the folder is on this Mac, so Finder can show it.
    public var isLocal: Bool

    public init(id: ProjectId, name: String, path: String, serverId: ServerId, isLocal: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.serverId = serverId
        self.isLocal = isLocal
    }

    /// The absolute path of a project-relative `path`.
    public func absolutePath(_ relative: String) -> String {
        guard !relative.isEmpty else { return path }
        return path.hasSuffix("/") ? path + relative : path + "/" + relative
    }
}

/// Where native panels and panes send Git and file requests: the side
/// connection of the project's server, so they never wait behind terminals.
public protocol NativeTransport: AnyObject, Sendable {
    func git(_ request: GitRequest) async throws -> GitReply
    func files(_ request: FilesRequest) async throws -> FilesReply
}

extension ServerClient: NativeTransport {}

/// What every native panel and pane needs from the app.
@MainActor
public protocol NativeHost: AnyObject {
    /// The project the controller works in.
    var nativeProject: NativeProject { get }
    /// The project server's side connection, or `nil` while it is not
    /// connected. Controllers wait for `reconnected()` instead of failing.
    var nativeTransport: NativeTransport? { get }
    var theme: AppTheme { get }
    /// Shows a short message over the window.
    func showToast(_ message: String, style: Toast.Style)
    /// Asks a yes/no question as a sheet on the window.
    func confirm(title: String, message: String, confirmTitle: String, destructive: Bool,
                 completion: @escaping (Bool) -> Void)
}

extension NativeHost {
    /// Asks the project's server to report repository changes as
    /// `gitChanged`, as Codesh does for the current project. A server keeps
    /// one repository watch per connection, so the latest project shown wins.
    public func watchRepository() {
        guard let transport = nativeTransport else { return }
        let request = GitRequest(project: nativeProject.id, action: .watch)
        Task { _ = try? await transport.git(request) }
    }
}

/// Readable server errors shared by the native panels and panes.
public enum NativeErrors {
    /// The server's message without its protocol code, with missing files,
    /// folders and repositories said plainly.
    public static func friendly(_ error: String, folder: Bool) -> String {
        let lower = error.lowercased()
        if lower.contains("worktree is missing") || lower.contains("not a git repository")
            || lower.contains("not a repository")
        {
            return notRepository
        }
        if lower.contains("badpath") || lower.contains("no such file or directory") || lower.contains("not found") {
            return folder ? "Folder not found" : "File not found"
        }
        guard let separator = error.range(of: ": ") else { return error }
        let code = error[..<separator.lowerBound]
        guard !code.contains(where: \.isWhitespace) else { return error }
        return String(error[separator.upperBound...])
    }

    public static func friendly(_ error: Error, folder: Bool) -> String {
        friendly(describe(error), folder: folder)
    }

    /// The text of an error from a request.
    public static func describe(_ error: Error) -> String {
        if let error = error as? ClientError { return error.description }
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return String(describing: error)
    }

    public static let notRepository = "Not a Git repository"
    public static let notRepositoryHint = "Open a folder containing a Git repository to view changes."
    public static let unexpectedReply = "Unexpected reply"
}

/// Project-relative path helpers. Paths use `/` and the root is `""`.
public enum NativePath {
    /// The folder holding `path`; `""` for the project root.
    public static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// The last component of `path`.
    public static func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Whether `path` is `directory` or inside it; everything is inside the root.
    public static func isWithin(_ path: String, _ directory: String) -> Bool {
        if directory.isEmpty || path == directory { return true }
        return path.hasPrefix(directory) && path.dropFirst(directory.count).first == "/"
    }

    /// `name` inside `directory`.
    public static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }

    /// Whether `name` can name a new file or folder: one component, not `.` or `..`.
    public static func isValidName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
}

/// The colors and fonts the native panels share.
@MainActor
public enum NativeStyle {
    /// The side panel card: 6% foreground over the background in dark
    /// themes, mostly white in light ones.
    public static func panel(_ theme: AppTheme) -> NSColor {
        if theme.palette.isLight {
            return theme.bg.blended(withFraction: 0.7, of: .white) ?? theme.bg
        }
        return theme.palette.fg.blended(over: theme.palette.bg, amount: 0.06).nsColor
    }

    /// The code font for editors and diffs: the terminal's first installed
    /// font family at its size, else the system monospaced font.
    public static func codeFont(_ settings: TerminalSettings) -> NSFont {
        let size = CGFloat(min(max(settings.fontSize, 6), 72))
        for family in settings.fontFamilies {
            if let font = NSFont(name: family, size: size) { return font }
            let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
            if let font = NSFont(descriptor: descriptor, size: size), font.familyName == family { return font }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The width of one character cell and the height of a line in `font`.
    public static func cell(_ font: NSFont) -> NSSize {
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        let height = (font.ascender - font.descender + font.leading).rounded(.up) + 3
        return NSSize(width: max(width, 1), height: max(height, 1))
    }
}

/// The rounded card a side panel sits in, as in Codesh: 10pt radius, hairline
/// border and the panel fill. The shell places it 8pt from the window's top,
/// right and bottom edges.
public final class NativePanelCard: ThemedView {
    /// Whether to draw the card; off when the shell draws the panel's frame.
    public var drawsCard = true { didSet { needsDisplay = true } }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        guard let layer else { return }
        guard drawsCard else {
            layer.backgroundColor = nil
            layer.borderWidth = 0
            return
        }
        layer.backgroundColor = NativeStyle.panel(theme).cgColor
        layer.cornerRadius = Metrics.cardRadius
        layer.borderWidth = Metrics.border
        layer.borderColor = theme.cardBorder.cgColor
        layer.masksToBounds = true
    }

    public override func themeDidChange() {
        needsDisplay = true
    }
}

/// A 36pt panel header: a glyph, a 13pt semibold title and trailing
/// 16pt glyph buttons.
final class NativePanelHeader: ThemedView {
    let titleLabel: NSTextField
    private let iconView = NSImageView()
    private let trailing = NSStackView()

    init(icon: AppIcon, title: String) {
        titleLabel = makeLabel(title, font: AppFont.header)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        iconView.image = icon.image(size: Metrics.glyph)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.orientation = .horizontal
        trailing.spacing = 2
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(trailing)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.glyph),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.glyph),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Metrics.controlGap),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -Metrics.controlGap),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    func addTrailing(_ view: NSView) {
        trailing.addArrangedSubview(view)
    }

    override func themeDidChange() {
        titleLabel.textColor = theme.fgMuted
        iconView.contentTintColor = theme.fgMuted
    }
}

/// A centered muted message filling a pane or panel, such as "Loading…".
final class NativeMessageView: ThemedView {
    private let label: NSTextField
    private let detail: NSTextField

    init(_ text: String = "") {
        label = makeLabel(text, font: AppFont.body)
        detail = makeLabel("", font: AppFont.footnote)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for field in [label, detail] {
            field.alignment = .center
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
        }
        let stack = NSStackView(views: [label, detail])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.gutter),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.gutter),
        ])
        set(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var text: String { label.stringValue }

    func set(_ text: String) {
        label.stringValue = text
        detail.stringValue = text == NativeErrors.notRepository ? NativeErrors.notRepositoryHint : ""
        detail.isHidden = detail.stringValue.isEmpty
    }

    override func themeDidChange() {
        label.textColor = theme.fgMuted
        detail.textColor = theme.fgMuted
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(runHandler) : nil, keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func runHandler() { handler() }
}

/// A one-line name field for naming files inline: surface fill, accent
/// ring, Return submits, Escape or leaving it cancels.
final class InlineNameField: ThemedView, NSTextFieldDelegate {
    let field = NSTextField(string: "")
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onChange: (() -> Void)?
    private var finished = false

    init(text: String, label: String) {
        super.init(frame: .zero)
        field.stringValue = text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppFont.body
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.delegate = self
        field.setAccessibilityLabel(label)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Focuses the field with the name selected, without its extension.
    func begin() {
        window?.makeFirstResponder(field)
        guard let editor = field.currentEditor() else { return }
        let name = field.stringValue as NSString
        let dot = name.range(of: ".", options: .backwards)
        let length = dot.location != NSNotFound && dot.location > 0 ? dot.location : name.length
        editor.selectedRange = NSRange(location: 0, length: length)
    }

    /// Lets the field be submitted again after a refused name.
    func resume() {
        finished = false
        window?.makeFirstResponder(field)
    }

    override func themeDidChange() {
        field.textColor = theme.fg
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: Metrics.radiusSmall, yRadius: Metrics.radiusSmall)
        theme.surface.setFill()
        path.fill()
        theme.accent.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finished = true
            onSubmit?(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finished = true
            onCancel?()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        onCancel?()
    }
}
