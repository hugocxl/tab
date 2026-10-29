import Foundation
@testable import TabProtocol

/// One value of every message case, with fixed ids so fixtures stay stable.
enum Samples {
    static func uuid(_ value: UInt8) -> UUID {
        UUID(uuid: (value, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, value))
    }

    static let project = ProjectId(uuid: uuid(1))
    static let parent = ProjectId(uuid: uuid(2))
    static let session = SessionId(uuid: uuid(3))
    static let operation = OperationId(uuid: uuid(4))
    static let server = ServerId(uuid: uuid(5))
    static let client = ClientId(uuid: uuid(6))
    static let device = DeviceId(uuid: uuid(7))
    static let channel = ChannelId(7)
    static let size = Size(cols: 120, rows: 40)
    static let directory: ServerPath = "/Users/me/src/tab"

    static var style: Style {
        var style = Style()
        style.fg = .rgb(255, 128, 0)
        style.bg = .indexed(236)
        style.bold = true
        style.italic = true
        style.underline = .curly
        style.underlineColor = .rgb(1, 2, 3)
        style.invisible = true
        style.overline = true
        style.inverse = true
        style.strikethrough = true
        style.faint = true
        style.hyperlink = 42
        return style
    }

    static let rows: [Row] = [
        Row(index: 0, runs: [Run(text: "$ ls", width: 4), Run(text: "日本", width: 4, style: style)]),
        Row(index: 1, runs: [Run(text: "🙂 é", width: 4)]),
    ]

    static var screenRows: [Row] {
        (0 ..< 2).map { Row(index: UInt16($0), runs: [Run(text: "ok", width: 2)]) }
    }

    static let graphics = Graphics(
        cell: CellSize(width: 8, height: 16),
        images: [GraphicImage(id: 1, generation: 2, width: 1, height: 2, rgba: Data([1, 2, 3, 4, 5, 6, 7, 8]))],
        placements: [GraphicPlacement(image: 1, id: 9, column: -1, row: 3, offset: (x: 1, y: 2),
                                      size: (cols: 1, rows: 1), source: (x: 0, y: 0, width: 1, height: 2), z: -5)]
    )

    static let snapshot = AttachSnapshot(
        channel: channel, size: Size(cols: 10, rows: 2), rows: screenRows,
        cursor: Cursor(shape: .bar, row: 1, col: 1, visible: true), modes: Modes(), graphics: graphics,
        title: "zsh", directory: directory, prompts: [0, 2], history: [Row(index: 0, runs: [Run(text: "x", width: 1)])],
        historyCursor: HistoryCursor(9), historyTotal: 10
    )

    static let savedScreen = SavedScreen(size: Size(cols: 10, rows: 2), rows: screenRows,
                                         cursor: Cursor(row: 1, col: 2), graphics: nil, reason: .exited(1))

    static let descriptor = ProjectDescriptor(id: project, directory: directory, name: "tab", kind: .worktree,
                                              parentId: parent, worktreesHidden: true)

    static let summary = GitSummary(branch: "main", head: "abc123", upstream: "origin/main", ahead: 1, behind: 2,
                                    changed: 3, staged: 1, unstaged: 1, untracked: 1, conflicted: 0,
                                    commitSubject: "Fix", commitTimestamp: 1_700_000_000)

    static let file = GitFile(path: "src/a.swift", originalPath: "src/b.swift", index: .renamed,
                              worktree: .modified, added: 3, removed: 1)

    static let removal = WorktreeRemoval(directory: directory, device: 1, inode: 2, dirty: true,
                                         status: Data(" M a\n".utf8), head: "abc", branch: "feature")

    static let pullRequest = GitPullRequest(number: 12, url: "https://github.com/o/r/pull/12", title: "Add",
                                            author: "me", headBranch: "feature", headOid: "abc", baseBranch: "main",
                                            state: "OPEN", draft: true, updatedAt: "2026-01-01T00:00:00Z",
                                            mergeable: true, mergeState: "CLEAN", crossRepository: false,
                                            checks: GitChecks(passing: 3, failing: 1, pending: 2))

