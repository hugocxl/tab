import TabMobileKit
import TabProtocol
import UIKit

/// The files a turn changed, as recorded when it finished, each opening its
/// diff. Comments on the diffs collect here, and go into the message together.
final class AgentChangesViewController: UITableViewController {
    private let controller: AgentChatController
    private let checkpoint: AgentTurnCheckpoint
    private var files: [AgentTurnCheckpoint.File]
    private var totalFiles: Int
    private var nextOffset: Int?
    private var loading = false
    private let addToMessage = UIBarButtonItem()
    private let commentsItem = UIBarButtonItem()
    /// The comments changed, or went into the message.
    var onCommentsChanged: (() -> Void)?
    /// The comments went into the message.
    var onAddedToMessage: (() -> Void)?

    init(controller: AgentChatController, checkpoint: AgentTurnCheckpoint) {
        self.controller = controller
        self.checkpoint = checkpoint
        files = checkpoint.files
        totalFiles = checkpoint.totalFiles
        nextOffset = checkpoint.files.count < checkpoint.totalFiles ? checkpoint.files.count : nil
        super.init(style: .insetGrouped)
        title = "Changes"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// This list in a navigation controller, as a sheet.
    func inSheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        navigation.isToolbarHidden = false
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.subtitle = "+\(checkpoint.additions) −\(checkpoint.deletions)"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "file")
        addToMessage.primaryAction = UIAction(title: "Add to Message") { [weak self] _ in self?.addCommentsToMessage() }
        addToMessage.style = .prominent
        commentsItem.image = UIImage(systemName: "bubble.left.and.text.bubble.right")
        toolbarItems = [commentsItem, .flexibleSpace(), addToMessage]
        refreshComments()
        loadMore()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshComments()
        tableView.reloadData()
    }

    private var comments: [AgentReviewComment] { controller.reviewComments(for: checkpoint.id) }

    private func refreshComments() {
        let comments = comments
        addToMessage.isEnabled = !comments.isEmpty
        commentsItem.isEnabled = !comments.isEmpty
        commentsItem.title = comments.isEmpty ? "Comments" : "Comments (\(comments.count))"
        commentsItem.accessibilityLabel = commentsItem.title
        commentsItem.menu = CommentList.menu(comments) { [weak self] comment in self?.edit(comment) }
    }

    private func edit(_ comment: AgentReviewComment) {
        CommentList.edit(comment, existing: true, from: self) { [weak self] edited in
            guard let self else { return }
            var all = comments
            if let edited, let index = all.firstIndex(where: { $0.id == edited.id }) {
                all[index] = edited
            } else {
                all.removeAll { $0.id == comment.id }
            }
            controller.setReviewComments(all, for: checkpoint.id)
            refreshComments()
            tableView.reloadData()
            onCommentsChanged?()
        }
    }

    private func addCommentsToMessage() {
        if let problem = controller.addReviewToDraft(checkpoint.id) {
            let alert = UIAlertController(title: "Couldn't Add the Comments", message: problem, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCommentsChanged?()
        dismiss(animated: true) { [onAddedToMessage] in onAddedToMessage?() }
    }

    /// Reads the rest of the list a page at a time.
    private func loadMore() {
        guard let offset = nextOffset, !loading else { return }
        loading = true
        Task { [weak self] in
            guard let self else { return }
            defer { loading = false }
            guard let page = try? await controller.checkpoint(checkpoint.id, offset: offset) else {
                nextOffset = nil
                return
            }
            let known = Set(files.map(\.path))
            files += page.files.filter { !known.contains($0.path) }
            totalFiles = page.totalFiles
            nextOffset = page.nextOffset
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { files.count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        var notes: [String] = []
        if totalFiles > files.count, nextOffset == nil {
            notes.append("\(totalFiles - files.count) more files changed. Open them on the Mac.")
        }
        if checkpoint.truncated { notes.append("This turn changed more than Tab recorded.") }
        notes.append("Tap lines in a diff to comment on them. Comments stay with your message until you add them.")
        return notes.joined(separator: "\n")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "file", for: indexPath)
        let file = files[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        let name = (file.path as NSString).lastPathComponent
        content.text = name
        let folder = (file.path as NSString).deletingLastPathComponent
        let counts = NSMutableAttributedString()
        if let additions = file.additions {
            counts.append(NSAttributedString(string: "+\(additions) ", attributes: [.foregroundColor: UIColor.systemGreen]))
        }
        if let deletions = file.deletions {
            counts.append(NSAttributedString(string: "−\(deletions) ", attributes: [.foregroundColor: UIColor.systemRed]))
        }
        let commented = comments.filter { $0.path == file.path }.count
        if commented > 0 { counts.append(NSAttributedString(string: commented == 1 ? "· 1 comment " : "· \(commented) comments ")) }
        if !folder.isEmpty { counts.append(NSAttributedString(string: folder)) }
        content.secondaryAttributedText = counts
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        content.image = UIImage(systemName: "doc.text")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        if indexPath.row == files.count - 1 { loadMore() }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let diff = AgentDiffViewController(controller: controller, checkpoint: checkpoint.id, path: files[indexPath.row].path)
        diff.onCommentsChanged = { [weak self] in
            self?.refreshComments()
            self?.onCommentsChanged?()
        }
        diff.onAddToMessage = { [weak self] in self?.addCommentsToMessage() }
        navigationController?.pushViewController(diff, animated: true)
    }
}

/// Listing and editing review comments, shared by the file list and the diff.
@MainActor
enum CommentList {
    /// A menu with each of `comments`, which `edit` opens.
    static func menu(_ comments: [AgentReviewComment], edit: @escaping (AgentReviewComment) -> Void) -> UIMenu {
        UIMenu(title: "Review Comments", children: comments.map { comment in
            let action = UIAction(title: comment.text, image: UIImage(systemName: "text.bubble")) { _ in edit(comment) }
            action.subtitle = comment.location
            return action
        })
    }

    /// Edits `comment` in a sheet; `done` gets the edited comment, or nil when it was deleted.
    static func edit(_ comment: AgentReviewComment, existing: Bool, from presenter: UIViewController,
                     done: @escaping (AgentReviewComment?) -> Void) {
        let editor = TextEditorViewController(
            title: existing ? "Edit Comment" : "Add Comment",
            note: comment.location + "\n" + comment.source.components(separatedBy: "\n").prefix(6).joined(separator: "\n"),
            text: comment.text, allowsDelete: existing, allowsEmpty: false) { outcome in
                switch outcome {
                case .saved(let text, _):
                    var edited = comment
                    edited.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    done(edited)
                case .deleted:
                    done(nil)
                }
            }
        presenter.present(editor.inSheet(), animated: true)
    }
}

/// One file's recorded diff. Tap a line to select it and another to extend
/// the selection, then comment on the selected lines.
final class AgentDiffViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let controller: AgentChatController
    private let checkpoint: String
    private let path: String
    private let table = UITableView(frame: .zero, style: .plain)
    private var diff: GitDiff?
    private var selection: (rows: ClosedRange<Int>, old: Bool)?
    private var anchor: Int?
    private let commentItem = UIBarButtonItem()
    private let commentsItem = UIBarButtonItem()
    private let addToMessage = UIBarButtonItem()
    var onCommentsChanged: (() -> Void)?
    var onAddToMessage: (() -> Void)?

    init(controller: AgentChatController, checkpoint: String, path: String) {
        self.controller = controller
        self.checkpoint = checkpoint
        self.path = path
        super.init(nibName: nil, bundle: nil)
        title = (path as NSString).lastPathComponent
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.subtitle = (path as NSString).deletingLastPathComponent
        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.register(DiffLineCell.self, forCellReuseIdentifier: "line")
        table.translatesAutoresizingMaskIntoConstraints = false
        table.accessibilityLabel = "Recorded diff. Tap a line to select it, then another to extend the selection."
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        commentItem.primaryAction = UIAction(title: "Comment") { [weak self] _ in self?.addComment() }
        commentsItem.image = UIImage(systemName: "bubble.left.and.text.bubble.right")
        addToMessage.primaryAction = UIAction(title: "Add to Message") { [weak self] _ in self?.onAddToMessage?() }
        addToMessage.style = .prominent
        toolbarItems = [commentItem, commentsItem, .flexibleSpace(), addToMessage]
        addKeyCommand(UIKeyCommand(title: "Select Next Line", action: #selector(selectDown), input: UIKeyCommand.inputDownArrow))
        addKeyCommand(UIKeyCommand(title: "Select Previous Line", action: #selector(selectUp), input: UIKeyCommand.inputUpArrow))
        addKeyCommand(UIKeyCommand(title: "Extend Selection Down", action: #selector(extendDown), input: UIKeyCommand.inputDownArrow,
                                   modifierFlags: .shift))
        addKeyCommand(UIKeyCommand(title: "Extend Selection Up", action: #selector(extendUp), input: UIKeyCommand.inputUpArrow,
                                   modifierFlags: .shift))
        addKeyCommand(UIKeyCommand(title: "Old Lines", action: #selector(selectOld), input: UIKeyCommand.inputLeftArrow))
        addKeyCommand(UIKeyCommand(title: "New Lines", action: #selector(selectNew), input: UIKeyCommand.inputRightArrow))
        addKeyCommand(UIKeyCommand(title: "Comment", action: #selector(commentCommand), input: "\r"))
        refreshToolbar()
        load()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    private func load() {
        var loading = UIContentUnavailableConfiguration.loading()
        loading.text = "Loading the diff"
        contentUnavailableConfiguration = loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await controller.checkpoint(checkpoint, path: path)
                show(reply.diff)
            } catch {
                var failed = UIContentUnavailableConfiguration.empty()
                failed.image = UIImage(systemName: "exclamationmark.triangle")
                failed.text = "Couldn't Load the Diff"
                failed.secondaryText = error.localizedDescription
                contentUnavailableConfiguration = failed
            }
        }
    }

    private func show(_ diff: GitDiff?) {
        self.diff = diff
        guard let diff, !diff.binary, !diff.rows.isEmpty else {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "doc")
            empty.text = diff?.binary == true ? "Binary File" : "No Diff Recorded"
            empty.secondaryText = diff?.binary == true ? "Its changes can't be shown as lines." : "Tab kept no lines for this file."
            contentUnavailableConfiguration = empty
            return
        }
        contentUnavailableConfiguration = nil
        if diff.truncated {
            let note = UILabel()
            note.text = "This diff is cut short. The rest of it is on the Mac."
            note.font = .preferredFont(forTextStyle: .footnote)
            note.textColor = .secondaryLabel
            note.textAlignment = .center
            note.numberOfLines = 0
            note.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: 44)
            table.tableFooterView = note
        }
        table.reloadData()
    }

    private var comments: [AgentReviewComment] { controller.reviewComments(for: checkpoint) }

    private var selectedLines: (first: UInt64, last: UInt64, source: String)? {
        guard let diff, let selection else { return nil }
        return AgentReviewComment.selection(diff.rows[selection.rows], old: selection.old)
    }

    private func refreshToolbar() {
        let lines = selectedLines
        commentItem.isEnabled = lines != nil
        commentItem.title = "Comment"
        commentItem.accessibilityLabel = lines.map { $0.first == $0.last ? "Comment on line \($0.first)" : "Comment on lines \($0.first) to \($0.last)" }
            ?? "Comment"
        let comments = comments
        commentsItem.isEnabled = !comments.isEmpty
        commentsItem.title = comments.isEmpty ? "Comments" : "Comments (\(comments.count))"
        commentsItem.accessibilityLabel = commentsItem.title
        commentsItem.menu = CommentList.menu(comments) { [weak self] comment in self?.edit(comment, existing: true) }
        addToMessage.isEnabled = !comments.isEmpty
        table.accessibilityValue = lines.map { "Selected \($0.first == $0.last ? "line \($0.first)" : "lines \($0.first) through \($0.last)"), \(selection?.old == true ? "old" : "new") side" }
            ?? "No lines selected"
    }

    /// The side a row's line counts on: removed lines are the old file's,
    /// others the new file's. Nil for hunk headers.
    private func side(_ index: Int) -> Bool? {
        guard let row = diff?.rows[index], row.kind != .hunk else { return nil }
        if row.kind == .deletion { return row.oldLineNumber == nil ? nil : true }
        return row.newLineNumber == nil ? (row.oldLineNumber == nil ? nil : true) : false
    }

    private func select(_ index: Int, extend: Bool, old: Bool? = nil) {
        guard let old = old ?? side(index) else { return }
        let previous = selection.map { Set($0.rows) } ?? []
        if extend, let anchor, selection?.old == old,
           diff.map({ !$0.rows[min(anchor, index)...max(anchor, index)].contains { $0.kind == .hunk } }) == true {
            selection = (min(anchor, index)...max(anchor, index), old)
        } else {
            anchor = index
            selection = (index...index, old)
        }
        UISelectionFeedbackGenerator().selectionChanged()
        let changed = previous.symmetricDifference(selection.map { Set($0.rows) } ?? [])
        table.reconfigureRows(at: changed.map { IndexPath(row: $0, section: 0) })
        table.scrollToRow(at: IndexPath(row: index, section: 0), at: .none, animated: true)
        refreshToolbar()
    }

    private func clearSelection() {
        let rows = selection.map { Array($0.rows) } ?? []
        selection = nil
        anchor = nil
        table.reconfigureRows(at: rows.map { IndexPath(row: $0, section: 0) })
        refreshToolbar()
    }

    private func move(_ delta: Int, extend: Bool) {
        guard let diff else { return }
        let old = selection?.old ?? false
        let current = selection.map { delta < 0 ? $0.rows.lowerBound : $0.rows.upperBound }
        var next = current.map { $0 + delta } ?? (delta > 0 ? 0 : diff.rows.count - 1)
        while diff.rows.indices.contains(next) {
            let row = diff.rows[next]
            if row.kind != .hunk, (old ? row.oldLineNumber : row.newLineNumber) != nil {
                select(next, extend: extend, old: old)
                return
            }
            next += delta
        }
    }

    @objc private func selectDown() { move(1, extend: false) }
    @objc private func selectUp() { move(-1, extend: false) }
    @objc private func extendDown() { move(1, extend: true) }
    @objc private func extendUp() { move(-1, extend: true) }
    @objc private func selectOld() { switchSide(old: true) }
    @objc private func selectNew() { switchSide(old: false) }
    @objc private func commentCommand() { addComment() }

    /// Context lines are on both sides; the arrows choose which one a comment is about.
    private func switchSide(old: Bool) {
        guard let selection, let row = diff?.rows[selection.rows.lowerBound],
              (old ? row.oldLineNumber : row.newLineNumber) != nil else { return }
        select(selection.rows.lowerBound, extend: false, old: old)
    }

    private func addComment() {
        guard let selection, let lines = selectedLines else { return }
        let comment = AgentReviewComment(checkpoint: checkpoint, path: path, old: selection.old, firstLine: lines.first,
                                         lastLine: lines.last, source: lines.source, text: "")
        edit(comment, existing: false)
    }

    private func edit(_ comment: AgentReviewComment, existing: Bool) {
        CommentList.edit(comment, existing: existing, from: self) { [weak self] edited in
            guard let self else { return }
            var all = comments
            all.removeAll { $0.id == comment.id }
            if let edited {
                if let index = comments.firstIndex(where: { $0.id == comment.id }) { all.insert(edited, at: index) } else { all.append(edited) }
            }
            controller.setReviewComments(all, for: checkpoint)
            if !existing { clearSelection() }
            refreshToolbar()
            table.reloadData()
            onCommentsChanged?()
        }
    }

    /// Whether a comment covers the row's line.
    private func commented(_ row: GitDiffRow) -> Bool {
        comments.contains { comment in
            guard comment.path == path, let line = comment.old ? row.oldLineNumber : row.newLineNumber else { return false }
            return (comment.firstLine ... comment.lastLine).contains(line)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { diff?.rows.count ?? 0 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "line", for: indexPath)
        guard let diff, let cell = cell as? DiffLineCell else { return cell }
        let row = diff.rows[indexPath.row]
        cell.configure(row, selected: selection?.rows.contains(indexPath.row) == true, commented: commented(row))
        return cell
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool { side(indexPath.row) != nil }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        // Tapping the selection clears it; another line extends it.
        if let selection, selection.rows.contains(indexPath.row) {
            clearSelection()
            return
        }
        select(indexPath.row, extend: selection != nil)
    }
}

/// One line of a diff: its old and new line numbers, then its text, tinted
/// by whether it was added or removed.
private final class DiffLineCell: UITableViewCell {
    private let numbers = UILabel()
    private let line = UILabel()
    private let marker = UIImageView(image: UIImage(systemName: "text.bubble.fill"))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        numbers.font = font
        numbers.textColor = .tertiaryLabel
        numbers.textAlignment = .right
        line.font = font
        line.numberOfLines = 0
        line.lineBreakMode = .byCharWrapping
        marker.tintColor = .tintColor
        marker.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9)
        marker.translatesAutoresizingMaskIntoConstraints = false
        for view in [numbers, line] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        contentView.addSubview(marker)
        let column = numbers.widthAnchor.constraint(equalToConstant: 72)
        NSLayoutConstraint.activate([
            column,
            numbers.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            numbers.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1),
            line.leadingAnchor.constraint(equalTo: numbers.trailingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            line.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1),
            line.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -1),
            marker.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            marker.centerYAnchor.constraint(equalTo: numbers.centerYAnchor),
        ])
        selectionStyle = .none
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ row: GitDiffRow, selected: Bool, commented: Bool) {
        let old = row.oldLineNumber.map(String.init) ?? ""
        let new = row.newLineNumber.map(String.init) ?? ""
        numbers.text = row.kind == .hunk ? "" : "\(old.padding(toLength: 4, withPad: " ", startingAt: 0)) \(new)"
        line.text = row.text.isEmpty ? " " : row.text
        marker.isHidden = !commented
        let tint: UIColor
        switch row.kind {
        case .addition:
            tint = UIColor.systemGreen.withAlphaComponent(0.14)
            line.textColor = .label
        case .deletion:
            tint = UIColor.systemRed.withAlphaComponent(0.14)
            line.textColor = .label
        case .hunk:
            tint = .secondarySystemBackground
            line.textColor = .secondaryLabel
        default:
            tint = .clear
            line.textColor = .label
        }
        backgroundColor = selected ? UIColor.tintColor.withAlphaComponent(0.22) : tint
        accessibilityLabel = [row.kind == .addition ? "Added" : row.kind == .deletion ? "Removed" : nil,
                              row.newLineNumber.map { "line \($0)" } ?? row.oldLineNumber.map { "old line \($0)" },
                              row.text].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = selected ? [.button, .selected] : .button
        accessibilityValue = commented ? "Commented" : nil
    }
}
