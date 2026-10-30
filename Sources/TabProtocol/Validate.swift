import Foundation

// Request and reply validation: what a well-behaved peer never sends. The
// server checks every request before acting on it; clients check replies.

/// Rules shared by several messages.
public enum Validation {
    public static func size(_ size: Size) throws(ErrorCode) {
        guard (1 ... Limits.maxCols).contains(size.cols), (1 ... Limits.maxRows).contains(size.rows) else {
            throw .badSize
        }
    }

    public static func cellSize(_ cell: CellSize) throws(ErrorCode) {
        guard (1 ... 4096).contains(cell.width), (1 ... 4096).contains(cell.height) else { throw .badSize }
    }

    public static func input(_ bytes: Data) throws(ErrorCode) {
        if bytes.count > Limits.maxInput { throw .badRequest }
    }

    public static func search(query: String, maxResults: UInt16) throws(ErrorCode) {
        guard (1 ... Limits.maxSearchQuery).contains(query.utf8.count) else { throw .badRequest }
        try pageSize(maxResults)
    }

    public static func pageSize(_ rows: UInt16) throws(ErrorCode) {
        guard (1 ... Limits.maxHistoryPage).contains(Int(rows)) else { throw .badRequest }
    }

    public static func versions(_ versions: [ProtocolVersion]) throws(ErrorCode) {
        if versions.isEmpty { throw .badRequest }
    }

    /// At most 128 variables with names a process can hold, in 64 KiB together.
    public static func environment(_ environment: [String: String]) throws(ErrorCode) {
        guard environment.count <= Limits.maxEnvironmentVariables else { throw .badRequest }
        var total = 0
        for (key, value) in environment {
            if key.isEmpty || key.contains("=") || hasNul(key) || hasNul(value) { throw .badRequest }
            total += key.utf8.count + value.utf8.count
        }
        if total > Limits.maxEnvironmentBytes { throw .badRequest }
    }

    public static func deviceName(_ name: String) throws(ErrorCode) {
        if isBlank(name) || name.utf8.count > Limits.maxDeviceName || hasControl(name) { throw .badRequest }
    }

    /// DNS names and IPv4 addresses, without ports.
    public static func pairingHosts(_ hosts: [String]) throws(ErrorCode) {
        guard hosts.count <= Limits.maxPairingHosts else { throw .badRequest }
        for host in hosts {
            let valid = !host.isEmpty && host.utf8.count <= 253
                && host.utf8.allSatisfy { byte in
                    (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
                        || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
                }
            if !valid { throw .badRequest }
        }
    }

    /// `folders` names: one path component each, within listing limits.
    public static func folderNames(_ names: [ServerPath]) throws(ErrorCode) {
        guard names.count <= Limits.maxFileEntries,
              names.reduce(0, { $0 + $1.byteCount }) <= Limits.maxFilePathBytes else { throw .badRequest }
        for name in names { try name.validateComponent() }
    }

    static func hasNul(_ text: String) -> Bool { text.utf8.contains(0) }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    static func message(_ text: String, limit: Int) throws(ErrorCode) {
        if isBlank(text) || text.utf8.count > limit || hasNul(text) { throw .badRequest }
    }

    static func name(_ text: String) throws(ErrorCode) {
        if isBlank(text) || text.utf8.count > 1024 { throw .badRequest }
    }

    static func gitText(_ text: String) throws(ErrorCode) {
        if text.isEmpty || text.utf8.count > 1024 || hasNul(text) || text.hasPrefix("-") { throw .badRequest }
    }

    static func gitPath(_ path: ServerPath) throws(ErrorCode) {
        if path.rawValue.isEmpty || path.byteCount > Limits.maxPathBytes || path.containsNul { throw .badPath }
    }

    static func hash(_ hash: String) throws(ErrorCode) {
        let hex = hash.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (65 ... 70).contains(byte) || (97 ... 102).contains(byte)
        }
        if hash.isEmpty || hash.utf8.count > 64 || !hex { throw .badRequest }
    }

    static func number(_ number: UInt64) throws(ErrorCode) {
        if number == 0 { throw .badRequest }
    }

    static func lineLimit(_ limit: UInt32?) throws(ErrorCode) {
        if let limit, limit == 0 || limit > 100_000 { throw .badRequest }
    }