    static let rawDiff = GitRawDiff(diff: "diff --git a b\n", truncated: true)

    static let gitActions: [GitAction] = [
        .summary, .branches, .remoteBranches, .changes, .switchBranch("main"), .createBranch("new"),
        .deleteBranch("old"), .deleteLocalBranch(name: "old", force: true), .deleteRemoteBranch("old"),
        .stage(["a"]), .unstage(["a", "b"]), .discard(["c"]),
        .commit(message: "Fix", stageAll: true, amend: false),
        .diff(GitDiffRequest(path: "a", staged: true, lineLimit: 100, context: 3)),
        .rawDiff(GitDiffRequest(staged: false)), .log(maxCount: 50, skip: 10), .status(local: true), .repoInfo,
        .initRepository, .pull, .push(setUpstream: true), .fetch, .checkout("abc"), .cherryPick("def"),
        .revert("0123"), .createTag(name: "v1", hash: "abc"), .worktrees,
        .worktree(WorktreeIntent(operation: operation,
                                 action: .create(project: project, directory: "/tmp/w", branch: "b", base: "main"),
                                 options: WorktreeOptions(name: "W", hooks: [WorktreeHook(command: "make", name: "Build",
                                                                                          project: true)]))),
        .worktree(WorktreeIntent(operation: operation, action: .register(project: project, directory: "/tmp/w"))),
        .worktree(WorktreeIntent(operation: operation, action: .remove(expected: removal))),
        .worktree(WorktreeIntent(operation: operation,
                                 action: .checkoutPullRequest(project: project, directory: "/tmp/pr", number: 4))),
        .inspectRemoval, .worktreeHooks(teardown: true),
        .pullRequest(.info), .pullRequest(.number), .pullRequest(.diff(number: 3, lineLimit: nil)),
        .pullRequest(.list(filter: .merged, limit: 20, checks: true)),
        .pullRequest(.create(title: "T", body: "B", baseBranch: "main", draft: false)),
        .pullRequest(.merge(number: 3, method: .squash, deleteBranch: true, expectedHead: "abc")),
        .pullRequest(.close(number: 3)), .pullRequest(.checkout(number: 3)),
        .pullRequest(.updateBranch(number: 3, expectedHead: "abc")),
        .watch, .unwatch, .switchToBase("main"), .branchDiff(base: "main", lineLimit: 10),
        .changesPreview(lineLimit: nil), .stagedPreview(lineLimit: 5),
        .commitAll(message: "m", expectedHead: nil, expectedTree: "abc"),
        .commitStaged(message: "m", expectedHead: "def", expectedTree: "abc"),
        .publishBranch(branch: "b", destination: GitPushDestination(remote: "origin", branch: "b")),
    ]

    static let gitReplies: [GitReply] = [
        .summary(summary), .summary(nil), .branches([GitBranch(name: "main", current: true, checkedOut: true,
                                                               isDefault: true)]),
        .changes([file]),
        .worktrees([GitWorktree(directory: directory, head: "abc", branch: "main", primary: true, locked: true,
                                bare: false, detached: true, prunable: true, registered: project)]),
        .removal(removal), .project(descriptor), .done,
        .status(GitStatus(summary: summary, defaultBranch: "main", branches: [GitBranch(name: "x")],
                          files: [GitFileStatus(file: file, staged: GitLineStat(additions: 1, deletions: 2, binary: false),
                                                unstaged: GitLineStat(binary: true))],
                          pullRequest: pullRequest)),
        .repoInfo(GitRepoInfo(root: directory, gitDir: "/Users/me/src/tab/.git", isWorktree: true,
                              currentBranch: "main")),
        .remoteBranches(["origin/main"]),
        .log([GitCommit(hash: "abcdef", shortHash: "abc", subject: "S", authorName: "A", authorDate: "2026",
                        parentHashes: ["123"], refs: [GitRef(name: "main", kind: .localBranch),
                                                      GitRef(name: "v1", kind: .tag)])]),
        .rawDiff(rawDiff),
        .diff(GitDiff(rows: [GitDiffRow(kind: .hunk, text: "@@ -1 +1 @@"),
                             GitDiffRow(kind: .deletion, oldLineNumber: 1, oldText: "a", text: "-a"),
                             GitDiffRow(kind: .addition, newLineNumber: 1, newText: "b", text: "+b")],
                      additions: 1, deletions: 1, truncated: false, binary: false)),
        .commit("abcdef"), .pullRequest(pullRequest), .pullRequest(nil), .pullRequestNumber(12),
        .pullRequestNumber(nil), .pullRequests([pullRequest]),
        .changesPreview(GitChangesPreview(branch: "b", head: "abc", tree: "def", diff: rawDiff,
                                          files: [GitPreviewFile(path: "a", added: 1, removed: 2, untracked: true)],
                                          destination: GitPushDestination(remote: "origin", branch: "b"))),
        .baseSwitch(.updated), .baseSwitch(.checkedOutElsewhere(directory)),
        .worktreeHooks([WorktreeHook(command: "npm i", project: false)]),
        .worktreeSetupFailed(project: descriptor, message: "hook failed"),
    ]

