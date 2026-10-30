import AppKit
import Combine
import TabClient
import TabCore
import TabProtocol

/// Answers every palette page from the model: commands, files, Find in
/// Files, branches, changes, worktrees, terminals, projects, workspaces,
/// themes and Open Project. Lists that come from a server load once per
/// opening and refresh the page when they arrive.
@MainActor
final class PaletteSource: PaletteDataSource {
    unowned let model: AppModel
    weak var palette: PaletteController?
    weak var actions: WindowActions?
    /// Runs a shortcut's action as its key would.
    var perform: ((ShortcutId) -> Void)?

    private var files: [ProjectId: Loadable<[String]>] = [:]
    private var branches: [ProjectId: Loadable<[GitBranch]>] = [:]
    private var changes: [ProjectId: Loadable<[GitFile]>] = [:]
    private var sessions: [ProjectId: Loadable<[ProjectSession]>] = [:]
    private var find = FindState()
    private let folders = FolderSearch()
    private var subscription: AnyCancellable?
    private var waitingForFolders: Set<ServerId> = []

    enum Loadable<Value> {
        case loading
        case loaded(Value)
        case failed(String)

        var value: Value? {
            if case .loaded(let value) = self { return value }
            return nil
        }
    }

    struct FindState {
        var caseSensitive = false
        var regex = false
        var query = ""
        var result: Loadable<ContentSearchResult>?
        var task: Task<Void, Never>?
    }

    init(model: AppModel) {
        self.model = model
        folders.onChange = { [weak self] in self?.palette?.refresh(.addProject(.local)) }
        subscription = model.changes.sink { [weak self] _ in
            guard let self else { return }
            for server in self.waitingForFolders where self.model.connectionState(server).isReady {
                let path = self.remoteFolders[server]?.path
                self.loadRemoteFolders(server, path: path?.isEmpty == false ? path : nil)
            }
        }
    }

    private var current: Project { model.currentProject }