    static func prompts(_ rows: [UInt16], count: Int) throws(ErrorCode) {
        if rows.count > count { throw .badRequest }
        for index in rows.indices.dropFirst() where rows[index - 1] >= rows[index] { throw .badRequest }
        if let last = rows.last, Int(last) >= count { throw .badRequest }
    }

    static func links(_ rows: [LinkRow]) throws(ErrorCode) {
        guard rows.count <= Int(Limits.maxRows),
              rows.reduce(0, { $0 + $1.spans.count }) <= Limits.maxLinkSpans else { throw .badRequest }
        for index in rows.indices.dropFirst() where rows[index - 1].row >= rows[index].row { throw .badRequest }
        for row in rows {
            if row.row >= Limits.maxRows || row.spans.isEmpty { throw .badRequest }
            for index in row.spans.indices.dropFirst() where row.spans[index - 1].end > row.spans[index].start {
                throw .badRequest
            }
            for span in row.spans {
                if span.start >= span.end || span.end > Limits.maxCols || span.uri.isEmpty
                    || span.uri.utf8.count > Limits.maxLinkURI || hasControl(span.uri) {
                    throw .badRequest
                }
            }
        }
    }

    static func historyRows(_ rows: [Row], next: HistoryCursor?, total: UInt64, limit: Int) throws(ErrorCode) {
        if rows.count > limit || UInt64(rows.count) > total || next == HistoryCursor(0)
            || (rows.isEmpty && next != nil) {
            throw .badRequest
        }
        for (index, row) in rows.enumerated() {
            if Int(row.index) != index || row.runs.contains(where: { $0.width == 0 })
                || row.runs.reduce(0, { $0 + Int($1.width) }) > Int(Limits.maxCols) {
                throw .badRequest
            }
        }
    }
}

// MARK: - Control channel

extension Message {
    public func validate() throws(ErrorCode) {
        switch self {
        case .request(_, let body): try body.validate()
        case .reply(_, let body): try body.validate()
        case .event(let body): try body.validate()
        case .unknown: break
        }
    }
}

extension RequestBody {
    public func validate() throws(ErrorCode) {
        switch self {
        case .agentChat(let request):
            try request.validate()
        case .agentComposerContext:
            break
        case .hello(let hello):
            try Validation.versions(hello.versions)
        case .clearScreen(let channel), .detach(let channel):
            if channel.isControl { throw .unknownChannel }
        case .writeInput(_, let bytes):
            try Validation.input(bytes)
        case .acknowledgeActivity(let ids), .claimActivity(let ids):
            if ids.count > Limits.activityHistoryLimit { throw .badRequest }
        case .git(let request):
            try request.validate()
        case .files(let request):
            try request.validate()
        case .listFolders(let path):
            try path.validateAbsolute()
        case .upload(let chunk):
            try chunk.validate()
        case .exec(let request):
            try request.validate()
        case .syncSessionReferences(_, _, let sessions):
            if sessions.count > Limits.maxSessionReferences { throw .badRequest }
        case .mutateProject(let intent):
            try intent.mutation.validate()
        case .writeServerSettings(let settings):
            try settings.validate()
        case .searchHistory(let source, let query, _, _, let maxResults):
            if source == .live(.control) { throw .unknownChannel }
            try Validation.search(query: query, maxResults: maxResults)
        case .createSession(let request):
            try request.validate()
        case .attach(_, let size):
            try Validation.size(size)
        case .historyPage(let channel, _, let maxRows):
            if channel.isControl { throw .unknownChannel }
            try Validation.pageSize(maxRows)
        case .savedHistoryPage(_, _, let maxRows):
            try Validation.pageSize(maxRows)
        case .setTerminalColors(let colors):
            try colors.validate()
        case .pair(let request):
            try Validation.deviceName(request.name)
            if request.code.count != 16 { throw .badRequest }
        case .authenticate(let credential):
            if credential.token.count != 32 { throw .badRequest }
        case .writeRemoteAccess(let settings):
            try settings.validate()
        case .startPairing(let hosts):
            try Validation.pairingHosts(hosts)
        case .ping, .listSessions, .attachWithoutResize, .endSession, .closeSession, .discardSession,
             .readSavedScreen, .identifyClient, .cancelCreation, .readCatalog, .listProjectSessions,
             .readServerSettings, .stopServer, .stopServerIfIdle, .restartServer, .cancelExec, .readActivity,
             .readRemoteAccess, .cancelPairing, .revokeDevice, .unknown:
            break
        }
    }
}