    static let filesActions: [FilesAction] = [
        .list(""), .read("a.txt"), .readBytes("img.png"), .write(path: "a.txt", content: "hi\n"),
        .writeBytes(path: "b.bin", bytes: Data([0, 255])), .stat("a"), .mkdir("dir"),
        .rename(path: "a", name: "b"), .move(paths: ["a", "b"], into: "dir"), .delete(["a"]), .watch, .unwatch,
        .searchFiles(limit: 5000),
        .searchContent(ContentSearchQuery(query: "foo(", caseSensitive: true, regex: false, maxMatchesPerFile: 200)),
    ]

    static let filesReplies: [FilesReply] = [
        .entries([FileEntry(name: "a", path: "dir/a", isDirectory: false, isIgnored: true)]),
        .content(FileContent(path: "a", content: "héllo", size: 6)),
        .bytes(FileBytes(path: "b", bytes: Data([1, 2, 3]))),
        .info(FileInfo(name: "a", path: "a", isDirectory: true, size: 0)),
        .path("new"), .paths(["a", "b"]), .done,
        .fileList(FileList(paths: ["a.swift", "b/c.swift"], truncated: true)),
        .searchResults(ContentSearchResult(files: [
            FileMatches(path: "a.swift", matches: [ContentMatch(line: 3, column: 5, preview: "let foo(",
                                                                ranges: [MatchRange(start: 4, end: 8)])]),
        ], truncated: false)),
    ]

    static let colors = TerminalColors(
        foreground: RGB(0xd5, 0xce, 0xc7), background: RGB(0x11, 0x11, 0x11), cursor: RGB(255, 255, 255),
        ansi: (0 ..< 16).map { RGB(UInt8($0), UInt8($0 * 2), UInt8($0 * 3)) }, palette: [17: RGB(1, 2, 3)],
        cursorStyle: .underline, cursorBlink: true
    )

