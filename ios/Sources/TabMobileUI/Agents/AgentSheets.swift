import TabMobileKit
import UIKit

/// A sheet for writing longer text, such as a queued prompt or a review
/// comment: a scrolling multiline editor under a note, with Save and Cancel,
/// and optionally a switch and Delete. Saving or deleting reports once.
final class TextEditorViewController: UIViewController, UITextViewDelegate {
    enum Outcome {
        case saved(text: String, option: Bool)
        case deleted
    }

    private let note: String
    private let initialText: String
    private let option: String?
    private let allowsDelete: Bool
    private let allowsEmpty: Bool
    private let onFinish: (Outcome) -> Void
    private let text = UITextView()
    private let optionSwitch = UISwitch()
    private var finished = false

    /// `option` names a switch shown under the text; `allowsDelete` adds Delete.
    init(title: String, note: String, text: String, option: String? = nil, allowsDelete: Bool = false,
         allowsEmpty: Bool = true, onFinish: @escaping (Outcome) -> Void) {
        self.note = note
        initialText = text
        self.option = option
        self.allowsDelete = allowsDelete
        self.allowsEmpty = allowsEmpty
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// This editor in a navigation controller, as a resizable sheet.
    func inSheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.modalPresentationStyle = .formSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let save = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.save() })
        save.style = .prominent
        navigationItem.rightBarButtonItem = save

        let noteLabel = UILabel()
        noteLabel.text = note
        noteLabel.font = .preferredFont(forTextStyle: .footnote)
        noteLabel.adjustsFontForContentSizeCategory = true
        noteLabel.textColor = .secondaryLabel
        noteLabel.numberOfLines = 0

        text.text = initialText
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.backgroundColor = .secondarySystemGroupedBackground
        text.layer.cornerRadius = 12
        text.layer.cornerCurve = .continuous
        text.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        text.delegate = self
        text.alwaysBounceVertical = true

        let stack = UIStackView(arrangedSubviews: [noteLabel, text])
        stack.axis = .vertical
        stack.spacing = 12
        if let option {
            let label = UILabel()
            label.text = option
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            optionSwitch.accessibilityLabel = option
            let row = UIStackView(arrangedSubviews: [label, optionSwitch])
            row.alignment = .center
            row.spacing = 12
            stack.addArrangedSubview(row)
        }
        if allowsDelete {
            var delete = UIButton.Configuration.glass()
            delete.title = "Delete"
            delete.image = UIImage(systemName: "trash")
            delete.imagePadding = 6
            delete.baseForegroundColor = .systemRed
            let button = UIButton(configuration: delete, primaryAction: UIAction { [weak self] _ in self?.finish(.deleted) })
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -12),
            text.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        let fills = stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12)
        fills.priority = .defaultHigh
        fills.isActive = true
        addKeyCommand(UIKeyCommand(title: "Save", action: #selector(saveCommand), input: "\r", modifierFlags: .command))
        refreshSave()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        text.becomeFirstResponder()
    }

    @objc private func saveCommand() { save() }

    func textViewDidChange(_ textView: UITextView) { refreshSave() }

    private func refreshSave() {
        navigationItem.rightBarButtonItem?.isEnabled = allowsEmpty
            || !(text.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard navigationItem.rightBarButtonItem?.isEnabled == true else { return }
        finish(.saved(text: text.text ?? "", option: optionSwitch.isOn))
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        onFinish(outcome)
        dismiss(animated: true)
    }
}

/// A searchable list in a sheet, such as the conversation's prompts or the
/// conversations saved on the Mac. Choosing an entry closes it.
final class SearchPickerViewController: UITableViewController, UISearchResultsUpdating {
    private let placeholder: String
    private var entries: [AgentPickerEntry] = []
    private var shown: [AgentPickerEntry] = []
    private var note: String?
    private let onSelect: (AgentPickerEntry) -> Void
    private let search = UISearchController(searchResultsController: nil)

    init(title: String, placeholder: String, onSelect: @escaping (AgentPickerEntry) -> Void) {
        self.placeholder = placeholder
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// This picker in a navigation controller, as a resizable sheet.
    func inSheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.modalPresentationStyle = .formSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = placeholder
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "entry")
        filter()
    }

    /// Shows `entries`, keeping the search; `note` explains the list below it.
    func update(_ entries: [AgentPickerEntry], note: String?) {
        self.entries = entries
        self.note = note
        filter()
    }

    func updateSearchResults(for searchController: UISearchController) { filter() }

    private func filter() {
        let query = search.searchBar.text ?? ""
        shown = entries.filter { $0.matches(query) }
        guard isViewLoaded else { return }
        tableView.reloadData()
        var empty: UIContentUnavailableConfiguration?
        if shown.isEmpty {
            empty = entries.isEmpty ? .empty() : .search()
            if entries.isEmpty { empty?.secondaryText = note }
        }
        contentUnavailableConfiguration = empty
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { shown.count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        shown.isEmpty ? nil : note
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath)
        let entry = shown[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = entry.title
        content.textProperties.numberOfLines = 2
        content.secondaryText = entry.detail
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let entry = shown[indexPath.row]
        dismiss(animated: true) { [onSelect] in onSelect(entry) }
    }
}