extension CreateSession {
    public func validate() throws(ErrorCode) {
        try directory.validate()
        try Validation.environment(environment)
        try Validation.size(size)
        if let command, command.utf8.count > 64 * 1024 || Validation.hasNul(command) { throw .badRequest }
    }
}

extension TerminalColors {
    public func validate() throws(ErrorCode) {
        if ansi.count != 16 || palette.keys.contains(where: { !(0 ... 255).contains($0) }) { throw .badRequest }
    }
}

extension ServerSettingsDoc {
    public func validate() throws(ErrorCode) {
        if historyBudgetBytes > Limits.maxHistoryBudgetBytes { throw .badRequest }
        try defaultShell?.validateAbsolute()
    }
}

extension ReplyBody {
    public func validate() throws(ErrorCode) {
        switch self {
        case .agentChat(let snapshot):
            try snapshot.validate()
        case .agentComposerContext(let context):
            try context.validate()
        case .activityClaimed(let ids):
            if ids.count > Limits.activityHistoryLimit { throw .badRequest }
        case .activity(let snapshot):
            if snapshot.events.count > Limits.activityHistoryLimit || snapshot.agents.count > 16_384 {
                throw .badRequest
            }
        case .files(let reply):
            try reply.validate()
        case .folders(let names):
            try Validation.folderNames(names)
        case .uploaded(let path):
            try path?.validateAbsolute()
        case .exec(let result):
            try result.validate()
        case .catalog(let page):
            try page.validate()
        case .projectSessions(let page):
            try page.validate()
        case .serverSettings(let settings):
            try settings.validate()
        case .searchPage(let page):
            try page.validate()
        case .sessions(let sessions):
            for session in sessions { try session.directory.validate() }
        case .sessionCreated(let session):
            try session.directory.validate()
        case .attached(let snapshot, _):
            try snapshot.validate()
        case .historyPage(let page):
            try page.validate()
        case .savedScreen(let screen):
            try screen.validate()
        case .paired(let paired):
            try paired.validate()
        case .remoteAccess(let state):
            try state.validate()
        case .pairing(let offer):
            try offer.invite.validate()
        case .hello(let hello):
            try Validation.versions([hello.version])
        case .versionUnsupported, .pong, .error, .detached, .sessionEnded, .sessionClosed, .sessionDiscarded,
             .creationCancelled, .screenCleared, .terminalColorsSet, .sessionReferencesSynced, .clientIdentified,
             .inputWritten, .projectMutated, .serverSettingsWritten, .serverStopping, .serverBusy,
             .serverRestarting, .git, .execCancelled, .activityAcknowledged, .authenticated, .unknown:
            break
        }
    }
}

extension EventBody {
    public func validate() throws(ErrorCode) {
        switch self {
        case .filesChanged(_, let changes):
            try changes.validate()
        case .sessionMetadata(_, let metadata):
            try metadata.directory.validate()
        case .progress(_, let progress):
            if let percent = progress.progress?.percent, percent > 100 { throw .badRequest }
        case .changed, .agentChatChanged, .sessionEnded, .gitChanged, .serverRestarting, .fatal, .unknown:
            break
        }
    }
}

// MARK: - Session channel

extension SessionMessage {
    public func validate() throws(ErrorCode) {
        switch self {
        case .metadata(let event): try event.validate()
        case .resized(let size), .resize(let size): try Validation.size(size)
        case .input(let input): try input.validate()
        case .cellSize(let cell): try Validation.cellSize(cell)
        case .ended, .ack, .scroll, .requestHistory, .clear, .unknown: break
        }
    }
}