    static let requests: [RequestBody] = [
        .hello(Hello(versions: [.v1], client: .desktop, clientId: client,
                     build: BuildInfo(version: "1.0.0"))),
        .ping, .listSessions,
        .createSession(CreateSession(project: project, operation: operation, directory: directory, size: size,
                                     command: "htop", environment: ["http_proxy": "http://p:1"])),
        .attach(session: session, size: size), .attachWithoutResize(session), .detach(channel),
        .endSession(session), .closeSession(session: session, operation: operation), .discardSession(session),
        .readSavedScreen(session), .historyPage(channel: channel, before: HistoryCursor(100), maxRows: 200),
        .savedHistoryPage(session: session, before: nil, maxRows: 50),
        .searchHistory(source: .live(channel), query: "error", ignoreCase: true, before: nil, maxResults: 100),
        .searchHistory(source: .saved(session), query: "x", ignoreCase: false, before: HistoryCursor(5),
                       maxResults: 1),
        .clearScreen(channel), .setTerminalColors(colors),
        .syncSessionReferences(owner: operation, revision: 3, sessions: [session]),
        .identifyClient(.cli), .cancelCreation(operation), .writeInput(session: session, bytes: Data("ls\r".utf8)),
        .readCatalog(after: project, revision: 4), .readCatalog(after: nil, revision: nil),
        .mutateProject(ProjectIntent(operation: operation, mutation: .create(descriptor))),
        .mutateProject(ProjectIntent(operation: operation, mutation: .rename(project: project, name: "New"))),
        .mutateProject(ProjectIntent(operation: operation, mutation: .delete(project))),
        .mutateProject(ProjectIntent(operation: operation, mutation: .pruneWorktree(project))),
        .mutateProject(ProjectIntent(operation: operation, mutation: .setWorktreesVisible(project: project,
                                                                                         visible: false))),
        .listProjectSessions(project: project, after: session, revision: 2), .listFolders("/Users"),
        .readServerSettings,
        .writeServerSettings(ServerSettingsDoc(defaultShell: "/bin/zsh", historyBudgetBytes: 1024,
                                               shellIntegration: false)),
        .stopServer(force: true), .stopServerIfIdle, .restartServer,
        .git(GitRequest(project: project, action: .summary)),
        .files(FilesRequest(project: project, action: .watch)),
        .exec(ExecRequest(job: 1, project: project, argv: ["git", "status"], cwd: directory, env: ["A": "b"],
                          stdin: Data([1]), timeoutMs: 1000)),
        .cancelExec(job: 1),
        .upload(UploadChunk(session: session, upload: operation, name: "shot.png", offset: 0,
                            bytes: Data([9, 8]), last: true)),
        .readActivity, .acknowledgeActivity([1, 2]), .claimActivity([3]),
        .authenticate(DeviceCredential(device: device, token: Data(repeating: 7, count: 32))),
        .pair(PairRequest(code: Data(repeating: 1, count: 16), name: "iPhone")),
        .readRemoteAccess, .writeRemoteAccess(RemoteAccessSettings(enabled: true, port: 7419)),
        .startPairing(hosts: ["mac.local", "192.168.1.2"]), .cancelPairing, .revokeDevice(device),
        .unknown("someFutureRequest"),
    ]

    static let invite = PairingInvite(hosts: ["mac.local"], port: 7419, fingerprint: Data(repeating: 0xab, count: 32),
                                      code: Data(repeating: 0x01, count: 16))

    static let activity = ActivitySnapshot(
        revision: 9,
        agents: [AgentActivity(session: session, project: project, provider: .claude, state: .blocked)],
        events: [AgentEvent(id: 1, session: session, project: project, provider: .ohMyPi, timestamp: 1000,
                            kind: .attention, read: false)]
    )

