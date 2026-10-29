import AppKit
import TabCore

/// Add Project → Remote: browses a server's folders from its Home. Type a
/// path and press Return to go there, click a folder to open it, Up to go
/// to the parent, and Add Project to add the folder shown.
@MainActor
public final class RemoteFolderBrowser: ThemedView {
    public typealias List = (ServerPath) async throws -> [ServerPath]

    private let list: List
    private let choose: (ServerPath) -> Void
    private let path: InsetTextField
    private let up: IconButton
    private let rows = NSStackView()
    private let scroll = ScrollView()
    private let status = DialogParts.note("")
    private let spinner = Spinner()
    private let addButton = PillButton("Add Project", style: .primary)
    private var current: ServerPath
    private var loading: Task<Void, Never>?
    /// Closes whatever shows the browser.
    public var dismiss: (() -> Void)?

    /// - Parameters:
    ///   - list: the folders directly inside an absolute path there.
    ///   - choose: the folder to add as a project.
    public init(serverName: String, start: ServerPath, list: @escaping List, choose: @escaping (ServerPath) -> Void) {
        self.list = list
        self.choose = choose
        current = start
        path = InsetTextField(value: start.rawValue, placeholder: "/path/on/\(serverName)",
                              label: "Folder on \(serverName)", width: nil, monospaced: true)
        up = IconButton(.chevronUp, label: "Enclosing Folder")
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 420))
        translatesAutoresizingMaskIntoConstraints = false
        up.toolTip = "Enclosing Folder"
        up.action = { [weak self] in self?.goUp() }
        path.onCommit = { [weak self] text in self?.open(ServerPath(text)) }
        addButton.action = { [weak self] in
            guard let self else { return }
            self.choose(self.current)
            self.dismiss?()
        }
        let cancel = PillButton("Cancel") { [weak self] in self?.dismiss?() }
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.content.addSubview(rows)
        rows.pinEdges(to: scroll.content, insets: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0))
        let card = Card()
        card.addSubview(scroll)
        scroll.pinEdges(to: card, insets: NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4))
        let content = DialogParts.column([
            DialogParts.title("Add Project on \(serverName)"),
            DialogParts.row([up, path]),
            card,
            DialogParts.row([spinner, status]),
            DialogParts.buttons(trailing: [cancel, addButton]),
        ])
        addSubview(content)
        content.pinEdges(to: self, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        widthAnchor.constraint(equalToConstant: 480).isActive = true
        open(start)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The folder above `path`, or `nil` at the root.
    nonisolated static func parent(of path: ServerPath) -> ServerPath? {
        let text = path.rawValue
        guard text != "/" else { return nil }
        var trimmed = Substring(text)
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return nil }
        let parent = trimmed[..<slash]
        return ServerPath(parent.isEmpty ? "/" : String(parent))
    }

    /// The last component of a folder path, for its row.
    nonisolated static func name(of path: ServerPath) -> String {
        path.rawValue.split(separator: "/").last.map(String.init) ?? path.rawValue
    }

    private func goUp() {
        guard let parent = Self.parent(of: current) else { return }
        open(parent)
    }

    private func open(_ folder: ServerPath) {
        loading?.cancel()
        guard folder.rawValue.hasPrefix("/") else {
            show(error: "Enter an absolute path")
            return
        }
        spinner.isHidden = false
        status.stringValue = "Loading…"
        status.textColor = theme.fgMuted
        addButton.isEnabled = false
        loading = Task { [weak self, list] in
            let result: Result<[ServerPath], Error>
            do {
                result = .success(try await list(folder))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self else { return }
            self.spinner.isHidden = true
            switch result {
            case .success(let folders):
                self.current = folder
                self.path.setSavedValue(folder.rawValue)
                self.up.isEnabled = Self.parent(of: folder) != nil
                self.addButton.isEnabled = true
                self.status.stringValue = folders.isEmpty ? "No folders inside." : ""
                self.show(folders)
            case .failure(let error):
                self.show(error: error.localizedDescription)
            }
        }
    }

    private func show(_ folders: [ServerPath]) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for folder in folders.sorted(by: { Self.name(of: $0).localizedStandardCompare(Self.name(of: $1)) == .orderedAscending }) {
            let row = ListRow(title: Self.name(of: folder), icon: AppIcon.folder.image(),
                              accessory: AppIcon.chevronRight.image().map(NSImageView.init(image:)))
            row.onClick = { [weak self] in self?.open(folder) }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        scroll.scrollOffset = 0
    }

    private func show(error: String) {
        spinner.isHidden = true
        status.stringValue = error
        status.textColor = theme.danger
        addButton.isEnabled = false
    }
}