extension MetadataEvent {
    public func validate() throws(ErrorCode) {
        switch self {
        case .screenPrompts(_, let rows):
            try Validation.prompts(rows, count: Int(Limits.maxRows))
        case .links(_, let rows):
            try Validation.links(rows)
        case .directory(let path):
            try path.validate()
        case .clipboardWrite(let text):
            if text.isEmpty || text.utf8.count > Limits.maxClipboardText { throw .badRequest }
        case .title, .foregroundProcess, .bell, .history, .inputModes, .cursorBlinking, .unknown:
            break
        }
    }
}

extension TerminalInput {
    public func validate() throws(ErrorCode) {
        switch self {
        case .bytes(let bytes):
            try Validation.input(bytes)
        case .text(let text), .paste(let text):
            if text.utf8.count > Limits.maxInput { throw .badRequest }
        case .key(let event):
            try event.validate()
        case .mouse(let event):
            try event.validate()
        case .focus:
            break
        }
    }
}

extension KeyEvent {
    public func validate() throws(ErrorCode) {
        func printable(_ scalar: Unicode.Scalar) -> Bool {
            scalar.properties.generalCategory != .control && !(0xF700 ... 0xF8FF).contains(scalar.value)
        }
        if key.utf8.count > 32 || Validation.hasControl(key) || text.utf8.count > 4096
            || !text.unicodeScalars.allSatisfy(printable) {
            throw .badRequest
        }
        if unshiftedCodepoint != 0 {
            guard let scalar = Unicode.Scalar(unshiftedCodepoint), printable(scalar) else { throw .badRequest }
        }
    }
}

extension MouseEvent {
    public func validate() throws(ErrorCode) {
        let valid = switch action {
        case .press, .release: button != nil && scroll == nil
        case .motion: scroll == nil
        case .scroll: button == nil && scroll != nil
        }
        if !valid { throw .badRequest }
    }
}

// MARK: - Screens

extension ScreenFrame {
    public func validate() throws(ErrorCode) {
        try Validation.size(size)
        try graphics?.validate()
    }
}

extension Graphics {
    public func validate() throws(ErrorCode) {
        try Validation.cellSize(cell)
        guard images.count <= Limits.maxGraphicsPlacements, placements.count <= Limits.maxGraphicsPlacements else {
            throw .badRequest
        }
        var byId: [UInt32: GraphicImage] = [:]
        var total = 0
        for image in images {
            let (pixels, overflow) = UInt64(image.width).multipliedReportingOverflow(by: UInt64(image.height))
            total += image.rgba.count
            if overflow || pixels > UInt64(Int.max / 4) || image.width == 0 || image.height == 0
                || pixels * 4 != UInt64(image.rgba.count) || total > Limits.maxGraphicsBytes
                || byId.updateValue(image, forKey: image.id) != nil {
                throw .badRequest
            }
        }
        for placement in placements {
            guard let image = byId[placement.image] else { throw .badRequest }
            let source = placement.source
            let (right, rightOverflow) = source.x.addingReportingOverflow(source.width)
            let (bottom, bottomOverflow) = source.y.addingReportingOverflow(source.height)
            if source.width == 0 || source.height == 0 || placement.size.cols == 0 || placement.size.rows == 0
                || rightOverflow || bottomOverflow || right > image.width || bottom > image.height {
                throw .badRequest
            }
        }
    }
}

extension AttachSnapshot {
    public func validate() throws(ErrorCode) {
        try graphics?.validate()
        try Validation.size(size)
        try directory.validate()
        try Validation.historyRows(history, next: historyCursor, total: historyTotal, limit: Limits.maxAttachHistory)
        try Validation.prompts(prompts, count: history.count + Int(size.rows))
    }
}

extension HistoryPage {
    public func validate() throws(ErrorCode) {
        try Validation.historyRows(rows, next: next, total: totalRows, limit: Limits.maxHistoryPage)
        try screen?.validate()
        try Validation.prompts(prompts, count: rows.count + Int(screen?.size.rows ?? 0))
    }
}

extension SavedScreen {
    public func validate() throws(ErrorCode) {
        try graphics?.validate()
        try Validation.size(size)
        if rows.count != Int(size.rows) || cursor.row >= size.rows || cursor.col >= size.cols {
            throw .badRequest
        }
        for (index, row) in rows.enumerated() {
            if Int(row.index) != index || row.runs.contains(where: { $0.width == 0 })
                || row.runs.reduce(0, { $0 + Int($1.width) }) > Int(size.cols) {
                throw .badRequest
            }
        }
    }
}