    /// Fuzzy ranking for a query; the list's own order without one.
    private func rankKeepingOrder<Item>(_ items: [Item], key: (Item) -> String, query: String, limit: Int) -> [Fuzzy.Ranked<Item>] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            let ordered = Array(items.enumerated())
            let ranked = Fuzzy.rank(ordered, key: { String(format: "%08d", $0.offset) }, query: "", limit: limit)
            return ranked.map { entry in
                var copy = Fuzzy.rank([entry.item.element], key: { _ in "" }, query: "", limit: 1)[0]
                copy.ranges = []
                return copy
            }
        }
        return Fuzzy.rank(items, key: key, query: query, limit: limit)
    }

    // MARK: Specs

    func spec(for page: PalettePage) -> PageSpec {
        switch page {
        case .root: return PageSpec(.root, placeholder: "Search for commands, files, branches…")
        case .files: return PageSpec(.files, placeholder: "Go to file…", breadcrumb: "Go to File")
        case .find:
            var spec = PageSpec(.find, placeholder: "Find in files…", breadcrumb: "Find in Files")
            spec.accessories = [
                .toggle(id: "case", label: "Aa", active: find.caseSensitive),
                .toggle(id: "regex", label: ".*", active: find.regex),
            ]
            spec.emptyMessage = "Type to search the project's files"
            return spec
        case .branches: return PageSpec(page, placeholder: "Switch to branch…", breadcrumb: "Switch Branch")
        case .newBranch:
            var spec = PageSpec(page, placeholder: "New branch name…", breadcrumb: "New Branch")
            spec.emptyMessage = "Type the new branch's name"
            return spec
        case .changes: return PageSpec(page, placeholder: "Filter changes…", breadcrumb: "Changes")
        case .worktrees: return PageSpec(page, placeholder: "Switch to worktree…", breadcrumb: "Switch Worktree")
        case .terminals:
            var spec = PageSpec(page, placeholder: "Search terminals…", breadcrumb: "Existing Terminals")
            spec.emptyMessage = "Every terminal of this project is open"
            return spec
        case .projects: return PageSpec(page, placeholder: "Switch to project…", breadcrumb: "Switch Project")
        case .workspaces: return PageSpec(page, placeholder: "Switch to workspace…", breadcrumb: "Switch Workspace")
        case .newTerminal: return PageSpec(page, placeholder: "New terminal in project…", breadcrumb: "New Terminal in Project")
        case .themes: return PageSpec(page, placeholder: "Search themes…", breadcrumb: "Change Theme")
        case .addProject(let server):
            var spec = PageSpec(page, placeholder: "Search folders or enter a path…",
                                breadcrumb: server.isLocal ? "Open Project" : "Add Project on \(model.serverName(server) ?? "Server")")
            spec.completesOnTab = true
            return spec
        case .commands: return PageSpec(page, placeholder: "Run command…", breadcrumb: "Commands")
        }
    }

    // MARK: Opening

    func opened(_ page: PalettePage) {
        switch page {
        case .root:
            if !current.home { loadFiles(current.id) }
            if model.git[current.id]?.isRepository ?? false { loadBranches(current.id) }
        case .files: loadFiles(current.id, force: true)
        case .branches(let project), .newBranch(let project): loadBranches(project, force: true)
        case .changes(let project): loadChanges(project)
        case .terminals(let project): loadSessions(project)
        case .addProject(let server):
            if server.isLocal { folders.start(root: searchRoot) } else { loadRemoteFolders(server, path: nil) }
        default: break
        }
    }

    func closed() {
        waitingForFolders.removeAll()
        find.task?.cancel()
        files = [:]
        changes = [:]
        sessions = [:]
        model.acknowledgeFocusedActivity()
        model.focusActiveContent()
    }

    func ran(_ page: PalettePage, item: String) {
        guard page == .root, !item.contains("/") else { return }
        model.updateAppearance { appearance in
            appearance.paletteRecent.removeAll { $0 == item }
            appearance.paletteRecent.insert(item, at: 0)
            appearance.paletteRecent = Array(appearance.paletteRecent.prefix(RootRanking.recentLimit))
        }
    }

    func toggled(_ page: PalettePage, accessory: String, active: Bool) {
        guard page == .find else { return }
        if accessory == "case" { find.caseSensitive = active }
        if accessory == "regex" { find.regex = active }
        find.query = ""
    }

    // MARK: Content

    func content(for page: PalettePage, query: String) -> PageContent {
        let query = query.trimmingCharacters(in: .whitespaces)
        switch page {
        case .root: return rootContent(query)
        case .files: return filesContent(query)
        case .find: return findContent(query)
        case .branches(let project): return branchesContent(project, query)
        case .newBranch(let project): return newBranchContent(project, query)
        case .changes(let project): return changesContent(project, query)
        case .worktrees(let parent): return .items(worktreeItems(parent, query, limit: .max))
        case .terminals(let project): return terminalsContent(project, query)
        case .projects: return .items(projectItems(query, limit: .max))
        case .workspaces: return .items(workspaceItems(query))
        case .newTerminal: return .items(newTerminalItems(query))
        case .themes: return .items(themeItems(query))
        case .addProject(let server): return addProjectContent(server, query)
        case .commands: return .items(customCommandItems(query))
        }
    }

    // MARK: Root

    func rootCommands() -> [RootCommand] {
        var commands: [RootCommand] = []
        let keymap = model.settings.keymap
        func command(_ id: ShortcutId, _ title: String, _ category: PaletteCategory, keywords: String = "", disabled: Bool = false) {
            commands.append(RootCommand(id: id.rawValue, title: title, keywords: keywords, category: category,
                                        shortcut: keymap.chord(id), disabled: disabled,
                                        target: .run { [weak self] in self?.perform?(id) }))
        }
        func page(_ id: String, _ title: String, _ category: PaletteCategory, _ page: PalettePage, shortcut: ShortcutId? = nil,
                  keywords: String = "", disabled: Bool = false) {
            commands.append(RootCommand(id: id, title: title, keywords: keywords, category: category,
                                        shortcut: shortcut.flatMap { keymap.chord($0) }, disabled: disabled, target: .page(page)))
        }
        let terminalPane = model.activePane.flatMap { model.state.pane($0) }?.content.isTerminal ?? false
        let project = current.id
        let paneCount = model.activeTab?.panes.count ?? 0
        let missing = current.status == .missing
        command(.newTab, "New Terminal", .terminal)
        command(.newHomeTab, "New Home Terminal", .terminal)
        page(ShortcutId.newTabInProject.rawValue, "New Terminal in Project…", .terminal, .newTerminal, shortcut: .newTabInProject)
        page(ShortcutId.existingTerminals.rawValue, "Existing Terminals…", .terminal, .terminals(project), shortcut: .existingTerminals)
        command(.closeTab, "Close Tab", .terminal, disabled: model.activeTab == nil)
        let single = model.sidebarListing.targets.count < 2
        command(.nextTab, "Next Tab", .terminal, disabled: single)
        command(.previousTab, "Previous Tab", .terminal, disabled: single)
        for (id, title) in [(ShortcutId.find, "Find…"), (.findNext, "Find Next"), (.findPrevious, "Find Previous"),
                            (.previousPrompt, "Previous Prompt"), (.nextPrompt, "Next Prompt"),
                            (.selectCommandOutput, "Select Command Output"), (.scrollToBottom, "Scroll to Bottom"),
                            (.increaseFontSize, "Increase Font Size"), (.decreaseFontSize, "Decrease Font Size"),
                            (.detachTerminal, "Detach Terminal")] {
            command(id, title, .terminal, disabled: !terminalPane)
        }
        for (id, title) in [(ShortcutId.splitRight, "Split Right"), (.splitDown, "Split Down"), (.closePane, "Close Pane"),
                            (.toggleZoomPane, "Toggle Pane Zoom")] {
            command(id, title, .panes, disabled: missing || model.activePane == nil)
        }
        for (id, title) in [(ShortcutId.equalizeSplits, "Equalize Splits"), (.focusPaneLeft, "Focus Pane Left"),
                            (.focusPaneRight, "Focus Pane Right"), (.focusPaneUp, "Focus Pane Up"), (.focusPaneDown, "Focus Pane Down")] {
            command(id, title, .panes, disabled: missing || paneCount < 2)
        }
        command(.newBrowserTab, "New Browser Pane", .panes, disabled: missing || !model.settings.browser.enabled)
        page(ShortcutId.goToFile.rawValue, "Go to File…", .files, .files, shortcut: .goToFile, keywords: "quick open file")
        page(ShortcutId.findInFiles.rawValue, "Find in Files…", .files, .find, shortcut: .findInFiles, keywords: "search grep")
        command(.toggleFiles, "Toggle Files", .files, keywords: "explorer tree folder")
        let repository = model.git[project]?.isRepository ?? false
        page("switch_branch", "Switch Branch…", .git, .branches(project), keywords: "git checkout", disabled: !repository)
        page("git_changes", "Changes…", .git, .changes(project), keywords: "git status stage diff", disabled: !repository)
        page("new_branch", "New Branch…", .git, .newBranch(project), keywords: "git create", disabled: !repository)
        command(.toggleSourceControl, "Toggle Source Control", .git, keywords: "git changes stage commit")
        for (action, title) in [(RepositoryAction.commit, "Commit with AI…"), (.createPullRequest, "Create Pull Request with AI…")] {
            let availability = model.ai.availability(action, project: project)
            if availability == .hidden { continue }
            var disabled = false
            if case .disabled = availability { disabled = true }
            commands.append(RootCommand(id: "ai_\(action.rawValue)", title: title, keywords: "ai agent generate", category: .git,
                                        disabled: disabled, target: .run { [weak self] in self?.model.ai.start(action, project: project) }))
        }
        command(.newWorktree, "New Worktree…", .worktrees, disabled: model.newWorktreeTarget == nil)
        if let parent = worktreeSwitcherProject {
            page(ShortcutId.switchWorktree.rawValue, "Switch Worktree…", .worktrees, .worktrees(parent), shortcut: .switchWorktree)
        } else {
            command(.switchWorktree, "Switch Worktree…", .worktrees, disabled: true)
        }
        let singleProject = model.navigationProjects.count < 2
        command(.nextProject, "Next Project", .projects, disabled: singleProject)
        command(.previousProject, "Previous Project", .projects, disabled: singleProject)
        page("switch_project", "Switch Project…", .projects, .projects)
        if !model.state.workspaces.isEmpty || model.offersRemoteServersWorkspace {
            page("switch_workspace", "Switch Workspace…", .projects, .workspaces)
        }
        page(ShortcutId.addProject.rawValue, "Open Project…", .projects, .addProject(.local), shortcut: .addProject,
             keywords: "add project folder")
        for server in model.settings.servers {
            page("add_project_on:\(server.id)", "Add Project on \(server.name)…", .projects, .addProject(server.id),
                 keywords: server.destination)
        }
        command(.toggleSidebar, "Toggle Sidebar", .view)
        command(.toggleAgentsPanel, "Toggle Agents Panel", .view)
        command(.toggleAgentSessions, "Toggle Agent Sessions", .view, keywords: "harness history resume providers")
        page(ShortcutId.toggleThemePicker.rawValue, "Change Theme…", .view, .themes, shortcut: .toggleThemePicker,
             keywords: "appearance colors")
        command(.toggleVoiceRecording, "Toggle Voice Recording", .view, keywords: "dictation speech")
        command(.toggleFullScreen, "Toggle Full Screen", .window)
        command(.minimize, "Minimize Window", .window)
        command(.zoom, "Zoom Window", .window, keywords: "Maximize Restore")
        command(.quit, "Quit \(Release.appName)", .window, keywords: "Quit exit")
        command(.endAllSessionsAndQuit, "End All Sessions and Quit", .window)
        command(.installCommandLineTool, "Install Command Line Tool…", .window)
        commands.append(RootCommand(id: "check_for_updates", title: "Check for Updates…", category: .window,
                                    target: .run { [weak self] in self?.model.updater.checkForUpdates() }))
        commands.append(RootCommand(id: "remote_servers", title: "Remote Servers…", category: .remote,
                                    target: .run { [weak self] in self?.model.showServersPane() }))
        command(.openSettings, "Open Settings", .settings)
        for custom in model.settings.commands {
            commands.append(RootCommand(
                id: custom.shortcutId, title: custom.name, keywords: custom.command, category: .custom,
                shortcut: keymap.binding(custom.shortcutId), disabled: missing,
                target: .run { [weak self] in self?.runCustom(custom) }
            ))
        }
        return commands
    }

    func runCustom(_ command: CustomCommand) {
        model.newTerminal(in: model.currentProject.id, command: command.command)
    }

    private var worktreeSwitcherProject: ProjectId? {
        let root = current.parentId ?? current.id
        guard let project = model.state.project(root), !project.home,
              model.listingBuilder().hasWorktrees(project) else { return nil }
        return root
    }

    private func rootContent(_ query: String) -> PageContent {
        let commands = rootCommands()
        guard !query.isEmpty else {
            return PageContent(sections: RootRanking.sections(commands, recent: model.appearance.paletteRecent))
        }
        var sections: [PaletteSection] = []
        let ranked = RootRanking.ranked(commands, query: query)
        if !ranked.isEmpty { sections.append(PaletteSection("Commands", ranked)) }
        let limit = RootRanking.hitLimit
        if query.count >= 2, !current.home {
            let (items, more) = fileItems(query, limit: limit)
            push(&sections, "Files", items, more: more, page: .files, query: query)
        }
        let (branchHits, moreBranches) = branchItems(current.id, query, limit: limit)
        push(&sections, "Branches", branchHits, more: moreBranches, page: .branches(current.id), query: query)
        if let parent = worktreeSwitcherProject {
            let items = worktreeItems(parent, query, limit: limit + 1)
            push(&sections, "Worktrees", Array(items.prefix(limit)), more: items.count > limit, page: .worktrees(parent), query: query)
        }
        let projects = projectItems(query, limit: limit + 1)
        push(&sections, "Projects", Array(projects.prefix(limit)), more: projects.count > limit, page: .projects, query: query)
        let terminals = openTerminalItems(query, limit: limit)
        push(&sections, "Terminals", terminals, more: false, page: .terminals(current.id), query: query)
        if sections.isEmpty { return .empty("No results for “\(query)”") }
        return PageContent(sections: sections)
    }

    private func push(_ sections: inout [PaletteSection], _ title: String, _ items: [PaletteItem], more: Bool,
                      page: PalettePage, query: String) {
        guard !items.isEmpty else { return }
        var items = items.map { item -> PaletteItem in
            var item = item
            item.id = "\(title.lowercased())/\(item.id)"
            return item
        }
        if more {
            var seeAll = PaletteItem(id: "see-all:\(title)", title: "See all in \(title)", target: .apply { [weak self] in
                self?.palette?.push(page, query: query)
            })
            seeAll.tile = .none
            items.append(seeAll)
        }
        sections.append(PaletteSection(title, items))
    }

    // MARK: Files

    private func loadFiles(_ project: ProjectId, force: Bool = false) {
        if !force, files[project] != nil { return }
        guard let side = model.sideClient(for: project) else {
            files[project] = .failed("The project's server is not connected.")
            return
        }
        if files[project]?.value == nil { files[project] = .loading }
        Task {
            do {
                let list = try await side.searchFiles(project)
                files[project] = .loaded(list.paths)
            } catch {
                files[project] = .failed(error.message)
            }
            palette?.refresh()
        }
    }

    private func fileItems(_ query: String, limit: Int) -> ([PaletteItem], Bool) {
        guard let paths = files[current.id]?.value else { return ([], false) }
        let ranked: [(String, [Range<Int>])]
        if query.isEmpty {
            ranked = paths.sorted { left, right in
                let leftDepth = left.split(separator: "/").count
                let rightDepth = right.split(separator: "/").count
                return leftDepth != rightDepth ? leftDepth < rightDepth : left.localizedStandardCompare(right) == .orderedAscending
            }.prefix(limit + 1).map { ($0, []) }
        } else {
            ranked = rankKeepingOrder(paths, key: { $0 }, query: query, limit: limit + 1).map { ($0.item, $0.ranges) }
        }
        let project = current.id
        let items = ranked.prefix(limit).map { path, ranges -> PaletteItem in
            let name = (path as NSString).lastPathComponent
            let directory = (path as NSString).deletingLastPathComponent
            let offset = (path as NSString).length - (name as NSString).length
            var item = PaletteItem(id: path, title: name, target: .run { [weak self] in
                self?.model.openEditor(project: project, path: path)
            })
            item.highlights = ranges.compactMap { range in
                range.lowerBound >= offset ? (range.lowerBound - offset)..<(range.upperBound - offset) : nil
            }
            item.subtitle = directory.isEmpty ? nil : directory + "/"
            item.kind = PaletteKind.file.rawValue
            item.tile = PaletteKind.file.tile
            item.actions = fileActions(project)
            return item
        }
        return (items, ranked.count > limit)
    }

    private func fileActions(_ project: ProjectId) -> [PaletteItemAction] {
        var actions = [PaletteItemAction("open", "Open File")]
        if model.state.project(project)?.serverId.isLocal == true {
            actions.append(PaletteItemAction("reveal", "Reveal in Finder"))
        }
        actions.append(PaletteItemAction("copy", "Copy Path"))
        actions.append(PaletteItemAction("copy-relative", "Copy Relative Path"))
        return actions
    }

    private func filesContent(_ query: String) -> PageContent {
        switch files[current.id] {
        case .loading?, nil: return .loading("Loading files…")
        case .failed(let message)?: return .error(message)
        case .loaded?:
            let (items, _) = fileItems(query, limit: 200)
            return items.isEmpty ? .empty(query.isEmpty ? "No files" : "No files match “\(query)”") : .items(items)
        }
    }

    // MARK: Find in Files

    private func findContent(_ query: String) -> PageContent {
        guard !query.isEmpty else { return PageContent() }
        if query != find.query { startFind(query) }
        switch find.result {
        case .loading?, nil: return .loading("Searching…")
        case .failed(let message)?: return .error(message)
        case .loaded(let result)?:
            let project = current.id
            let sections = result.files.map { file -> PaletteSection in
                let items = file.matches.map { match -> PaletteItem in
                    var item = PaletteItem(id: "\(file.path):\(match.line):\(match.column)",
                                           title: match.preview.trimmingCharacters(in: .whitespaces), target: .run { [weak self] in
                        self?.model.openEditor(project: project, path: file.path, line: Int(match.line), column: Int(match.column))
                    })
                    item.subtitle = "line \(match.line)"
                    item.tile = PaletteKind.file.tile
                    item.kind = PaletteKind.file.rawValue
                    return item
                }
                return PaletteSection(file.path, items)
            }
            if sections.isEmpty { return .empty("No matches for “\(query)”") }
            return PageContent(sections: sections)
        }
    }

    private func startFind(_ query: String) {
        find.query = query
        find.task?.cancel()
        guard let side = model.sideClient(for: current.id) else {
            find.result = .failed("The project's server is not connected.")
            return
        }
        find.result = .loading
        let project = current.id
        let search = ContentSearchQuery(query: query, caseSensitive: find.caseSensitive, regex: find.regex)
        find.task = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            do {
                let result = try await side.searchContent(project, search)
                guard !Task.isCancelled, find.query == query else { return }
                find.result = .loaded(result)
            } catch {
                guard !Task.isCancelled else { return }
                find.result = .failed(error.message)
            }
            palette?.refresh(.find)
        }
    }

    // MARK: Git

    private func loadBranches(_ project: ProjectId, force: Bool = false) {
        if !force, branches[project] != nil { return }
        guard let side = model.sideClient(for: project) else { return }
        if branches[project]?.value == nil { branches[project] = .loading }
        Task {
            do {
                branches[project] = .loaded(try await side.gitBranches(project))
            } catch {
                branches[project] = .failed(error.message)
            }
            palette?.refresh()
        }
    }

    private func branchItems(_ project: ProjectId, _ query: String, limit: Int) -> ([PaletteItem], Bool) {
        guard let list = branches[project]?.value else { return ([], false) }
        let ranked: [(GitBranch, [Range<Int>])] = query.isEmpty
            ? list.map { ($0, []) }
            : rankKeepingOrder(list, key: \.name, query: query, limit: .max).map { ($0.item, $0.ranges) }
        let items = ranked.prefix(limit).map { entry -> PaletteItem in
            let branch = entry.0
            var item = PaletteItem(id: branch.name, title: branch.name, target: .run { [weak self] in
                self?.switchBranch(project, branch.name)
            })
            item.highlights = entry.1
            item.current = branch.current
            item.disabled = branch.checkedOut && !branch.current
            item.badge = branch.isDefault ? "default" : (branch.checkedOut && !branch.current ? "in a worktree" : nil)
            item.kind = PaletteKind.branch.rawValue
            item.tile = PaletteKind.branch.tile
            item.actions = [PaletteItemAction("switch", "Switch Branch"),
                            PaletteItemAction("delete", "Delete Branch…", destructive: true)]
            return item
        }
        return (items, ranked.count > limit)
    }

    private func branchesContent(_ project: ProjectId, _ query: String) -> PageContent {
        switch branches[project] {
        case .loading?, nil: return .loading("Loading branches…")
        case .failed(let message)?: return .error(message)
        case .loaded?:
            let (items, _) = branchItems(project, query, limit: .max)
            return items.isEmpty ? .empty("No branches match “\(query)”") : .items(items)
        }
    }

    private func switchBranch(_ project: ProjectId, _ name: String) {
        runGit(project, .switchBranch(name), done: "Switched to \(name)")
    }

    private func newBranchContent(_ project: ProjectId, _ query: String) -> PageContent {
        guard !query.isEmpty else { return PageContent() }
        let base = model.git[project]?.summary?.branch
        var item = PaletteItem(id: "create", title: "Create branch “\(query)”", target: .run { [weak self] in
            self?.runGit(project, .createBranch(query), done: "Created and switched to \(query)")
        })
        item.subtitle = base.map { "from \($0)" }
        item.tile = PaletteKind.branch.tile
        item.kind = PaletteKind.branch.rawValue
        return .items([item])
    }

    private func runGit(_ project: ProjectId, _ action: GitAction, done: String) {
        guard let side = model.sideClient(for: project) else { return }
        Task {
            do {
                _ = try await side.git(GitRequest(project: project, action: action))
                model.presenter?.showToast(done, error: false)
                model.gitChanged(project)
            } catch {
                model.report(error.message)
            }
        }
    }

    private func loadChanges(_ project: ProjectId) {
        guard let side = model.sideClient(for: project) else {
            changes[project] = .failed("The project's server is not connected.")
            return
        }
        if changes[project]?.value == nil { changes[project] = .loading }
        Task {
            do {
                changes[project] = .loaded(try await side.gitChanges(project))
            } catch {
                changes[project] = .failed(error.message)
            }
            palette?.refresh()
        }
    }

    private func changesContent(_ project: ProjectId, _ query: String) -> PageContent {
        switch changes[project] {
        case .loading?, nil: return .loading("Loading changes…")
        case .failed(let message)?: return .error(message)
        case .loaded(let files)?:
            let groups: [(String, (GitFile) -> Bool, Bool)] = [
                ("Conflicts", { $0.isConflicted }, false),
                ("Staged", { !$0.isConflicted && !$0.isUntracked && $0.index != .unmodified }, true),
                ("Changes", { !$0.isConflicted && !$0.isUntracked && $0.worktree != .unmodified }, false),
                ("Untracked", { $0.isUntracked }, false),
            ]
            let needle = Fuzzy.normalize(query)
            let sections = groups.map { title, belongs, staged in
                PaletteSection(title, files.filter(belongs).compactMap { file -> PaletteItem? in
                    let path = file.path.rawValue
                    guard let match = Fuzzy.match(path, needle) else { return nil }
                    var item = PaletteItem(id: "\(title):\(path)", title: (path as NSString).lastPathComponent, target: .run { [weak self] in
                        self?.model.openDiff(project: project, path: path, staged: staged)
                    })
                    let directory = (path as NSString).deletingLastPathComponent
                    item.subtitle = directory.isEmpty ? nil : directory + "/"
                    item.highlights = query.isEmpty ? [] : match.ranges.compactMap { range in
                        let offset = (path as NSString).length - (item.title as NSString).length
                        return range.lowerBound >= offset ? (range.lowerBound - offset)..<(range.upperBound - offset) : nil
                    }
                    item.kind = PaletteKind.change.rawValue
                    item.tile = PaletteKind.change.tile
                    item.actions = [PaletteItemAction("diff", "Open Diff"),
                                    staged ? PaletteItemAction("unstage", "Unstage", keepOpen: true)
                                        : PaletteItemAction("stage", "Stage", keepOpen: true),
                                    PaletteItemAction("discard", "Discard Changes", destructive: true)]
                    return item
                })
            }
            let content = PageContent(sections: sections)
            return content.sections.allSatisfy(\.items.isEmpty) ? .empty("No changes") : content
        }
    }

    // MARK: Worktrees

    private func worktreeItems(_ parent: ProjectId, _ query: String, limit: Int) -> [PaletteItem] {
        guard let root = model.state.project(parent) else { return [] }
        let recent = model.appearance.worktreeRecent
        var projects = ([root] + model.state.projects.filter { $0.parentId == parent }).enumerated().sorted { left, right in
            let leftRank = recent.firstIndex(of: left.element.id) ?? Int.max
            let rightRank = recent.firstIndex(of: right.element.id) ?? Int.max
            return leftRank != rightRank ? leftRank < rightRank : left.offset < right.offset
        }.map(\.element)
        if let index = projects.firstIndex(where: { $0.id == current.id }) {
            projects.insert(projects.remove(at: index), at: 0)
        }
        let needle = Fuzzy.normalize(query)
        var items: [PaletteItem] = []
        for project in projects {
            guard let match = Fuzzy.match(project.name, needle) else { continue }
            var item = PaletteItem(id: project.id.description, title: project.name, target: .run { [weak self] in
                self?.model.selectProject(project.id)
            })
            item.highlights = match.ranges
            item.subtitle = model.git[project.id]?.summary?.branch
            item.current = project.id == current.id
            item.badge = project.id == parent ? "primary" : nil
            item.disabled = project.status != .available
            item.kind = PaletteKind.worktree.rawValue
            item.tile = PaletteKind.worktree.tile
            var actions = [PaletteItemAction("open", "Switch to Worktree")]
            if project.parentId != nil {
                actions.append(PaletteItemAction("rename", "Rename Worktree…"))
                actions.append(PaletteItemAction("remove", "Remove Worktree and Files…", destructive: true))
            }
            item.actions = actions
            items.append(item)
            if items.count >= limit { break }
        }
        if limit == .max {
            var create = PaletteItem(id: "new-worktree", title: "New Worktree…", target: .run { [weak self] in
                self?.actions?.newWorktree(parent: parent)
            })
            create.tile = .icon(.plus, .purple)
            items.append(create)
        }
        return items
    }

    // MARK: Terminals

    private func loadSessions(_ project: ProjectId) {
        guard let main = model.client(for: project) else {
            sessions[project] = .failed("The project's server is not connected.")
            return
        }
        sessions[project] = .loading
        Task {
            do {
                let shown = Set(model.state.sessionReferences(model.state.projectServer(project) ?? .local))
                let available = try await main.availableProjectSessions(project).filter { !shown.contains($0.info.id) }
                sessions[project] = .loaded(available)
            } catch {
                sessions[project] = .failed(error.message)
            }
            palette?.refresh()
        }
    }

    private func terminalsContent(_ project: ProjectId, _ query: String) -> PageContent {
        switch sessions[project] {
        case .loading?, nil: return .loading("Loading terminals…")
        case .failed(let message)?: return .error(message)
        case .loaded(let list)?:
            let needle = Fuzzy.normalize(query)
            let items = list.compactMap { session -> PaletteItem? in
                let title = TerminalSessionController.abbreviate(session.info.directory.rawValue)
                guard let match = Fuzzy.match(title, needle) else { return nil }
                var item = PaletteItem(id: session.info.id.description, title: title, target: .run { [weak self] in
                    self?.model.openExistingSession(session.info.id, in: project)
                })
                item.highlights = match.ranges
                if let owner = session.owner {
                    item.subtitle = owner.kind == .desktop ? "Opened in another Tab window" : "Opened by \(owner.kind.rawValue)"
                }
                item.badge = session.status == .starting ? "starting" : nil
                item.kind = PaletteKind.terminal.rawValue
                item.tile = PaletteKind.terminal.tile
                return item
            }
            return items.isEmpty ? .empty(query.isEmpty ? "Every terminal of this project is open" : "No terminals match") : .items(items)
        }
    }

    /// Open terminal panes, for the root search.
    private func openTerminalItems(_ query: String, limit: Int) -> [PaletteItem] {
        guard !query.isEmpty else { return [] }
        var candidates: [(Pane, Project)] = []
        for project in model.state.projects where model.state.isListed(project) || project.home {
            for pane in project.tabs.flatMap(\.panes) where pane.content.isTerminal { candidates.append((pane, project)) }
        }
        return rankKeepingOrder(candidates, key: { $0.0.title }, query: query, limit: limit).map { entry in
            let (pane, project) = entry.item
            var item = PaletteItem(id: pane.id.description, title: pane.title, target: .run { [weak self] in
                self?.model.focusPane(pane.id)
            })
            item.highlights = entry.ranges
            item.subtitle = model.title(of: project)
            item.kind = PaletteKind.terminal.rawValue
            item.tile = PaletteKind.terminal.tile
            return item
        }
    }

    // MARK: Projects and workspaces

    private func projectItems(_ query: String, limit: Int) -> [PaletteItem] {
        let builder = model.listingBuilder()
        let projects = builder.listedParents()
        return rankKeepingOrder(projects, key: { builder.title($0) }, query: query, limit: limit).map { entry in
            let project = entry.item
            var item = PaletteItem(id: project.id.description, title: builder.title(project), target: .run { [weak self] in
                guard let self else { return }
                self.model.selectProject(self.model.preferredWorktree(project.id))
            })
            item.highlights = entry.ranges
            item.subtitle = displayPath(project)
            item.current = project.id == current.id || project.id == current.parentId
            item.disabled = project.status != .available
            item.kind = PaletteKind.project.rawValue
            item.tile = model.projectIcon(project.id).map { PaletteTile(.image($0), .none) } ?? PaletteKind.project.tile
            return item
        }
    }

    func displayPath(_ project: Project) -> String {
        let path = project.directory.rawValue
        if project.serverId.isLocal { return TabDirs.abbreviateHome(path, home: NSHomeDirectory()) ?? path }
        return "\(model.serverName(project.serverId) ?? "") · \(path)"
    }

    private func workspaceItems(_ query: String) -> [PaletteItem] {
        let active = model.state.activeWorkspace?.id
        var entries: [(String, String, Bool, @MainActor () -> Void)] = [
            ("all", "All Projects", active == nil && !model.state.remoteServersSelected, { [weak self] in self?.model.selectWorkspace(nil) }),
        ]
        for workspace in model.state.workspaces {
            entries.append((workspace.id.description, workspace.name, workspace.id == active, { [weak self] in
                self?.model.selectWorkspace(workspace.id)
            }))
        }
        if model.offersRemoteServersWorkspace {
            entries.append(("remote", "Remote Servers", model.state.remoteServersSelected, { [weak self] in
                self?.model.selectRemoteServersWorkspace()
            }))
        }
        var items = rankKeepingOrder(entries, key: { $0.1 }, query: query, limit: .max).map { entry in
            var item = PaletteItem(id: entry.item.0, title: entry.item.1, target: .run(entry.item.3))
            item.highlights = entry.ranges
            item.current = entry.item.2
            item.kind = PaletteKind.workspace.rawValue
            item.tile = PaletteKind.workspace.tile
            return item
        }
        var create = PaletteItem(id: "new-workspace", title: "New Workspace…", target: .run { [weak self] in
            self?.actions?.newWorkspace(adding: nil, anchor: nil)
        })
        create.tile = .icon(.plus, .indigo)
        items.append(create)
        return items
    }

    private func newTerminalItems(_ query: String) -> [PaletteItem] {
        let builder = model.listingBuilder()
        var projects = [model.state.home] + model.state.projects.filter { $0.isRemoteHome }
        for parent in builder.listedParents() where !parent.home {
            projects.append(parent)
            projects += builder.children(of: parent.id)
        }
        return rankKeepingOrder(projects, key: { builder.title($0) }, query: query, limit: .max).map { entry in
            let project = entry.item
            var item = PaletteItem(id: project.id.description, title: builder.title(project), target: .run { [weak self] in
                guard let self else { return }
                self.model.connectOnDemand(project.serverId)
                self.model.newTerminal(in: project.id)
            })
            item.highlights = entry.ranges
            item.subtitle = displayPath(project)
            item.disabled = project.status != .available
            item.kind = project.parentId == nil ? PaletteKind.project.rawValue : PaletteKind.worktree.rawValue
            item.tile = project.parentId == nil ? PaletteKind.project.tile : PaletteKind.worktree.tile
            return item
        }
    }

    // MARK: Themes

    private func themeItems(_ query: String) -> [PaletteItem] {
        let entries = model.theme.catalog.entries
        let currentName = model.theme.currentThemeName
        return rankKeepingOrder(entries, key: \.name, query: query, limit: .max).map { entry in
            let theme = entry.item
            var item = PaletteItem(id: theme.name, title: theme.name, target: .apply { [weak self] in
                self?.model.setTheme(theme.name)
            })
            item.highlights = entry.ranges
            item.current = theme.name == currentName
            item.kind = PaletteKind.theme.rawValue
            let scheme = theme.scheme
            let colors = [scheme.background, scheme.palette[1], scheme.palette[2], scheme.palette[3]].compactMap { $0?.nsColor }
            item.tile = PaletteTile(.swatches(colors), .none)
            return item
        }
    }

    private func customCommandItems(_ query: String) -> [PaletteItem] {
        let keymap = model.settings.keymap
        return rankKeepingOrder(model.settings.commands, key: \.name, query: query, limit: .max).map { entry in
            let command = entry.item
            var item = PaletteItem(id: command.id, title: command.name, target: .run { [weak self] in self?.runCustom(command) })
            item.highlights = entry.ranges
            item.subtitle = command.command
            item.shortcut = keymap.binding(command.shortcutId)
            item.kind = PaletteKind.command.rawValue
            item.tile = PaletteCategory.custom.tile
            return item
        }
    }

    // MARK: Open Project

    var searchRoot: String {
        TabDirs.expandHome(model.settings.projects.searchRoot ?? "~")
    }

    private var remoteFolders: [ServerId: (path: String, folders: Loadable<[ServerPath]>)] = [:]

    private func loadRemoteFolders(_ server: ServerId, path: String?) {
        model.connectOnDemand(server)
        guard let connection = model.connections[server], let main = connection.main else {
            waitingForFolders.insert(server)
            remoteFolders[server] = (path ?? "", .loading)
            return
        }
        waitingForFolders.remove(server)
        let home = model.state.serverHome(server)?.directory.rawValue ?? "/"
        let target = path ?? home
        remoteFolders[server] = (target, .loading)
        Task {
            do {
                let list = try await main.listFolders(ServerPath(target))
                guard connection.main === main, remoteFolders[server]?.path == target else { return }
                remoteFolders[server] = (target, .loaded(list))
            } catch {
                guard connection.main === main, remoteFolders[server]?.path == target else { return }
                remoteFolders[server] = (target, .failed(error.message))
            }
            palette?.refresh()
        }
    }

    private func addProjectContent(_ server: ServerId, _ query: String) -> PageContent {
        if !server.isLocal { return remoteAddProjectContent(server, query) }
        var sections: [PaletteSection] = []
        let typedPath = query.hasPrefix("/") || query.hasPrefix("~")
        var folderItems: [PaletteItem] = []
        if typedPath {
            folderItems = FolderBrowse.items(query).map { folderItem($0, ranges: []) }
        } else if !query.isEmpty {
            folderItems = rankKeepingOrder(folders.found, key: { ($0 as NSString).lastPathComponent }, query: query, limit: 100)
                .map { entry in
                    folderItem(entry.item, ranges: entry.ranges)
                }
        }
        if folderItems.isEmpty {
            let hint = query.isEmpty ? "Type to search folders, or enter a path"
                : (folders.searching && !typedPath ? "Searching…" : "No folders match “\(query)”")
            var placeholder = PaletteItem(id: "hint", title: hint, target: .apply {})
            placeholder.disabled = true
            folderItems = [placeholder]
        }
        sections.append(PaletteSection("Folders", folderItems))
        var choose = PaletteItem(id: "choose", title: "Choose in Finder…", target: .run { [weak self] in self?.chooseInFinder() })
        choose.tile = .icon(.folder, .gray)
        var location = PaletteItem(id: "location", title: "Change Search Location…", target: .run { [weak self] in
            self?.changeSearchLocation()
        })
        location.subtitle = (TabDirs.abbreviateHome(searchRoot, home: NSHomeDirectory()) ?? searchRoot) + "/"
        location.tile = .icon(.search, .gray)
        sections.append(PaletteSection("More", [choose, location]))
        return PageContent(sections: sections)
    }

    private func folderItem(_ path: String, ranges: [Range<Int>]) -> PaletteItem {
        let name = (path as NSString).lastPathComponent
        var item = PaletteItem(id: path, title: name, target: .run { [weak self] in self?.model.addProject(path) })
        item.highlights = ranges
        item.subtitle = TabDirs.abbreviateHome((path as NSString).deletingLastPathComponent, home: NSHomeDirectory())
        item.kind = PaletteKind.folder.rawValue
        item.tile = PaletteKind.folder.tile
        item.actions = [
            PaletteItemAction("open", "Open Project"),
            PaletteItemAction("add", "Add Project"),
            PaletteItemAction("reveal", "Reveal in Finder"),
            PaletteItemAction("copy", "Copy Path"),
            PaletteItemAction("parent", "Go to Parent Folder", keepOpen: true),
        ]
        return item
    }

    private func remoteAddProjectContent(_ server: ServerId, _ query: String) -> PageContent {
        guard let entry = remoteFolders[server] else { return .loading("Connecting…") }
        switch entry.folders {
        case .loading: return .loading("Loading folders…")
        case .failed(let message): return .error(message)
        case .loaded(let list):
            let needle = Fuzzy.normalize(query)
            var items: [PaletteItem] = []
            var here = PaletteItem(id: entry.path, title: "Add “\((entry.path as NSString).lastPathComponent)”", target: .run { [weak self] in
                self?.model.addProject(entry.path, server: server)
            })
            here.subtitle = entry.path
            here.tile = .icon(.plus, .pink)
            items.append(here)
            if entry.path != "/" {
                var up = PaletteItem(id: "..", title: "..", target: .apply { [weak self] in
                    self?.loadRemoteFolders(server, path: (entry.path as NSString).deletingLastPathComponent)
                })
                up.tile = .icon(.folder, .gray)
                items.append(up)
            }
            for folder in list {
                let name = folder.lastComponent
                guard let match = Fuzzy.match(name, needle) else { continue }
                let path = folder.isAbsolute ? folder.rawValue : (entry.path as NSString).appendingPathComponent(folder.rawValue)
                var item = PaletteItem(id: path, title: name, target: .apply { [weak self] in
                    self?.loadRemoteFolders(server, path: path)
                    self?.palette?.setQuery("")
                })
                item.highlights = match.ranges
                item.kind = PaletteKind.folder.rawValue
                item.tile = PaletteKind.folder.tile
                item.actions = [PaletteItemAction("browse", "Open Folder"), PaletteItemAction("add", "Add Project")]
                items.append(item)
            }
            return PageContent(sections: [PaletteSection(entry.path, items)])
        }
    }

    func complete(_ page: PalettePage, query: String, item: String?) -> String? {
        guard case .addProject(let server) = page, server.isLocal else { return nil }
        if let item, item.hasPrefix("/") {
            return (TabDirs.abbreviateHome(item, home: NSHomeDirectory()) ?? item) + "/"
        }
        return FolderBrowse.complete(query)
    }

    private func chooseInFinder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: searchRoot)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addProject(url.path)
    }

    private func changeSearchLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Search Here"
        panel.directoryURL = URL(fileURLWithPath: searchRoot)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var settings = model.settings
        do {
            try settings.setProjectSearchRoot(TabDirs.abbreviateHome(url.path, home: NSHomeDirectory()) ?? url.path, in: model.dirs.settings)
            model.apply(settings: settings)
        } catch {
            model.report(error)
        }
        palette?.push(.addProject(.local))
    }

    // MARK: Actions

    func perform(_ page: PalettePage, item raw: String, action: String) {
        let item = raw.split(separator: "/", maxSplits: 1).count == 2 && page == .root
            ? String(raw.split(separator: "/", maxSplits: 1)[1]) : raw
        let tag = raw.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        let target: PalettePage = page == .root
            ? (tag == "files" ? .files : tag == "branches" ? .branches(current.id) : tag == "worktrees" ? .worktrees(current.parentId ?? current.id) : page)
            : page
        switch target {
        case .files: fileAction(item, action)
        case .branches(let project):
            if action == "switch" { switchBranch(project, item) }
            if action == "delete" { runGit(project, .deleteLocalBranch(name: item, force: false), done: "Deleted \(item)") }
            branches[project] = nil
            loadBranches(project)
        case .changes(let project): changeAction(project, item, action)
        case .worktrees:
            guard let id = UUID(uuidString: item).map({ ProjectId(uuid: $0) }) else { return }
            switch action {
            case "open": model.selectProject(id); palette?.close()
            case "rename": palette?.close(); actions?.rename(project: id, anchor: nil)
            case "remove": palette?.close(); model.confirmRemoveWorktree(id)
            default: break
            }
        case .addProject(let server):
            if server.isLocal { folderAction(item, action) } else if action == "add" {
                model.addProject(item, server: server)
                palette?.close()
            } else {
                loadRemoteFolders(server, path: item)
            }
        default:
            break
        }
    }

    private func fileAction(_ path: String, _ action: String) {
        let project = current
        let absolute = (project.directory.rawValue as NSString).appendingPathComponent(path)
        switch action {
        case "open":
            palette?.close()
            model.openEditor(project: project.id, path: path)
        case "reveal": NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolute)])
        case "copy": copy(absolute)
        case "copy-relative": copy(path)
        default: break
        }
    }

    private func changeAction(_ project: ProjectId, _ item: String, _ action: String) {
        let parts = item.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let path = String(parts[1])
        let staged = parts[0] == "Staged"
        let request: GitAction
        switch action {
        case "diff":
            palette?.close()
            model.openDiff(project: project, path: path, staged: staged)
            return
        case "stage": request = .stage([ServerPath(path)])
        case "unstage": request = .unstage([ServerPath(path)])
        case "discard": request = .discard([ServerPath(path)])
        default: return
        }
        guard let side = model.sideClient(for: project) else { return }
        Task {
            do {
                _ = try await side.git(GitRequest(project: project, action: request))
                model.gitChanged(project)
            } catch {
                model.report(error.message)
            }
            loadChanges(project)
        }
    }

    private func folderAction(_ path: String, _ action: String) {
        switch action {
        case "open":
            palette?.close()
            model.addProject(path)
        case "add":
            let shown = model.currentProject.id
            if model.addProject(path) != nil, model.state.project(shown) != nil { model.selectProject(shown) }
            palette?.close()
        case "reveal": NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case "copy": copy(path)
        case "parent":
            let parent = (path as NSString).deletingLastPathComponent
            palette?.setQuery((TabDirs.abbreviateHome(parent, home: NSHomeDirectory()) ?? parent) + "/")
        default: break
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.presenter?.showToast("Copied", error: false)
    }
}
