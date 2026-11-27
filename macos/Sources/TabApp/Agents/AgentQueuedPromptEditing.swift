import AppKit
import TabClient
import TabCore
import TabProtocol

/// The user's edit of one queued prompt, kept until the server acknowledges it. Its
/// attachments are either ones the server already holds, named by ID, or new ones with
/// their bytes.
struct AgentQueuedPromptEdit {
    enum Attachment {
        case existing(AgentChatAttachmentDescriptor)
        case added(AgentDraftAttachment)

        var id: String {
            switch self {
            case .existing(let descriptor): return descriptor.id
            case .added(let attachment): return attachment.id
            }
        }

        var byteCount: Int {
            switch self {
            case .existing(let descriptor): return descriptor.byteCount
            case .added(let attachment): return attachment.data.count
            }
        }

        /// For the attachment strip; an existing attachment's bytes stay on the server.
        var draft: AgentDraftAttachment {
            switch self {
            case .existing(let descriptor):
                return AgentDraftAttachment(id: descriptor.id, name: descriptor.name, mimeType: descriptor.mimeType,
                                            data: Data(), storedByteCount: descriptor.byteCount)
            case .added(let attachment): return attachment
            }
        }
    }

    let promptID: String
    /// The queue revision this edit applies to.
    var baseRevision: UInt64
    var text: String
    var useCurrentSettings = false
    var attachments: [Attachment]
    /// The prompt's attachments at `baseRevision`, in order.
    var originalAttachmentIDs: [String]
    /// Kept attachments that were removed elsewhere since the edit began.
    var lostAttachments: [String] = []

    init(prompt: AgentQueuedPrompt) {
        promptID = prompt.id
        baseRevision = prompt.revision
        text = prompt.text
        attachments = prompt.attachments.map { .existing($0) }
        originalAttachmentIDs = prompt.attachments.map(\.id)
    }

    var attachmentsChanged: Bool { attachments.map(\.id) != originalAttachmentIDs }

    /// Why the server would refuse this edit, checked before sending it.
    var validationError: String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty { return AgentQueuedEdit.emptyPromptMessage }
        if text.utf8.count > AgentPaneController.maximumPromptBytes { return "A queued prompt holds at most \(AgentPaneController.maximumPromptBytes / 1024) KB of text." }
        if attachments.count > AgentChatAttachment.maxCount || attachments.reduce(0, { $0 + $1.byteCount }) > AgentChatAttachment.maxTotalBytes {
            return "Attach up to \(AgentChatAttachment.maxCount) files, totaling at most \(AgentChatAttachment.maxTotalBytes / 1024 / 1024) MB."
        }
        return nil
    }

    /// The request that saves it: the long-standing text edit when only text or settings
    /// changed, which every server understands, else the whole-prompt edit.
    func request(session: SessionId, settings: AgentQueuedSettings?) -> AgentChatRequest {
        if !attachmentsChanged, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .editQueued(session: session, id: promptID, text: text, expectedRevision: baseRevision, settings: settings)
        }
        var kept: [String] = [], added: [AgentChatAttachment] = []
        for attachment in attachments {
            switch attachment {
            case .existing(let descriptor): kept.append(descriptor.id)
            case .added(let draft): added.append(AgentChatAttachment(id: draft.id, name: draft.name, mimeType: draft.mimeType, data: draft.data))
            }
        }
        return .editQueuedPrompt(session: session, id: promptID, expectedRevision: baseRevision,
                                 edit: AgentQueuedEdit(text: text, settings: settings, keptAttachments: kept, addedAttachments: added))
    }

    /// Whether `prompt` already shows this edit, as after a save whose reply was lost.
    func isApplied(in prompt: AgentQueuedPrompt) -> Bool {
        prompt.text == text && prompt.attachments.map(\.id) == attachments.map(\.id)
    }

    /// This edit on top of the prompt as it is now: attachments removed elsewhere drop out
    /// and are noted, and ones added elsewhere stay, so saving removes nothing unseen.
    func rebased(on prompt: AgentQueuedPrompt) -> Self {
        var copy = self
        let present = Dictionary(prompt.attachments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        copy.lostAttachments = attachments.compactMap {
            if case .existing(let descriptor) = $0, present[descriptor.id] == nil { return descriptor.name }
            return nil
        }
        copy.attachments = attachments.filter {
            if case .existing(let descriptor) = $0 { return present[descriptor.id] != nil }
            return true
        }
        let known = Set(copy.attachments.map(\.id))
        let original = Set(originalAttachmentIDs)
        copy.attachments += prompt.attachments.filter { !known.contains($0.id) && !original.contains($0.id) }.map { .existing($0) }
        copy.baseRevision = prompt.revision
        copy.originalAttachmentIDs = prompt.attachments.map(\.id)
        return copy
    }

    mutating func remove(_ id: String) { attachments.removeAll { $0.id == id } }

    /// Adds `drafts`, or puts the first in place of `replacing`; the reason when they don't fit.
    mutating func add(_ drafts: [AgentDraftAttachment], replacing: String? = nil) -> String? {
        var next = attachments
        if let replacing, let index = next.firstIndex(where: { $0.id == replacing }), let first = drafts.first {
            next[index] = .added(first)
            next += drafts.dropFirst().map { .added($0) }
        } else {
            next += drafts.map { .added($0) }
        }
        guard next.count <= AgentChatAttachment.maxCount,
              next.reduce(0, { $0 + $1.byteCount }) <= AgentChatAttachment.maxTotalBytes else {
            return "Attach up to \(AgentChatAttachment.maxCount) files, totaling at most \(AgentChatAttachment.maxTotalBytes / 1024 / 1024) MB."
        }
        attachments = next
        return nil
    }
}