extension SearchPage {
    /// Matches come newest first: strictly descending by row, then column.
    public func validate() throws(ErrorCode) {
        if matches.count > Limits.maxHistoryPage || scannedRows > Limits.maxSearchScannedRows
            || next == HistoryCursor(0) || (scannedRows == 0 && (!matches.isEmpty || next != nil)) {
            throw .badRequest
        }
        let rowLimit = totalRows.addingReportingOverflow(UInt64(Limits.maxRows))
        for found in matches {
            if found.start >= found.end || found.end > Limits.maxCols
                || (!rowLimit.overflow && found.row >= rowLimit.partialValue) {
                throw .badRequest
            }
        }
        for index in matches.indices.dropFirst() {
            let previous = matches[index - 1]
            let current = matches[index]
            if (previous.row, previous.start) <= (current.row, current.start) { throw .badRequest }
        }
    }
}

// MARK: - Catalog

extension ProjectDescriptor {
    public func validate() throws(ErrorCode) {
        try Validation.name(name)
        if !directory.isAbsolute || directory.byteCount > Limits.maxPathBytes || directory.containsNul
            || parentId == id || (kind == .worktree && parentId == nil) || (home && (kind != nil || parentId != nil)) {
            throw .badRequest
        }
    }
}

extension ProjectMutation {
    public func validate() throws(ErrorCode) {
        switch self {
        case .create(let project):
            if project.home { throw .badRequest }
            if let kind = project.kind, !kind.isKnown { throw .badRequest }
            try project.validate()
        case .rename(_, let name):
            try Validation.name(name)
        case .delete, .pruneWorktree, .setWorktreesVisible:
            break
        }
    }
}

extension CatalogPage {
    public func validate() throws(ErrorCode) {
        if projects.count > Limits.catalogPageSize { throw .badRequest }
        for index in projects.indices.dropFirst() where projects[index - 1].id >= projects[index].id {
            throw .badRequest
        }
        if let next, projects.last?.id != next { throw .badRequest }
        for project in projects {
            if project.home != (project.id == home) { throw .badRequest }
            try project.validate()
        }
    }
}

extension ProjectSessions {
    public func validate() throws(ErrorCode) {
        if sessions.count > Limits.catalogPageSize { throw .badRequest }
        for index in sessions.indices.dropFirst() where sessions[index - 1].info.id >= sessions[index].info.id {
            throw .badRequest
        }
        if let next, sessions.last?.info.id != next { throw .badRequest }
        for session in sessions { try session.info.directory.validate() }
    }
}

// MARK: - Git

extension GitRequest {
    public func validate() throws(ErrorCode) {
        switch action {
        case .switchBranch(let text), .createBranch(let text), .deleteBranch(let text), .deleteRemoteBranch(let text),
             .switchToBase(let text), .deleteLocalBranch(let text, _):
            try Validation.gitText(text)
        case .checkout(let hash), .cherryPick(let hash), .revert(let hash):
            try Validation.hash(hash)
        case .createTag(let name, let hash):
            try Validation.gitText(name)
            try Validation.hash(hash)
        case .commit(let message, _, let amend):
            if !(amend && message.isEmpty) { try Validation.message(message, limit: 64 * 1024) }
        case .log(let maxCount, _):
            if maxCount > 1000 { throw .badRequest }
        case .diff(let request):
            guard let path = request.path else { throw .badRequest }
            try Validation.lineLimit(request.lineLimit)
            try Validation.gitPath(path)
        case .rawDiff(let request):
            try Validation.lineLimit(request.lineLimit)
            if let path = request.path { try Validation.gitPath(path) }
        case .branchDiff(let base, let lineLimit):
            try Validation.gitText(base)
            try Validation.lineLimit(lineLimit)
        case .changesPreview(let lineLimit), .stagedPreview(let lineLimit):
            try Validation.lineLimit(lineLimit)
        case .commitAll(let message, let expectedHead, let expectedTree),
             .commitStaged(let message, let expectedHead, let expectedTree):
            try Validation.message(message, limit: 64 * 1024)
            if let expectedHead { try Validation.hash(expectedHead) }
            try Validation.hash(expectedTree)
        case .publishBranch(let branch, let destination):
            try Validation.gitText(branch)
            try Validation.gitText(destination.remote)
            try Validation.gitText(destination.branch)
        case .pullRequest(let action):
            try action.validate()
        case .stage(let paths), .unstage(let paths), .discard(let paths):
            if paths.count > 4096 { throw .badRequest }
            for path in paths { try Validation.gitPath(path) }
        case .worktree(let intent):
            try intent.validate()
        case .summary, .branches, .remoteBranches, .changes, .status, .repoInfo, .initRepository, .pull, .push,
             .fetch, .worktrees, .inspectRemoval, .worktreeHooks, .watch, .unwatch:
            break
        }
    }
}

