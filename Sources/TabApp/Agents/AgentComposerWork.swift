import AppKit
import TabCore
import TabProtocol

/// Composer work that outlives a keystroke: attachment imports tied to the draft they
/// started in, stashed drafts, queued-prompt edits awaiting the server, and Send Now.
@MainActor
final class AgentComposerWork {
    /// Changes whenever the draft is cleared, replaced or disposed. An import finishing
    /// for an older draft is dropped, so it never lands in the one typed since.
    var draftGeneration: UInt64 = 0
    var imports: [UUID: Task<Void, Never>] = [:]
    /// The import making optimized copies of images, which Dismiss cancels.
    var optimization: UUID?
    /// Asks whether to attach optimized copies; nil asks with a sheet.
    var confirmImageOptimization: (([AgentOversizedImage]) async -> Bool)?

    var stash: AgentDraftStash?
    var stashPicker: AgentSearchPicker?
    var stashTask: Task<Void, Never>?
    /// Asks how to restore a stash into a draft that isn't empty; nil asks with a sheet.
    var chooseStashRestore: ((AgentStashedDraft) async -> AgentStashRestoreChoice)?

    /// Queued-prompt edits the server has not acknowledged, by prompt ID. An edit leaves
    /// only once saved, or when the user copies, stashes or discards it.
    var queueEdits: [String: AgentQueuedPromptEdit] = [:]
    var queueEditorOpen = false
    var queueEditor: AgentQueuedPromptEditor?
    /// Shows the queued-prompt editor; nil presents the sheet.
    var presentQueuedEditor: ((AgentQueuedPromptEdit) async -> AgentQueuedPromptEdit?)?
    /// Asks what to do with an edit the server didn't take; nil asks with a sheet.
    var chooseQueueEditRecovery: ((AgentQueuedEditRecovery) async -> AgentQueuedEditRecovery.Choice)?

    /// A Send Now waiting for its outcome: the queued prompt it asked to steer, and why
    /// the server refused to, if it did.
    var sendNow: (id: String, failure: String?)?

    func dispose() {
        for task in imports.values { task.cancel() }
        imports.removeAll()
        stashTask?.cancel()
        stashPicker?.close()
        queueEditor?.close()
    }
}

enum AgentStashRestoreChoice: Equatable { case merge, replace, cancel }

extension AgentPaneController {
    // MARK: Attachment intake

    /// A paste this long goes in as a text file, so the draft stays readable and editable.
    static let longPasteCharacters = 10_000
    static let longPasteLines = 200
    /// The most text a message carries, as the server checks it.
    nonisolated static let maximumPromptBytes = 64 * 1024

    /// Takes a long paste as a text attachment and says so only once it is in the draft.
    /// When the draft's attachments are full it goes in as text instead, if the message
    /// can hold it, and otherwise nothing changes and the notice says why. True means the
    /// paste was handled here; false lets the text view insert it.
    func attachLongPaste(_ text: String) -> Bool {
        let lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        guard !disposed, text.count >= Self.longPasteCharacters || lines >= Self.longPasteLines else { return false }
        let data = Data(text.utf8)
        if draftAttachments.contains(where: { $0.mimeType == "text/plain" && $0.data == data }) {
            showNotice("This text is already attached.", kind: .info)
            return true
        }
        let attachment = AgentDraftAttachment(name: "Pasted text (\(lines) lines).txt", mimeType: "text/plain", data: data)
        if let reason = attachmentCapacityError(adding: [attachment]) {
            let composer = surface.composer
            let current = composer.string as NSString
            let selection = NSIntersectionRange(composer.selectedRange(), NSRange(location: 0, length: current.length))
            let resulting = current.length == 0 ? data.count
                : composer.string.utf8.count - current.substring(with: selection).utf8.count + data.count
            guard resulting <= Self.maximumPromptBytes else {
                showComposerError("The paste wasn't added: \(reason) It is also too long to put in the message, which holds \(Self.maximumPromptBytes / 1024) KB of text.")
                return true
            }
            showNotice("The paste went into the message as text: \(reason)", kind: .info)
            return false
        }
        addAttachments([attachment])
        if draftAttachments.contains(where: { $0.id == attachment.id }) {
            showNotice("The long paste was attached as a text file.", kind: .info)
        }
        return true
    }