/// An edit the server didn't take, and what became of its prompt.
struct AgentQueuedEditRecovery {
    enum Choice: Equatable { case editAgain, copy, stash, discard, keep }

    var edit: AgentQueuedPromptEdit
    /// The prompt as the server has it now; nil once it was sent or removed.
    var latest: AgentQueuedPrompt?
    var reason: String

    /// The edit can still be applied to the prompt, after another look.
    var canEditAgain: Bool { latest.map { $0.state != .delivering } ?? false }
}

extension AgentPaneController {
    /// Opens a queued prompt's editor, with an unsaved earlier edit of it when there is one.
    func editQueued(_ prompt: AgentQueuedPrompt) {
        guard !disposed, commandTask == nil, !composerWork.queueEditorOpen else { return }
        let start = composerWork.queueEdits[prompt.id].map { $0.rebased(on: prompt) } ?? AgentQueuedPromptEdit(prompt: prompt)
        composerWork.queueEditorOpen = true
        Task { [weak self] in
            guard let self else { return }
            let present = self.composerWork.presentQueuedEditor ?? { [weak self] in await self?.presentQueuedEditorSheet($0) }
            let edited = await present(start)
            self.composerWork.queueEditorOpen = false
            guard let edited, !self.disposed else { return }
            self.saveQueuedEdit(edited)
        }
    }

    private var currentQueuedSettings: AgentQueuedSettings {
        .init(model: effectiveModel, effort: reasoningEffort, planMode: snapshot?.planMode == true)
    }

    /// Saves an edit against the revision it was made on. The edit stays with the pane
    /// until the server acknowledges it; it never delivers the prompt.
    func saveQueuedEdit(_ edit: AgentQueuedPromptEdit) {
        composerWork.queueEdits[edit.promptID] = edit
        defer { updateControls() }
        if let error = edit.validationError { showComposerError(error); return }
        guard commandTask == nil else {
            showComposerError("Another request is in progress. Your edit is kept; open the prompt's editor to save it.")
            return
        }
        run(edit.request(session: session, settings: edit.useCurrentSettings ? currentQueuedSettings : nil),
            onReply: { [weak self] result in self?.queuedEditReplied(edit, result) },
            onFailure: { [weak self] error in self?.queuedEditFailed(edit, error) })
    }

    private func queuedEditReplied(_ edit: AgentQueuedPromptEdit, _ result: AgentChatSnapshot) {
        guard let prompt = result.queuedPrompts?.first(where: { $0.id == edit.promptID }), edit.isApplied(in: prompt) else {
            queuedEditFailed(edit, ModelError("The server did not apply the edit."))
            return
        }
        composerWork.queueEdits[edit.promptID] = nil
        updateControls()
    }

