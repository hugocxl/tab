import Darwin
import Foundation
import TabProtocol
import TabTerminal

/// Owns one session's terminal and program for its whole life. Every call to
/// the terminal happens on `queue`; the PTY reader thread only reads and
/// hands bytes over, and input is written on a separate queue so a program
/// that stops reading never stalls the screen.
final class SessionOwner: @unchecked Sendable {
    static let tick: TimeInterval = 0.016
    static let synchronizedTimeout: TimeInterval = 1
    static let checkpointInterval: TimeInterval = 1
    static let metadataInterval: TimeInterval = 1
    static let processInterval: TimeInterval = 0.25
    static let detectionInterval: TimeInterval = 0.1
    static let compressionQuiet: TimeInterval = 2
    static let endGrace: TimeInterval = 2
    static let drainGrace: TimeInterval = 1

    let info: SessionInfo
    let queue: DispatchQueue
    private let inputQueue: DispatchQueue
    private let pty: PTY
    private let terminal: Terminal
    private let archive: ArchiveStore
    private let activity: Activity
    private let detector: AgentDetector?
    private weak var delegate: SessionOwnerDelegate?

    // Shared with other threads.
    private let shared = NSLock()
    private var sharedMetadata: SessionMetadata
    private var sharedProgress = SessionProgress()
    private var sharedSize: Size
    private var pendingOutput = Data()
    private var drainScheduled = false

    // Owned by `queue`.
    private struct Attachment {
        let sink: SessionSink
        var seq: UInt64
    }

    private var attachments: [UInt64: Attachment] = [:]
    private var size: Size
    private var outputPending = false
    private var resetPending = false
    private var tickScheduled = false
    private var historyTotal: UInt64 = 0
    private var historyGeneration: UInt64 = 0
    private var inputModes = InputModes()
    private var cursorBlinking = true
    private var links: [LinkRow] = []
    private var prompts: [UInt16] = []
    private var graphics: Graphics?
    private var frameState: (Cursor, Modes)?
    private var synchronizedSince: TimeInterval?
    private var title = ""
    private var directory: ServerPath
    private var process: ForegroundProcess?
    private var observedDirectory: String?
    private var nextProcessProbe: TimeInterval = 0
    private var lastOutput: TimeInterval = 0
    private var agent: AgentProvider?
    private var agentGroup: pid_t = 0
    private var tracker = AgentStateTracker()
    private var detectionScreen = ""
    private var detectionNeeded = true
    private var detectionScheduled = false
    private var detectionProgress = ""
    private var compressionScheduled = false
    private var checkpointScheduled = false
    private var checkpointDelay = SessionOwner.checkpointInterval
    private var processSource: DispatchSourceProcess?
    private var exit: PTYExit?
    private var outputClosed = false
    private var requestedEnd: ExitReason?
    private var finishing = false
    private var finishCompletions: [@Sendable (ExitReason) -> Void] = []

    init(info: SessionInfo, request: SpawnRequest, historyBudgetBytes: UInt64, colors: TerminalColors?,
         archive: ArchiveStore, activity: Activity, detector: AgentDetector?,
         delegate: SessionOwnerDelegate) throws {
        self.info = info
        queue = DispatchQueue(label: "tab.session.\(info.id)", qos: .userInitiated)
        inputQueue = DispatchQueue(label: "tab.session.\(info.id).input", qos: .userInitiated)
        let budget = Int(clamping: historyBudgetBytes)
        do {
            terminal = try Terminal(size: request.size, historyBudgetBytes: budget)
            if let colors { try terminal.setDefaults(colors.theme) }
        } catch {
            throw ServiceError(.spawnFailed, "Could not start the terminal: \(error)")
        }
        do {
            pty = try PTY(spawning: request)
        } catch {
            throw ServiceError(.spawnFailed, "Could not start \(request.program): \(error)")
        }
        size = request.size
        sharedSize = request.size
        directory = info.directory
        sharedMetadata = SessionMetadata(title: "", directory: info.directory)
        self.archive = archive
        self.activity = activity
        self.detector = detector
        self.delegate = delegate
    }