    static let replies: [ReplyBody] = [
        .hello(HelloReply(version: .v1,
                          server: ServerInfo(build: BuildInfo(version: "1.0.0"), instance: 77, server: server),
                          features: Feature.all)),
        .versionUnsupported(supported: [.v1]), .pong,
        .error(ErrorReply(code: .unknownSession, message: "gone")),
        .sessions([SessionInfo(project: project, id: session, directory: directory)]),
        .sessionCreated(SessionInfo(project: project, id: session, directory: directory)),
        .attached(snapshot: snapshot, process: ForegroundProcess(name: "vim", isShell: false)),
        .attached(snapshot: snapshot, process: nil),
        .detached, .sessionEnded, .sessionClosed, .sessionDiscarded, .creationCancelled,
        .savedScreen(savedScreen),
        .historyPage(HistoryPage(prompts: [0], rows: rows, next: HistoryCursor(5), totalRows: 50,
                                 screen: savedScreen)),
        .searchPage(SearchPage(matches: [SearchMatch(row: 9, start: 1, end: 4), SearchMatch(row: 2, start: 0, end: 1)],
                               next: HistoryCursor(3), totalRows: 10, scannedRows: 7)),
        .screenCleared, .terminalColorsSet, .sessionReferencesSynced,
        .clientIdentified(SessionClient(id: client, kind: .mobile)), .inputWritten,
        .catalog(CatalogPage(server: server, home: project,
                             revision: 1, projects: [ProjectDescriptor(id: project, home: true, directory: "/Users/me",
                                                                       name: "Home")], next: nil)),
        .projectMutated(revision: 4),
        .projectSessions(ProjectSessions(revision: 1, sessions: [
            ProjectSession(info: SessionInfo(project: project, id: session, directory: directory), status: .live,
                           owner: SessionClient(id: client, kind: .desktop), attached: true),
        ], next: session)),
        .folders(["Documents", "src"]),
        .serverSettings(ServerSettingsDoc()), .serverSettingsWritten, .serverStopping, .serverBusy,
        .serverRestarting,
        .git(.done), .files(.done),
        .exec(ExecResult(stdout: "out", stderr: "err", exitCode: 2, timedOut: true, truncated: true, cancelled: true)),
        .execCancelled, .uploaded("/tmp/tab-uploads/shot.png"), .uploaded(nil),
        .activity(activity), .activityAcknowledged, .activityClaimed([1]), .authenticated,
        .paired(Paired(credential: DeviceCredential(device: device, token: Data(repeating: 2, count: 32)),
                       server: server, name: "Mac")),
        .remoteAccess(RemoteAccessState(revision: 2, settings: RemoteAccessSettings(enabled: true, port: 7419),
                                        status: .failed("port busy"), pairingExpiresAt: 99,
                                        devices: [PairedDevice(id: device, name: "Phone", pairedAt: 1, lastSeen: 2,
                                                               connected: true)])),
        .remoteAccess(RemoteAccessState(revision: 3, settings: RemoteAccessSettings(), status: .listening)),
        .pairing(PairingOffer(invite: invite, expiresAt: 1234)),
        .unknown("someFutureReply"),
    ]

    static let events: [EventBody] = [
        .changed(topic: .catalog, revision: 1), .changed(topic: .remoteAccess, revision: 2),
        .sessionMetadata(session: session, metadata: SessionMetadata(title: "t", directory: directory,
                                                                     process: ForegroundProcess(name: "zsh",
                                                                                                isShell: true))),
        .progress(session: session, progress: SessionProgress(progress: TerminalProgress(state: .running, percent: 40),
                                                              completed: 2)),
        .sessionEnded(session: session, reason: .signaled(9)), .sessionEnded(session: session, reason: .ended),
        .sessionEnded(session: session, reason: .serverStopped),
        .gitChanged(project: project), .filesChanged(project: project, changes: FileChanges(paths: ["a"])),
        .serverRestarting, .fatal(ErrorReply(code: .unauthorized, message: "no")), .unknown("someFutureEvent"),
    ]

    static let sessionMessages: [SessionMessage] = [
        .metadata(.title("vim")), .metadata(.directory(directory)),
        .metadata(.foregroundProcess(ForegroundProcess(name: "vim", isShell: false))), .metadata(.bell),
        .metadata(.history(totalRows: 100)), .metadata(.inputModes(InputModes())), .metadata(.cursorBlinking(true)),
        .metadata(.links(seq: 3, rows: [LinkRow(row: 1, spans: [LinkSpan(start: 0, end: 5, uri: "https://x.y")])])),
        .metadata(.screenPrompts(seq: 3, rows: [0, 5])), .metadata(.clipboardWrite("copied")),
        .metadata(.unknown("future")),
        .ended(.exited(0)), .resized(size),
        .input(.bytes(Data([27, 91]))), .input(.text("é")), .input(.paste("a\nb")), .input(.focus(true)),
        .input(.key(KeyEvent(key: "a", modifiers: [.control], text: "a", unshiftedCodepoint: 97))),
        .input(.mouse(MouseEvent(action: .scroll, scroll: .up, col: 3, row: 4))),
        .resize(size), .ack(99), .scroll(.lines(-3)), .scroll(.top), .scroll(.bottom),
        .cellSize(CellSize(width: 9, height: 18)), .requestHistory, .clear, .unknown("future"),
    ]
}