    /// A failed save: the server may still have applied it, as when its reply was lost,
    /// so read the queue before asking the user what to do with the edit.
    private func queuedEditFailed(_ edit: AgentQueuedPromptEdit, _ error: Error) {
        let generation = connectionGeneration
        let unsupported = (error as? ClientError)?.serverCode == .unsupported
        Task { [weak self] in
            guard let self else { return }
            let latest: AgentChatSnapshot
            do { latest = try await self.request(.read(session: self.session)) } catch {
                guard !self.disposed else { return }
                self.showComposerError("Couldn't save the queued prompt: \(error.localizedDescription) Your edit is kept; open the prompt's editor to try again.")
                return
            }
            guard !self.disposed, generation == self.connectionGeneration, self.composerWork.queueEdits[edit.promptID] != nil else { return }
            self.composerWorkAccepted(latest)
            guard self.composerWork.queueEdits[edit.promptID] != nil else { return }
            let prompt = latest.queuedPrompts?.first { $0.id == edit.promptID }
            let reason: String
            if unsupported {
                reason = "This server can't change a queued prompt's attachments. Update Tab on it, then restart it."
            } else if let prompt {
                reason = prompt.state == .delivering ? "The prompt started sending before the edit arrived."
                    : prompt.revision != edit.baseRevision ? "The prompt changed elsewhere before the edit arrived."
                    : error.localizedDescription
            } else {
                reason = "The prompt was sent or removed before the edit arrived."
            }
            await self.recoverQueuedEdit(AgentQueuedEditRecovery(edit: edit, latest: prompt, reason: reason))
        }
    }

    /// Settles retained edits against an authoritative queue: one the server shows is
    /// saved, as when a save's reply was lost to a reconnect.
    func reconcileQueueEdits(_ result: AgentChatSnapshot) {
        guard commandTask == nil, !composerWork.queueEdits.isEmpty else { return }
        for (id, edit) in composerWork.queueEdits {
            guard let prompt = result.queuedPrompts?.first(where: { $0.id == id }), edit.isApplied(in: prompt) else { continue }
            composerWork.queueEdits[id] = nil
            showNotice("The queued prompt's edit was saved.", kind: .info)
        }
    }

    private func recoverQueuedEdit(_ recovery: AgentQueuedEditRecovery) async {
        let ask = composerWork.chooseQueueEditRecovery ?? { [weak self] in await self?.presentQueueEditRecovery($0) ?? .keep }
        let choice = await ask(recovery)
        guard !disposed else { return }
        let edit = recovery.edit
        switch choice {
        case .editAgain:
            // The queue as just read, which the pane's snapshot may not show yet.
            refresh()
            guard let latest = recovery.latest, recovery.canEditAgain else {
                showComposerError("That prompt is no longer queued. Copy or stash your edit instead.")
                return
            }
            editQueued(latest)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(edit.text, forType: .string)
            composerWork.queueEdits[edit.promptID] = nil
            showNotice("Copied your edit. The composer's draft is unchanged.", kind: .info)
        case .stash:
            await stashQueuedEdit(edit)
        case .discard:
            composerWork.queueEdits[edit.promptID] = nil
        case .keep:
            if recovery.latest == nil { composerWork.queueEdits[edit.promptID] = nil }
            showNotice(recovery.reason + (recovery.latest == nil ? "" : " Your edit is kept; open the prompt's editor to finish it."), kind: .warning)
        }
        updateControls()
    }