extension WorktreeIntent {
    public func validate() throws(ErrorCode) {
        if let options { try options.validate(for: action) }
        switch action {
        case .create(_, let directory, let branch, let base):
            try Validation.gitPath(directory)
            try Validation.gitText(branch)
            if let base { try Validation.gitText(base) }
        case .register(_, let directory):
            try Validation.gitPath(directory)
        case .checkoutPullRequest(_, let directory, let number):
            try Validation.number(number)
            try Validation.gitPath(directory)
        case .remove(let expected):
            if expected.status.count > 4 * 1024 * 1024 { throw .badRequest }
            try Validation.gitPath(expected.directory)
        }
    }
}

extension WorktreeOptions {
    func validate(for action: WorktreeAction) throws(ErrorCode) {
        if let name {
            if Validation.isBlank(name) || name.utf8.count > 256 || Validation.hasNul(name) { throw .badRequest }
            guard case .create = action else { throw .badRequest }
        }
        if let hooks {
            let invalid = hooks.count > 128 || hooks.contains { hook in
                hook.command.utf8.count > 16 * 1024 || Validation.hasNul(hook.command)
                    || (hook.name?.utf8.count ?? 0) > 1024
            }
            if invalid { throw .badRequest }
            if case .register = action { throw .badRequest }
        }
    }
}

extension GitPullRequestAction {
    public func validate() throws(ErrorCode) {
        switch self {
        case .info, .number:
            break
        case .diff(let number, let lineLimit):
            try Validation.number(number)
            try Validation.lineLimit(lineLimit)
        case .list(_, let limit, _):
            if limit == 0 || limit > 200 { throw .badRequest }
        case .create(let title, let body, let baseBranch, _):
            try Validation.message(title, limit: 1024)
            if body.utf8.count > 64 * 1024 || Validation.hasNul(body) { throw .badRequest }
            if let baseBranch {
                try Validation.message(baseBranch, limit: 1024)
                if baseBranch.hasPrefix("-") { throw .badRequest }
            }
        case .merge(let number, _, _, let expectedHead):
            try Validation.number(number)
            if let expectedHead { try Validation.hash(expectedHead) }
        case .close(let number), .checkout(let number):
            try Validation.number(number)
        case .updateBranch(let number, let expectedHead):
            try Validation.number(number)
            try Validation.hash(expectedHead)
        }
    }
}

// MARK: - Files

extension FilesRequest {
    public func validate() throws(ErrorCode) {
        switch action {
        case .list(let path), .read(let path), .readBytes(let path), .stat(let path), .mkdir(let path):
            try path.validateRelative()
        case .write(let path, let content):
            try path.validateRelative()
            if content.utf8.count > Limits.maxFileBytes { throw .badRequest }
        case .writeBytes(let path, let bytes):
            try path.validateRelative()
            if bytes.count > Limits.maxFileBytes { throw .badRequest }
        case .rename(let path, let name):
            try path.validateRelative()
            try name.validateComponent()
        case .move(let paths, let into):
            try Self.validate(paths)
            try into.validateRelative()
        case .delete(let paths):
            try Self.validate(paths)
        case .searchFiles(let limit):
            if limit == 0 || limit > Limits.maxFileSearchResults { throw .badRequest }
        case .searchContent(let query):
            if query.query.isEmpty || query.query.utf8.count > 1024 || Validation.hasNul(query.query)
                || query.maxMatchesPerFile == 0 || query.maxMatchesPerFile > Limits.maxMatchesPerFile {
                throw .badRequest
            }
        case .watch, .unwatch:
            break
        }
    }