    /// Why `additions` don't fit the draft's attachments, or nil when they do.
    func attachmentCapacityError(adding additions: [AgentDraftAttachment]) -> String? {
        if draftAttachments.count + additions.count > AgentChatAttachment.maxCount {
            return "a message holds at most \(AgentChatAttachment.maxCount) attachments."
        }
        let total = (draftAttachments + additions).reduce(0) { $0 + $1.data.count }
        if additions.contains(where: { $0.data.count > AgentChatAttachment.maxFileBytes }) || total > AgentChatAttachment.maxTotalBytes {
            return "a message's attachments total at most \(AgentChatAttachment.maxTotalBytes / 1024 / 1024) MB."
        }
        return nil
    }

    private func isCurrentDraft(_ generation: UInt64) -> Bool {
        !disposed && generation == composerWork.draftGeneration
    }

    /// Runs one import for the current draft, after those before it. Clearing,
    /// replacing or disposing the draft drops it, finished or not.
    @discardableResult
    func prepareAttachments(_ load: @escaping @Sendable () async throws -> AgentAttachmentIntake) -> UUID {
        let generation = composerWork.draftGeneration
        let previous = attachmentTask
        let id = UUID()
        preparingAttachments += 1
        updateControls()
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.finishImport(id, generation: generation) }
            do {
                try Task.checkCancellation()
                guard self.isCurrentDraft(generation) else { return }
                let intake = try await load()
                try Task.checkCancellation()
                guard self.isCurrentDraft(generation) else { return }
                if !intake.attachments.isEmpty { self.addAttachments(intake.attachments) }
                if !intake.oversizedImages.isEmpty { self.offerOptimizedCopies(intake.oversizedImages) }
            } catch is CancellationError {
            } catch {
                if self.isCurrentDraft(generation) { self.showComposerError(error.localizedDescription) }
            }
        }
        composerWork.imports[id] = task
        attachmentTask = task
        return id
    }

    private func finishImport(_ id: UUID, generation: UInt64) {
        composerWork.imports[id] = nil
        if composerWork.optimization == id { composerWork.optimization = nil }
        // An invalidated draft's imports were already uncounted.
        guard generation == composerWork.draftGeneration else { return }
        preparingAttachments = max(0, preparingAttachments - 1)
        if preparingAttachments == 0 { attachmentTask = nil }
        if !disposed { updateControls() }
    }

    /// Ends every import of the current draft, queued or running; none of them can add
    /// to the draft that follows.
    func invalidateDraftImports() {
        composerWork.draftGeneration &+= 1
        for task in composerWork.imports.values { task.cancel() }
        composerWork.imports.removeAll()
        composerWork.optimization = nil
        preparingAttachments = 0
        attachmentTask = nil
        if notice?.kind == .progress { dismissNotice() }
        if !disposed { updateControls() }
    }

    /// Asks whether to attach optimized copies of images over the size limit, then makes them.
    func offerOptimizedCopies(_ images: [AgentOversizedImage]) {
        let generation = composerWork.draftGeneration
        Task { [weak self] in
            guard let self else { return }
            let ask = self.composerWork.confirmImageOptimization ?? { [weak self] in await self?.presentImageOptimization($0) ?? false }
            guard await ask(images), self.isCurrentDraft(generation) else { return }
            let used = self.draftAttachments.reduce(0) { $0 + $1.data.count }
            let budget = min(AgentChatAttachment.maxFileBytes, AgentChatAttachment.maxTotalBytes - used)
            let names = images.map(\.name).joined(separator: ", ")
            self.showNotice("Optimizing \(names)… Dismiss to cancel.", kind: .progress)
            self.composerWork.optimization = self.prepareAttachments {
                let worker = Task.detached(priority: .userInitiated) { () throws -> AgentAttachmentIntake in
                    var remaining = budget
                    var copies: [AgentDraftAttachment] = []
                    for image in images {
                        let copy = try AgentImageOptimizer.optimize(image, budget: remaining)
                        remaining -= copy.data.count
                        copies.append(copy)
                    }
                    return AgentAttachmentIntake(attachments: copies)
                }
                return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            }
        }
    }

    private func presentImageOptimization(_ images: [AgentOversizedImage]) async -> Bool {
        guard let window = surface.window else { return false }
        let alert = NSAlert()
        alert.window.appearance = surface.theme.nsAppearance
        let size = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        let limit = size(AgentChatAttachment.maxFileBytes)
        alert.messageText = images.count == 1 ? "Attach an optimized copy?" : "Attach optimized copies?"
        alert.informativeText = images.map { "\($0.name) is \(size($0.byteCount))." }.joined(separator: "\n")
            + "\n\nAttachments are limited to \(limit). Tab can resize and recompress a copy on this Mac; the original stays unchanged."
        alert.addButton(withTitle: images.count == 1 ? "Attach Optimized Copy" : "Attach Optimized Copies")
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    /// The notice's close button; for an optimization in progress it also cancels it.
    func dismissNoticePressed() {
        if notice?.kind == .progress, let id = composerWork.optimization {
            composerWork.imports[id]?.cancel()
            composerWork.optimization = nil
        }
        dismissNotice()
    }

    // MARK: Send Now

    /// Why Send Now can't steer the draft into the running turn, or nil when it can.
    var sendNowUnavailableReason: String? {
        guard created, !needsAuthoritativeSnapshot, let snapshot else { return "Wait for the conversation to reconnect." }
        if composerWork.sendNow != nil { return "The previous prompt is still being sent." }
        switch snapshot.status {
        case .working: break
        case .waiting: return "The agent is waiting for an answer, so prompts queue until it continues."
        default: return "Nothing is running, so Send sends right away."
        }
        if let command = AgentSlashCommand(text: surface.composer.string), !command.isPath {
            return "Commands run after active and queued work finishes."
        }
        guard selection.provider == snapshot.provider, selection.model == snapshot.model,
              reasoningEffort == snapshot.reasoningEffort else {
            return "Model and reasoning changes apply after the current response, so this prompt can only be queued."
        }
        return nil
    }

    /// Steers the draft into the running turn when the provider can take it now; otherwise
    /// it queues as Send would and the notice says what happened. Either way the prompt
    /// keeps one queue identity, so it reaches the agent at most once.
    func sendNow() {
        guard !disposed, canSendDraft else { return }
        switch snapshot?.status {
        case .working?:
            if let reason = sendNowUnavailableReason { showComposerError(reason); return }
            send(now: true)
        case .waiting?:
            // It can only queue; the reply's notice says so.
            send(now: true)
        default:
            send()
        }
    }

    /// The Send Now shortcut, while the composer has the keyboard; false lets the key go on.
    func performSendNowShortcut() -> Bool {
        guard surface.composerHasFocus, !surface.composer.hasMarkedText(), canSendDraft,
              snapshot?.status == .working || snapshot?.status == .waiting else { return false }
        sendNow()
        return true
    }

    /// After the server queued a Send Now prompt: the request that steers it, or nil when
    /// the server already started it or it has to wait, which the notice says.
    func sendNowRequest(_ id: String, after result: AgentChatSnapshot) -> AgentChatRequest? {
        guard let queued = result.queuedPrompts?.first(where: { $0.id == id }), queued.state != .delivering else {
            showNotice("The turn had ended, so the prompt was sent as the next message.", kind: .info)
            return nil
        }
        guard queued.state == .queued, result.status == .working else {
            showNotice(result.status == .waiting ? "Queued. The agent is waiting for an answer, so the prompt goes when it continues."
                : "Queued. It is sent when the current work finishes.", kind: .info)
            return nil
        }
        composerWork.sendNow = (id, nil)
        return .deliverQueued(session: session, id: id, expectedRevision: queued.revision)
    }

    func sendNowDispatched(_ id: String, _ outcome: Result<AgentChatSnapshot, Error>) {
        guard composerWork.sendNow?.id == id else { return }
        if case .failure(let error) = outcome {
            composerWork.sendNow = (id, error.localizedDescription)
            // Its turn may have ended meanwhile, and the queue sent it anyway.
            refresh()
        } else {
            // Its reply arrived inside the request; settle once the pane is free again.
            Task { [weak self] in
                guard let self, let snapshot = self.snapshot else { return }
                self.resolveSendNow(snapshot)
                self.updateControls()
            }
        }
        updateControls()
    }

    private func resolveSendNow(_ result: AgentChatSnapshot) {
        guard let tracked = composerWork.sendNow, commandTask == nil else { return }
        let queued = result.queuedPrompts?.first { $0.id == tracked.id }
        switch queued?.state {
        case nil:
            composerWork.sendNow = nil
            showNotice(tracked.failure == nil ? "Sent." : "The turn had ended, so the prompt was sent as the next message.", kind: .info)
        case .delivering?:
            return
        case .queued?:
            composerWork.sendNow = nil
            let reason = tracked.failure.map { ": " + $0 } ?? ": the turn ended before it arrived."
            showNotice("Couldn't send it now\(reason) It stays queued.", kind: .warning)
        case .uncertain?, .failed?:
            composerWork.sendNow = nil
            showNotice("Delivery may not have finished. Review the prompt in the queue before sending it again.", kind: .warning)
        }
    }

    /// Every accepted snapshot: settles Send Now and queued-prompt edits it answers.
    func composerWorkAccepted(_ result: AgentChatSnapshot) {
        resolveSendNow(result)
        reconcileQueueEdits(result)
    }

    func updateComposerWorkControls() {
        // Send is the one action while there is a draft; while the agent works its
        // tooltip names the Send Now shortcut when the draft could steer the turn.
        let working = snapshot?.status == .working || snapshot?.status == .waiting
        guard working, sendNowUnavailableReason == nil, let key = keyDisplay?(.sendAgentPromptNow) else { return }
        surface.send.toolTip = "Queue this prompt for the next response · \(key) adds it to the running turn now"
    }

    // MARK: Stashed drafts

    /// Items the composer's context menu adds: stashing the draft and restoring one.
    func composerMenuItems() -> [NSMenuItem] {
        guard composerWork.stash != nil, !disposed else { return [] }
        let stash = ClosureMenuItem("Stash Draft", enabled: !restoringDraft && !captureDraft().isEmpty) { [weak self] in self?.stashDraft() }
        let restore = ClosureMenuItem("Restore Stashed Draft…", enabled: !restoringDraft) { [weak self] in self?.showStashedDrafts() }
        return [stash, restore]
    }

    private var stashSettings: AgentStashedDraft.Settings {
        .init(provider: selection.provider.rawValue, model: selection.model, effort: reasoningEffort, planMode: snapshot?.planMode == true)
    }

    /// Sets the draft aside in this conversation's stash and starts an empty one.
    func stashDraft(completion: (() -> Void)? = nil) {
        guard !disposed, !restoringDraft, let stash = composerWork.stash else { return }
        guard preparingAttachments == 0 else { showComposerError("Wait for attachments to finish preparing, then stash the draft."); return }
        let draft = captureDraft()
        guard !draft.isEmpty else { showNotice("There is no draft to stash.", kind: .info); return }
        let shown = NSAttributedString(attributedString: surface.composer.attributedString())
        let settings = stashSettings
        composerWork.stashTask = Task { [weak self] in
            do {
                _ = try await stash.stash(draft, settings: settings)
                guard let self, !self.disposed else { return }
                // Edits typed while it saved stay in the draft.
                if self.surface.composer.attributedString().isEqual(to: shown) { self.surface.composer.string = "" }
                self.invalidateDraftImports()
                self.draftAttachments.removeAll { attachment in draft.attachments.contains { $0.id == attachment.id } }
                self.reviewComments.removeAll { comment in draft.reviewComments?.contains(comment) == true }
                self.refreshReviewComments()
                self.lastSubmission = nil
                self.updateAttachments()
                self.surface.refreshComposer()
                self.showNotice("Draft stashed. Restore it with /stashes or from the message box's menu.", kind: .info)
            } catch {
                self?.showComposerError("Couldn't stash the draft: " + error.localizedDescription)
            }
            completion?()
        }
    }

    /// Lists this conversation's stashed drafts; choosing one restores it.
    func showStashedDrafts() {
        guard !disposed, let stash = composerWork.stash else { return }
        Task { [weak self] in
            do {
                let entries = try await stash.list()
                guard let self, !self.disposed else { return }
                guard !entries.isEmpty else { self.showNotice("No stashed drafts in this conversation.", kind: .info); return }
                self.composerWork.stashPicker?.close()
                let picker = AgentSearchPicker(title: "Stashed drafts", placeholder: "Search stashed drafts…", theme: self.surface.theme)
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                picker.update(entries.reversed().map { entry in
                    let files = entry.attachments.isEmpty ? "" : " · \(entry.attachments.count) attachment\(entry.attachments.count == 1 ? "" : "s")"
                    return .init(id: entry.id, title: entry.title, detail: formatter.localizedString(for: entry.savedAt, relativeTo: Date()) + files)
                }, note: "Restoring adds a stashed draft to an empty message, or asks whether to merge or replace.")
                picker.onSelect = { [weak self] id in self?.restoreStash(id) }
                picker.onClose = { [weak self] in self?.composerWork.stashPicker = nil }
                self.composerWork.stashPicker = picker
                picker.present(in: self.surface.window)
            } catch {
                self?.showComposerError("Couldn't read stashed drafts: " + error.localizedDescription)
            }
        }
    }

    /// Restores a stashed draft: straight into an empty draft, otherwise merged or in
    /// place of it as the user chooses, the replaced draft going to the stash. Nothing is
    /// sent, and both drafts are kept until the choice is made.
    func restoreStash(_ id: String, completion: (() -> Void)? = nil) {
        guard !disposed, let stash = composerWork.stash else { return }
        composerWork.stashTask = Task { [weak self] in
            defer { completion?() }
            guard let self else { return }
            do {
                let restored = try await stash.read(id)
                guard !self.disposed, !self.restoringDraft else { return }
                var choice = AgentStashRestoreChoice.replace
                if !self.captureDraft().isEmpty || self.preparingAttachments > 0 {
                    let ask = self.composerWork.chooseStashRestore ?? { [weak self] in await self?.presentStashRestoreChoice($0) ?? .cancel }
                    choice = await ask(restored.entry)
                    guard choice != .cancel, !self.disposed else { return }
                }
                if choice == .replace, !self.captureDraft().isEmpty {
                    _ = try await stash.stash(self.captureDraft(), settings: self.stashSettings)
                }
                guard !self.disposed else { return }
                try self.apply(restored, merge: choice == .merge)
                try await stash.remove(id)
            } catch {
                self.showComposerError("Couldn't restore the stashed draft: " + error.localizedDescription)
            }
        }
    }

    private func apply(_ restored: AgentRestoredStash, merge: Bool) throws {
        let entry = restored.entry
        let incoming = restored.attachments.map {
            AgentDraftAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, data: $0.data)
        }
        let kept = merge ? draftAttachments : []
        let additions = incoming.filter { candidate in !kept.contains { $0.id == candidate.id || ($0.name == candidate.name && $0.data == candidate.data) } }
        guard kept.count + additions.count <= AgentChatAttachment.maxCount,
              (kept + additions).reduce(0, { $0 + $1.data.count }) <= AgentChatAttachment.maxTotalBytes else {
            throw ModelError("Together the drafts have too many attachments. Remove some from the message, then restore again.")
        }
        let text = entry.draft.attributed(theme: surface.theme)
        if !merge { invalidateDraftImports() }
        let storage = surface.composer.textStorage
        if merge, let storage, !storage.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let separator = NSAttributedString(string: "\n\n", attributes: [.font: AppFont.system(14, weight: .light), .foregroundColor: surface.theme.fg])
            storage.append(separator)
            storage.append(text)
        } else {
            storage?.setAttributedString(text)
        }
        draftAttachments = kept + additions
        let comments = entry.draft.reviewComments ?? []
        reviewComments = merge ? reviewComments + comments.filter { comment in !reviewComments.contains { $0.id == comment.id } } : comments
        refreshReviewComments()
        lastSubmission = nil
        restoreSettings(entry.settings)
        // Thumbnails come after: the draft is whole without them.
        for attachment in additions where attachment.mimeType.hasPrefix("image/") {
            let id = attachment.id, data = attachment.data
            Task { [weak self] in
                guard let thumbnail = await AgentAttachmentImporter.previewImage(data: data, pixels: 160),
                      let self, let index = self.draftAttachments.firstIndex(where: { $0.id == id }) else { return }
                let current = self.draftAttachments[index]
                self.draftAttachments[index] = AgentDraftAttachment(id: current.id, name: current.name, mimeType: current.mimeType,
                                                                    data: current.data, thumbnail: thumbnail)
                self.updateAttachments()
            }
        }
        updateAttachments()
        surface.refreshComposer()
        saveDraft(immediate: true)
        var notes: [String] = []
        if !restored.unavailable.isEmpty {
            notes.append("Unavailable and not restored: " + restored.unavailable.map(\.name).joined(separator: ", ") + ".")
        }
        if let settings = entry.settings, settings.planMode != (snapshot?.planMode == true) {
            notes.append("It was written with plan mode \(settings.planMode ? "on" : "off").")
        }
        showNotice(([merge ? "Stashed draft merged into the message." : "Stashed draft restored."] + notes).joined(separator: " "),
                   kind: restored.unavailable.isEmpty ? .info : .warning)
        focusContent()
    }

    /// Model and effort come back with the draft when this conversation can still use them.
    private func restoreSettings(_ settings: AgentStashedDraft.Settings?) {
        guard let settings, settings.provider == selection.provider.rawValue, canEditSelection else { return }
        if settings.model != selection.model { selectModel(provider: selection.provider, model: settings.model) }
        if settings.effort != reasoningEffort { selectEffort(settings.effort) }
    }

    private func presentStashRestoreChoice(_ entry: AgentStashedDraft) async -> AgentStashRestoreChoice {
        guard let window = surface.window else { return .cancel }
        let alert = NSAlert()
        alert.window.appearance = surface.theme.nsAppearance
        alert.messageText = "Restore “\(entry.title)”?"
        alert.informativeText = "The message box already has a draft. Merge adds the stashed draft after it; Replace stashes the current draft first."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        switch response {
        case .alertFirstButtonReturn: return .merge
        case .alertSecondButtonReturn: return .replace
        default: return .cancel
        }
    }
}