    /// Puts an unsaved edit in this conversation's stash, with its new attachments; the
    /// server's own attachments stay with the queued prompt.
    private func stashQueuedEdit(_ edit: AgentQueuedPromptEdit) async {
        guard let stash = composerWork.stash else { showComposerError("Stashing is unavailable in this pane."); return }
        let added: [AgentChatAttachment] = edit.attachments.compactMap {
            guard case .added(let draft) = $0 else { return nil }
            return AgentChatAttachment(id: draft.id, name: draft.name, mimeType: draft.mimeType, data: draft.data)
        }
        let draft = AgentSavedDraft(text: NSAttributedString(string: edit.text), attachments: [], submission: nil, answers: [:])
        do {
            _ = try await stash.stash(AgentSavedDraft(copying: draft, attachments: added),
                                      settings: .init(provider: selection.provider.rawValue, model: selection.model,
                                                      effort: reasoningEffort, planMode: snapshot?.planMode == true))
            composerWork.queueEdits[edit.promptID] = nil
            showNotice("Stashed your edit. Restore it with /stashes; the composer's draft is unchanged.", kind: .info)
        } catch {
            showComposerError("Couldn't stash the edit: " + error.localizedDescription)
        }
    }

    private func presentQueueEditRecovery(_ recovery: AgentQueuedEditRecovery) async -> AgentQueuedEditRecovery.Choice {
        guard let window = surface.window else { return .keep }
        let alert = NSAlert()
        alert.window.appearance = surface.theme.nsAppearance
        alert.messageText = "Your edit wasn't saved"
        alert.informativeText = recovery.reason + " The prompt keeps its latest version and isn't sent again; your draft in the message box is unchanged."
        var choices: [AgentQueuedEditRecovery.Choice] = []
        if recovery.canEditAgain { alert.addButton(withTitle: "Edit Again"); choices.append(.editAgain) }
        alert.addButton(withTitle: "Copy Edit"); choices.append(.copy)
        alert.addButton(withTitle: "Stash Edit"); choices.append(.stash)
        alert.addButton(withTitle: recovery.latest == nil ? "Discard Edit" : "Later"); choices.append(recovery.latest == nil ? .discard : .keep)
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : .keep
    }

    private func presentQueuedEditorSheet(_ edit: AgentQueuedPromptEdit) async -> AgentQueuedPromptEdit? {
        guard let window = surface.window else { return nil }
        let promptID = edit.promptID
        let fetch = surface.fetchAttachment
        let editor = AgentQueuedPromptEditor(edit: edit, theme: surface.theme, needsReview: snapshot?.queuedPrompts?
            .first { $0.id == promptID }.map { $0.state == .uncertain || $0.state == .failed } ?? false) { descriptor in
            guard let fetch else { throw ModelError("This server can't show a queued prompt's attachments.") }
            return try await fetch(promptID, descriptor)
        }
        composerWork.queueEditor = editor
        defer { if composerWork.queueEditor === editor { composerWork.queueEditor = nil } }
        return await editor.present(in: window)
    }
}