    static func validate(_ paths: [ServerPath]) throws(ErrorCode) {
        guard paths.count <= 4096, paths.reduce(0, { $0 + $1.byteCount }) <= Limits.maxFilePathBytes else {
            throw .badRequest
        }
        for path in paths { try path.validateRelative() }
    }
}

extension FilesReply {
    public func validate() throws(ErrorCode) {
        switch self {
        case .entries(let entries):
            guard entries.count <= Limits.maxFileEntries,
                  entries.reduce(0, { $0 + $1.path.byteCount + $1.name.byteCount }) <= Limits.maxFilePathBytes else {
                throw .badRequest
            }
            for entry in entries {
                try entry.path.validateRelative()
                try entry.name.validateRelative()
            }
        case .content(let file):
            try file.path.validateRelative()
            if file.content.utf8.count > Limits.maxFileBytes || file.size != UInt64(file.content.utf8.count) {
                throw .badRequest
            }
        case .bytes(let file):
            try file.path.validateRelative()
            if file.bytes.count > Limits.maxFileBytes { throw .badRequest }
        case .info(let info):
            try info.path.validateRelative()
        case .path(let path):
            try path.validateRelative()
        case .paths(let paths):
            try FilesRequest.validate(paths)
        case .fileList(let list):
            if list.paths.count > Limits.maxFileSearchResults { throw .badRequest }
        case .searchResults(let results):
            if results.files.contains(where: { $0.matches.count > Limits.maxMatchesPerFile }) { throw .badRequest }
        case .done:
            break
        }
    }
}

extension FileChanges {
    public func validate() throws(ErrorCode) {
        if paths.count > Limits.maxFileChanges || (rescan && !paths.isEmpty) { throw .badRequest }
        for path in paths { try path.validateRelative() }
    }
}

// MARK: - Exec and uploads

extension ExecRequest {
    public func validate() throws(ErrorCode) {
        let invalid = job == 0 || argv.first?.isEmpty == true || argv.count > 4096
            || stdin.count > Limits.maxExecOutput || timeoutMs == 0 || timeoutMs > Limits.maxExecTimeoutMs
            || argv.isEmpty == (shell == nil) || argv.contains(where: Validation.hasNul)
            || argv.reduce(0, { $0 + $1.utf8.count }) > 1024 * 1024
            || shell.map { $0.utf8.count > 1024 * 1024 || Validation.hasNul($0) } == true
        if invalid { throw .badRequest }
        do {
            try Validation.environment(env)
        } catch {
            throw .badRequest
        }
        try cwd?.validate()
    }
}

extension ExecResult {
    public func validate() throws(ErrorCode) {
        if stdout.utf8.count > Limits.maxExecOutput || stderr.utf8.count > Limits.maxExecOutput { throw .badRequest }
    }
}

extension UploadChunk {
    public func validate() throws(ErrorCode) {
        let (end, overflow) = offset.addingReportingOverflow(UInt64(bytes.count))
        if bytes.count > Limits.maxUploadChunk || name.utf8.count > Limits.maxUploadName || overflow
            || end > Limits.maxUploadBytes {
            throw .badRequest
        }
    }
}

// MARK: - Mobile access

extension RemoteAccessSettings {
    public func validate() throws(ErrorCode) {
        if port < 1024 { throw .badRequest }
    }
}

extension RemoteAccessState {
    public func validate() throws(ErrorCode) {
        try settings.validate()
        if devices.count > Limits.maxDevices { throw .badRequest }
        if case .failed(let message) = status, message.utf8.count > 1024 { throw .badRequest }
        for device in devices { try Validation.deviceName(device.name) }
    }
}

extension PairingInvite {
    public func validate() throws(ErrorCode) {
        try Validation.pairingHosts(hosts)
        if hosts.isEmpty || port < 1024 || fingerprint.count != 32 || code.count != 16 { throw .badRequest }
    }
}

extension Paired {
    public func validate() throws(ErrorCode) {
        if Validation.isBlank(name) || name.utf8.count > 255 || Validation.hasControl(name) { throw .badRequest }
    }
}