    /// Starts reading output and watching for the program's exit.
    func start() throws {
        let source = DispatchSource.makeProcessSource(identifier: pty.pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.checkExit() }
        processSource = source
        source.resume()
        do {
            try pty.startReader(output: { [weak self] data in self?.received(data) },
                                closed: { [weak self] in self?.queue.async { self?.readerClosed() } })
        } catch {
            source.cancel()
            try? pty.terminate()
            _ = try? pty.waitForExit()
            throw ServiceError(.spawnFailed, "Could not read the terminal: \(error)")
        }
        queue.async { [self] in
            scheduleMetadataPoll()
            scheduleCheckpoint()
            checkExit()
        }
    }

    // MARK: Shared state

    var metadata: SessionMetadata { shared.withLock { sharedMetadata } }
    var progress: SessionProgress { shared.withLock { sharedProgress } }
    var currentSize: Size { shared.withLock { sharedSize } }

    // MARK: Output

    /// On the reader thread: queue the bytes and wake the session once.
    private func received(_ data: Data) {
        let schedule = shared.withLock { () -> Bool in
            pendingOutput.append(data)
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
        if schedule { queue.async { [self] in drainOutput() } }
    }

    private func drainOutput() {
        let data = shared.withLock { () -> Data in
            drainScheduled = false
            defer { pendingOutput = Data() }
            return pendingOutput
        }
        guard !data.isEmpty else { return }
        feed(data)
    }

    private func feed(_ data: Data) {
        terminal.feed(data)
        writeEngineReplies()
        lastOutput = now
        if (try? terminal.synchronizedOutput()) == true {
            if synchronizedSince == nil { synchronizedSince = now }
        } else {
            synchronizedSince = nil
        }
        outputPending = true
        detectionNeeded = true
        scheduleTick()
        scheduleCheckpoint()
        scheduleCompression()
    }

    private func writeEngineReplies() {
        let replies = terminal.takePtyOutput()
        if !replies.isEmpty { write(replies) }
    }

    private func write(_ data: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        inputQueue.async { [pty] in
            do {
                try pty.write(data)
                completion?(nil)
            } catch {
                completion?(error)
            }
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Ticks

    private func scheduleTick() {
        guard !tickScheduled, !finishing else { return }
        tickScheduled = true
        queue.asyncAfter(deadline: .now() + Self.tick) { [weak self] in self?.tickNow() }
    }

    private func tickNow() {
        tickScheduled = false
        guard !finishing else { return }
        if let since = synchronizedSince, (try? terminal.synchronizedOutput()) == true {
            if now - since < Self.synchronizedTimeout {
                scheduleTick()
                return
            }
            try? terminal.endSynchronizedOutput()
        }
        synchronizedSince = nil
        updateMetadata()
        if let modes = try? terminal.inputModes(), modes != inputModes {
            inputModes = modes
            broadcast(.inputModes(modes))
        }
        updateCursorBlinking()
        if outputPending || resetPending {
            broadcastFrame()
        }
    }

    private func updateCursorBlinking() {
        guard let blinking = try? terminal.cursorBlinking(), blinking != cursorBlinking else { return }
        cursorBlinking = blinking
        broadcast(.cursorBlinking(blinking))
    }

    private func broadcast(_ event: MetadataEvent) {
        for (id, attachment) in attachments where !attachment.sink.metadata(event) {
            attachments[id] = nil
        }
    }

    private func broadcastFrame() {
        let reset = resetPending
        outputPending = false
        resetPending = false
        guard !attachments.isEmpty else { return }
        do {
            let total = UInt64(try terminal.historyCount())
            let generation = try terminal.historyGeneration()
            if total != historyTotal || generation != historyGeneration {
                historyTotal = total
                historyGeneration = generation
                broadcast(.history(totalRows: total))
            }
            let currentGraphics = try terminal.graphics()
            let shownGraphics: Graphics? = currentGraphics.images.isEmpty && currentGraphics.placements.isEmpty
                ? nil : currentGraphics
            let graphicsChanged = shownGraphics != graphics || reset
            graphics = shownGraphics
            let rows = try terminal.render().map { Row(index: $0.index, runs: ScreenShape.fit($0.runs, cols: size.cols)) }
            let cursor = ScreenShape.cursor(try terminal.cursor(), size: size)
            let modes = try terminal.modes()
            let currentLinks = linkRows()
            let currentPrompts = try terminal.screenPrompts()
            let linksChanged = currentLinks != links
            let promptsChanged = currentPrompts != prompts
            links = currentLinks
            prompts = currentPrompts
            let stateChanged = frameState.map { $0.0 != cursor || $0.1 != modes } ?? true
            guard reset || !rows.isEmpty || graphicsChanged || linksChanged || promptsChanged || stateChanged else {
                return
            }
            frameState = (cursor, modes)
            let sentGraphics = graphicsChanged ? (shownGraphics ?? Graphics(cell: terminal.cellSize)) : nil
            for (id, var attachment) in attachments {
                let frame = ScreenFrame(size: size, seq: attachment.seq, reset: reset, rows: rows, cursor: cursor,
                                        modes: modes, graphics: sentGraphics, historyRows: total)
                if promptsChanged || reset { _ = attachment.sink.metadata(.screenPrompts(seq: frame.seq, rows: prompts)) }
                if linksChanged || reset { _ = attachment.sink.metadata(.links(seq: frame.seq, rows: links)) }
                attachment.seq += 1
                attachments[id] = attachment.sink.frame(frame) ? attachment : nil
            }
        } catch {
            ServerLog.error("session \(info.id) render failed: \(error)")
        }
    }

    private func linkRows() -> [LinkRow] {
        terminal.hyperlinkRows().compactMap { row in
            let spans = row.spans.filter { $0.end <= size.cols && $0.start < $0.end }
                .map { LinkSpan(start: $0.start, end: $0.end, uri: $0.uri) }
            return spans.isEmpty || row.row >= size.rows ? nil : LinkRow(row: row.row, spans: spans)
        }
    }

    // MARK: Metadata

    private func scheduleMetadataPoll() {
        queue.asyncAfter(deadline: .now() + Self.metadataInterval) { [weak self] in
            guard let self, !self.finishing else { return }
            self.nextProcessProbe = 0
            self.updateMetadata()
            self.scheduleMetadataPoll()
        }
    }

    private func updateMetadata() {
        var sharedChanged = false
        for event in terminal.takeEvents() {
            switch event {
            case .title(let value) where value != title:
                title = value
                sharedChanged = true
                detectionNeeded = true
                broadcast(.title(value))
            case .title:
                break
            case .directory(let value):
                if let path = ForegroundProbe.terminalDirectory(value), path != directory.rawValue {
                    directory = ServerPath(path)
                    sharedChanged = true
                    broadcast(.directory(directory))
                }
            case .clipboardWrite(let text):
                if text.utf8.count <= Limits.maxClipboardText { broadcast(.clipboardWrite(text)) }
            case .bell:
                broadcast(.bell)
            case .progress(let update):
                updateProgress(update)
            }
        }
        if now >= nextProcessProbe {
            nextProcessProbe = now + Self.processInterval
            sharedChanged = probeProcess() || sharedChanged
        }
        if sharedChanged {
            let metadata = SessionMetadata(title: title, directory: directory, process: process)
            shared.withLock { sharedMetadata = metadata }
            delegate?.sessionMetadataChanged(info.id, metadata)
        }
    }

    private func probeProcess() -> Bool {
        guard let observation = ForegroundProbe.observe(master: pty.masterFD, shell: pty.pid) else { return false }
        var changed = false
        if observation.process != process {
            process = observation.process
            changed = true
            detectionNeeded = true
            broadcast(.foregroundProcess(observation.process))
        }
        if detector != nil, observation.group != agentGroup {
            agentGroup = observation.group
            let provider = observation.process.isShell && ForegroundProbe.shells.contains(
                observation.process.name.trimmingCharacters(in: CharacterSet(charactersIn: "-")))
                ? nil : ForegroundProbe.agentProvider(group: observation.group)
            if provider != agent {
                agent = provider
                detectionNeeded = true
                detectionProgress = ""
                detect()
                scheduleDetection()
            }
        }
        if let observed = observation.directory, observed != observedDirectory {
            observedDirectory = observed
            if observed != directory.rawValue {
                directory = ServerPath(observed)
                changed = true
                broadcast(.directory(directory))
            }
        }
        return changed
    }

    private func updateProgress(_ update: ProgressUpdate) {
        let report = update.report.map { report -> TerminalProgress in
            let state: ProgressState = switch report.state {
            case .running: .running
            case .error: .error
            case .indeterminate: .indeterminate
            case .paused: .paused
            }
            return TerminalProgress(state: state, percent: report.percent)
        }
        detectionProgress = update.report.map { report in
            let code = switch report.state {
            case .running: 1
            case .error: 2
            case .indeterminate: 3
            case .paused: 4
            }
            return "\(code);\(report.percent.map(Int.init) ?? -1)"
        } ?? ""
        detectionNeeded = true
        let progress = SessionProgress(progress: report, completed: update.completed)
        shared.withLock { sharedProgress = progress }
        delegate?.sessionProgressChanged(info.id, progress)
    }

    // MARK: Agent detection

    /// Polls while an agent runs in the foreground, reading the screen again
    /// only when it changed and isn't mid-frame.
    private func scheduleDetection() {
        guard detector != nil, agent != nil, !detectionScheduled, !finishing else { return }
        detectionScheduled = true
        queue.asyncAfter(deadline: .now() + Self.detectionInterval) { [weak self] in
            guard let self else { return }
            self.detectionScheduled = false
            guard !self.finishing else { return }
            self.detect()
            self.scheduleDetection()
        }
    }

    private func detect() {
        guard let detector else { return }
        guard let agent else {
            if tracker.provider != nil {
                tracker = AgentStateTracker()
                activity.clearAgent(info.id)
            }
            return
        }
        if detectionNeeded, (try? terminal.synchronizedOutput()) != true {
            detectionScreen = (try? terminal.detectionText()) ?? ""
            detectionNeeded = false
        }
        let completed = tracker.update(detector: detector, provider: agent, screen: detectionScreen, title: title,
                                       progress: detectionProgress, now: .now)
        guard let provider = tracker.provider else { return }
        activity.update(AgentActivity(session: info.id, project: info.project, provider: provider,
                                      state: tracker.state), completed: completed)
    }

    // MARK: Memory and saving

    private func scheduleCompression() {
        guard !compressionScheduled, !finishing else { return }
        compressionScheduled = true
        queue.asyncAfter(deadline: .now() + Self.compressionQuiet) { [weak self] in
            guard let self else { return }
            self.compressionScheduled = false
            guard !self.finishing else { return }
            let quiet = self.now - self.lastOutput
            if quiet < Self.compressionQuiet {
                self.compressionScheduled = true
                self.queue.asyncAfter(deadline: .now() + Self.compressionQuiet - quiet) { [weak self] in
                    self?.compressionScheduled = false
                    self?.scheduleCompression()
                }
                return
            }
            self.compressStep()
        }
    }

    private func compressStep() {
        guard !finishing, now - lastOutput >= Self.compressionQuiet else { return }
        if (try? terminal.compress(.incremental)) == true {
            queue.async { [weak self] in self?.compressStep() }
        }
    }

    private func scheduleCheckpoint() {
        guard !checkpointScheduled, !finishing else { return }
        checkpointScheduled = true
        queue.asyncAfter(deadline: .now() + checkpointDelay) { [weak self] in
            guard let self else { return }
            self.checkpointScheduled = false
            guard !self.finishing else { return }
            self.checkpoint()
        }
    }

    /// Captures the screen and history and hands them to the writer. A slow
    /// capture spaces the next ones out.
    private func checkpoint() {
        let started = now
        do {
            let snapshot = try terminal.archive()
            archive.save(info.id, snapshot, reason: nil)
        } catch {
            ServerLog.error("session \(info.id) could not capture its content: \(error)")
        }
        checkpointDelay = max(Self.checkpointInterval, (now - started) * 10)
    }

    // MARK: Attachments

    /// Attaches a client. The first attachment sets the size; `nil` keeps it.
    func attach(_ id: UInt64, sink: SessionSink, size requested: Size?) {
        queue.async { [self] in
            guard !finishing else {
                sink.failed(errorReply(ServiceError.unknownSession(info.id)))
                return
            }
            do {
                if attachments.isEmpty, let requested, requested != size {
                    try applySize(requested)
                }
                updateMetadata()
                updateCursorBlinking()
                if attachments.isEmpty {
                    _ = try terminal.render()
                    links = linkRows()
                    prompts = try terminal.screenPrompts()
                    frameState = (ScreenShape.cursor(try terminal.cursor(), size: size), try terminal.modes())
                    graphics = nil
                    historyTotal = UInt64(try terminal.historyCount())
                    historyGeneration = try terminal.historyGeneration()
                    outputPending = false
                    resetPending = false
                } else {
                    broadcastFrame()
                }
                let page = try historyPageNow(before: nil, maxRows: UInt16(Limits.maxAttachHistory))
                guard let screen = page.screen else { throw ServiceError(.historyUnavailable, "No screen") }
                let snapshot = AttachSnapshot(
                    channel: ChannelId(0), size: size, rows: screen.rows, cursor: screen.cursor,
                    modes: try terminal.modes(), graphics: screen.graphics, title: title, directory: directory,
                    prompts: page.prompts, history: page.rows, historyCursor: page.next, historyTotal: page.totalRows)
                guard sink.attached(snapshot, process: process) else { return }
                _ = sink.metadata(.inputModes(try terminal.inputModes()))
                _ = sink.metadata(.cursorBlinking(cursorBlinking))
                _ = sink.metadata(.links(seq: 0, rows: links))
                attachments[id] = Attachment(sink: sink, seq: 1)
            } catch {
                sink.failed(errorReply(error))
            }
        }
    }

    func detach(_ id: UInt64) {
        queue.async { [self] in attachments[id] = nil }
    }

    /// Resizes for every attached client.
    func resize(_ size: Size) {
        queue.async { [self] in
            guard !finishing, size != self.size else { return }
            do {
                try applySize(size)
                broadcastResize()
            } catch {
                ServerLog.error("session \(info.id) resize failed: \(error)")
            }
        }
    }

    private func applySize(_ size: Size) throws {
        try pty.resize(size)
        try terminal.resize(size)
        self.size = size
        shared.withLock { sharedSize = size }
        resetPending = true
        scheduleTick()
        scheduleCheckpoint()
    }

    private func broadcastResize() {
        for (id, attachment) in attachments where !attachment.sink.resized(size) {
            attachments[id] = nil
        }
    }

    func setCellSize(_ cell: CellSize) {
        queue.async { [self] in
            guard !finishing else { return }
            try? pty.setCellSize(cell)
            try? terminal.setCellSize(cell)
            outputPending = true
            scheduleTick()
        }
    }

    func setColors(_ colors: TerminalColors) {
        queue.async { [self] in
            guard !finishing else { return }
            try? terminal.setDefaults(colors.theme)
            writeEngineReplies()
            outputPending = true
            scheduleTick()
        }
    }

    // MARK: Input

    func input(_ data: Data) {
        guard !data.isEmpty else { return }
        write(data)
    }

    func input(_ input: TerminalInput) {
        if case .bytes(let data) = input {
            self.input(data)
            return
        }
        queue.async { [self] in
            guard !finishing else { return }
            do {
                let data: Data = switch input {
                case .bytes(let bytes): bytes
                case .text(let text): try terminal.encodeText(text)
                case .key(let event): try terminal.encodeKey(event)
                case .mouse(let event): try terminal.encodeMouse(event)
                case .paste(let text): try terminal.encodePaste(text)
                case .focus(let focused): try terminal.encodeFocus(focused)
                }
                if !data.isEmpty { write(data) }
            } catch {
                ServerLog.error("session \(info.id) input encoding failed: \(error)")
            }
        }
    }

    /// Writes bytes and reports when the terminal took them.
    func writeInput(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        write(data, completion: completion)
    }

    func scroll(_ request: ScrollRequest) {
        queue.async { [self] in
            guard !finishing else { return }
            switch request {
            case .lines(let lines): terminal.scroll(.delta(Int(lines)))
            case .top: terminal.scroll(.top)
            case .bottom: terminal.scroll(.bottom)
            case .unknown: return
            }
            outputPending = true
            scheduleTick()
        }
    }

    /// Sends the current history total to one attachment.
    func requestHistory(_ id: UInt64) {
        queue.async { [self] in
            guard let attachment = attachments[id], let total = try? terminal.historyCount() else { return }
            _ = attachment.sink.metadata(.history(totalRows: UInt64(total)))
        }
    }

    /// Clears the screen and history through the engine (Cmd+K).
    func clearScreen(completion: (@Sendable (Error?) -> Void)? = nil) {
        queue.async { [self] in
            guard !finishing else {
                completion?(ServiceError.unknownSession(info.id))
                return
            }
            do {
                if try terminal.clearScreen() {
                    resetPending = true
                    outputPending = true
                    detectionNeeded = true
                    writeEngineReplies()
                    scheduleTick()
                    scheduleCheckpoint()
                }
                completion?(nil)
            } catch {
                completion?(ServiceError(.badRequest, "Could not clear the terminal: \(error)"))
            }
        }
    }

    // MARK: History

    func historyPage(before: HistoryCursor?, maxRows: UInt16,
                     completion: @escaping @Sendable (Result<HistoryPage, Error>) -> Void) {
        queue.async { [self] in
            completion(Result { try historyPageNow(before: before, maxRows: maxRows) })
        }
    }

    private func historyPageNow(before: HistoryCursor?, maxRows: UInt16) throws -> HistoryPage {
        do {
            let generation = try terminal.historyGeneration()
            let total = try terminal.historyCount()
            let (range, next) = try HistoryWindow.range(session: info.id, generation: generation, before: before,
                                                        maxRows: maxRows, total: total)
            let slice = try terminal.history(range)
            let rows = slice.rows.enumerated().map {
                Row(index: UInt16($0.offset), runs: ScreenShape.fit($0.element.runs, cols: Limits.maxCols))
            }
            var prompts = slice.prompts.filter { Int($0) < rows.count }
            var screen: SavedScreen?
            if before == nil {
                let screenPrompts = try terminal.screenPrompts()
                prompts += screenPrompts.compactMap { UInt16(exactly: rows.count + Int($0)) }
                let current = try terminal.graphics()
                screen = SavedScreen(
                    size: size, rows: ScreenShape.rows(try terminal.fullRender(), size: size),
                    cursor: ScreenShape.cursor(try terminal.cursor(), size: size),
                    graphics: current.images.isEmpty && current.placements.isEmpty ? nil : current)
            }
            prompts = Array(Set(prompts)).sorted()
            scheduleCompression()
            return HistoryPage(prompts: prompts, rows: rows, next: rows.isEmpty ? nil : next,
                               totalRows: UInt64(total), screen: screen)
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError(.historyUnavailable, "Terminal history: \(error)")
        }
    }

    func search(query: String, ignoreCase: Bool, before: HistoryCursor?, maxResults: UInt16,
                completion: @escaping @Sendable (Result<SearchPage, Error>) -> Void) {
        queue.async { [self] in
            completion(Result {
                do {
                    let historyRows = try terminal.historyCount()
                    let search = HistorySearch(
                        session: info.id, generation: try terminal.historyGeneration(), query: query,
                        ignoreCase: ignoreCase, before: before, maxResults: maxResults, historyRows: historyRows,
                        screenRows: Int(size.rows))
                    let range = try search.range()
                    let historyEnd = min(range.upperBound, historyRows)
                    let historyStart = min(range.lowerBound, historyEnd)
                    let history = try terminal.history(historyStart..<historyEnd).rows
                    let screen = range.upperBound > historyRows ? try terminal.fullRender() : []
                    scheduleCompression()
                    return try search.scan { index in
                        if index < historyRows {
                            let offset = index - historyStart
                            return offset < history.count ? history[offset].runs : []
                        }
                        let row = index - historyRows
                        return row < screen.count ? screen[row].runs : []
                    }
                } catch let error as ServiceError {
                    throw error
                } catch {
                    throw ServiceError(.historyUnavailable, "Search: \(error)")
                }
            })
        }
    }

    // MARK: Ending

    /// Ends the program (hang-up, then kill after a grace period).
    /// `completion` runs once the session finished and its last save ended.
    func end(_ reason: ExitReason, completion: (@Sendable (ExitReason) -> Void)? = nil) {
        queue.async { [self] in
            if let ended {
                completion?(ended)
                return
            }
            if let completion { finishCompletions.append(completion) }
            guard requestedEnd == nil, exit == nil else { return }
            requestedEnd = reason
            try? pty.kill(SIGHUP)
            queue.asyncAfter(deadline: .now() + Self.endGrace) { [weak self] in
                guard let self, self.exit == nil else { return }
                try? self.pty.terminate()
                self.checkExit()
            }
            checkExit()
        }
    }

    private func readerClosed() {
        outputClosed = true
        checkExit()
        if exit == nil {
            // The reader closes just before the kernel reports the exit.
            queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.checkExit() }
        }
    }

    private func checkExit() {
        guard !finishing else { return }
        if exit == nil { exit = pty.exitReason() }
        guard let exit else { return }
        if outputClosed {
            finish(exit)
            return
        }
        // Wait briefly for output still in the PTY.
        queue.asyncAfter(deadline: .now() + Self.drainGrace) { [weak self] in
            guard let self, !self.finishing else { return }
            self.finish(exit)
        }
    }

    private func finish(_ exit: PTYExit) {
        guard !finishing else { return }
        drainOutput()
        updateMetadata()
        finishing = true
        processSource?.cancel()
        processSource = nil
        let reason: ExitReason
        switch (requestedEnd, exit) {
        case (let requested?, _): reason = requested
        case (nil, .exited(let code)): reason = .exited(code)
        case (nil, .signaled(let signal)): reason = .signaled(signal)
        }
        activity.remove(info.id)
        let save: (@escaping ArchiveStore.Completion) -> Void
        do {
            let snapshot = try terminal.archive()
            save = { [archive, info] completion in archive.save(info.id, snapshot, reason: reason, completion: completion) }
        } catch {
            ServerLog.error("session \(info.id) could not capture its last screen: \(error)")
            save = { completion in completion(error) }
        }
        save { [weak self] error in
            guard let self else { return }
            self.queue.async {
                for attachment in self.attachments.values { attachment.sink.ended(reason) }
                self.attachments = [:]
                self.finishedReason = reason
                if let delegate = self.delegate {
                    delegate.sessionFinished(self, reason: reason, saved: error == nil)
                } else {
                    self.signalFinished()
                }
            }
        }
    }

    private var finishedReason: ExitReason?
    private var ended: ExitReason?

    /// The server recorded the end: callers waiting for it may go on.
    func signalFinished() {
        queue.async { [self] in
            guard let reason = finishedReason, ended == nil else { return }
            ended = reason
            let completions = finishCompletions
            finishCompletions = []
            for completion in completions { completion(reason) }
        }
    }

    /// Calls `completion` once the session finished (immediately if it has).
    func whenFinished(_ completion: @escaping @Sendable (ExitReason) -> Void) {
        queue.async { [self] in
            if let ended {
                completion(ended)
            } else {
                finishCompletions.append(completion)
            }
        }
    }
}

extension TerminalColors {
    var theme: TerminalTheme {
        func color(_ rgb: RGB) -> ThemeColor { ThemeColor(rgb.red, rgb.green, rgb.blue) }
        var palette: [UInt8: ThemeColor] = [:]
        for (index, rgb) in self.palette {
            if let index = UInt8(exactly: index) { palette[index] = color(rgb) }
        }
        return TerminalTheme(foreground: color(foreground), background: color(background), cursor: color(cursor),
                             ansi: ansi.map(color), palette: palette, cursorStyle: cursorStyle,
                             cursorBlink: cursorBlink)
    }
}