/// The queued prompt's editor: its text, its attachments to preview, remove, replace or
/// add to, and whether to use the composer's current settings. Cancelling changes nothing.
@MainActor
final class AgentQueuedPromptEditor: NSObject {
    private let alert = NSAlert()
    private let text = NSTextView()
    private let strip = AgentAttachmentStrip(frame: .zero)
    private let addFiles = NSButton(title: "Add Files…", target: nil, action: nil)
    private let settings = NSButton(checkboxWithTitle: "Use current model, reasoning effort and plan mode", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let theme: AppTheme
    private let fetch: (AgentChatAttachmentDescriptor) async throws -> Data
    private var edit: AgentQueuedPromptEdit
    private var preview: NSPopover?
    private var importTask: Task<Void, Never>?

    init(edit: AgentQueuedPromptEdit, theme: AppTheme, needsReview: Bool,
         fetch: @escaping (AgentChatAttachmentDescriptor) async throws -> Data) {
        self.edit = edit
        self.theme = theme
        self.fetch = fetch
        super.init()
        alert.messageText = "Edit queued prompt"
        alert.informativeText = needsReview
            ? "The earlier delivery may have reached the agent. Saving does not send it again."
            : "Saving does not send it immediately."
        if !edit.lostAttachments.isEmpty {
            alert.informativeText += " Removed elsewhere since you began: " + edit.lostAttachments.joined(separator: ", ") + "."
        }
        alert.window.appearance = theme.nsAppearance
        let width: CGFloat = 460
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 330))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 136, width: width, height: 194))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        text.isRichText = false
        text.font = AppFont.body
        text.textColor = theme.fg
        text.backgroundColor = theme.card
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.frame = NSRect(x: 0, y: 0, width: width - 2, height: 192)
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.string = edit.text
        text.setAccessibilityLabel("Queued prompt")
        scroll.documentView = text
        strip.frame = NSRect(x: 0, y: 56, width: width, height: 76)
        strip.onRemove = { [weak self] id in self?.edit.remove(id); self?.refresh() }
        strip.onPreview = { [weak self] id in self?.showPreview(id) }
        strip.onReplace = { [weak self] id in self?.chooseFiles(replacing: id) }
        addFiles.frame = NSRect(x: 0, y: 28, width: 120, height: 26)
        addFiles.bezelStyle = .rounded
        addFiles.target = self
        addFiles.action = #selector(addPressed)
        message.frame = NSRect(x: 128, y: 28, width: width - 128, height: 26)
        message.font = AppFont.small
        message.textColor = theme.warning
        settings.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        for view in [scroll, strip, addFiles, message, settings] as [NSView] { content.addSubview(view) }
        alert.accessoryView = content
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        refresh()
    }

    func present(in window: NSWindow) async -> AgentQueuedPromptEdit? {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { [self] response in
                importTask?.cancel()
                preview?.close()
                guard response == .alertFirstButtonReturn else { return continuation.resume(returning: nil) }
                edit.text = text.string
                edit.useCurrentSettings = settings.state == .on
                continuation.resume(returning: edit)
            }
            alert.window.makeFirstResponder(text)
        }
    }

    func close() {
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
    }

    private func refresh() {
        strip.update(edit.attachments.map(\.draft), theme: theme)
        strip.isHidden = edit.attachments.isEmpty
        message.stringValue = ""
    }

    @objc private func addPressed() { chooseFiles(replacing: nil) }

    private func chooseFiles(replacing: String?) {
        let panel = NSOpenPanel()
        panel.title = replacing == nil ? "Attach files" : "Replace attachment"
        panel.prompt = replacing == nil ? "Attach" : "Replace"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = replacing == nil
        panel.beginSheetModal(for: alert.window) { [weak self] response in
            guard response == .OK, let self else { return }
            let urls = panel.urls
            self.importTask?.cancel()
            self.message.stringValue = "Preparing attachments…"
            self.addFiles.isEnabled = false
            self.importTask = Task { [weak self] in
                do {
                    let loaded = try await AgentAttachmentImporter.load(urls: urls)
                    guard let self, !Task.isCancelled else { return }
                    self.addFiles.isEnabled = true
                    if let error = self.edit.add(loaded, replacing: replacing) { self.message.stringValue = error } else { self.refresh() }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.addFiles.isEnabled = true
                    self.message.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func showPreview(_ id: String) {
        guard let attachment = edit.attachments.first(where: { $0.id == id }) else { return }
        let content = NSViewController()
        let background = ThemedBackground(color: { $0.floating })
        background.theme = theme
        background.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        content.view = background
        let draft = attachment.draft
        let image = NSImageView(frame: NSRect(x: 12, y: 12, width: 396, height: 276))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityLabel(draft.name)
        let label = NSTextField(wrappingLabelWithString: draft.name + "\nLoading…")
        label.frame = NSRect(x: 12, y: 12, width: 396, height: 276)
        label.textColor = theme.fg
        background.addSubview(image)
        background.addSubview(label)
        preview?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        preview = popover
        popover.show(relativeTo: strip.bounds, of: strip, preferredEdge: .minY)
        let fetch = self.fetch
        Task { [weak image, weak label] in
            do {
                let data: Data
                switch attachment {
                case .existing(let descriptor): data = try await fetch(descriptor)
                case .added(let added): data = added.data
                }
                if draft.mimeType.hasPrefix("image/"), let shown = await AgentAttachmentImporter.previewImage(data: data) {
                    image?.image = shown
                    label?.isHidden = true
                } else if let source = String(data: data.prefix(32_000), encoding: .utf8) {
                    label?.stringValue = source
                } else {
                    label?.stringValue = draft.name + "\n" + ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                }
            } catch {
                label?.stringValue = draft.name + "\nPreview unavailable: " + error.localizedDescription
            }
        }
    }
}
