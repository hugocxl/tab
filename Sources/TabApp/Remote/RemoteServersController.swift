import AppKit
import TabClient
import TabCore

/// The remote servers UI: the host menu popover, the server menus, the
/// Add/Edit Server dialog, the password prompt, the group name prompt, the
/// confirmations, and factories for the Remote Servers pane and the remote
/// folder browser. The shell makes one beside its `RemoteServersModel`.
@MainActor
public final class RemoteServersController {
    public let model: RemoteServersModel
    public var host: RemoteServersHost? { model.host }
    private weak var popover: NSPopover?
    private var formSheet: ServerFormSheet?
    private var passwordSheet: PasswordSheet?
    private var nameSheet: NamePromptSheet?

    public init(model: RemoteServersModel) {
        self.model = model
        model.askPassword = { [weak self] id in self?.askPassword(for: id) }
    }

    // MARK: Popover and host filter

    /// Shows the host menu popover above the sidebar footer button `anchor`,
    /// or closes it when it is open.
    public func toggleHostMenu(relativeTo anchor: NSView) {
        if let popover, popover.isShown {
            popover.close()
            return
        }
        let view = HostMenuView(controller: self)
        if let screen = anchor.window?.screen {
            view.maximumHeight = max(200, screen.visibleFrame.height - 120)
        }
        view.layoutSubtreeIfNeeded()
        let shown = PopoverHost.show(view, size: NSSize(width: HostMenuView.width, height: view.fittingSize.height),
                                     relativeTo: anchor, edge: .maxY)
        view.dismiss = { [weak shown] in shown?.close() }
        view.onSizeChange = { [weak shown] size in shown?.contentSize = size }
        popover = shown
    }

    /// The sidebar's host filter menu: All hosts, This Mac, each server,
    /// then Manage Remote Servers….
    public func hostFilterMenu(selected: SidebarHost, choose: @escaping (SidebarHost) -> Void) -> NSMenu {
        var builder = MenuBuilder()
        builder.add("All hosts", checked: selected == .all) { choose(.all) }
        builder.add("This Mac", checked: selected == .local) { choose(.local) }
        for server in model.listedIDs.compactMap(model.status(of:)) {
            builder.add(server.entry.name, checked: selected == .server(server.id)) { choose(.server(server.id)) }
        }
        builder.section()
        builder.add("Manage Remote Servers…") { [weak self] in self?.host?.showRemoteServersPane() }
        return builder.menu
    }

    // MARK: Menus

    /// The menu of one server; in the pane, a server among several ticked
    /// opens the menu of the ticked servers.
    public func serverMenu(_ id: ServerId, selection: Bool = false) -> NSMenu? {
        if selection && model.selection.count > 1 && model.selection.contains(id) {
            return selectionMenu()
        }
        guard let server = model.status(of: id) else { return nil }
        var builder = MenuBuilder()
        builder.add("New Terminal") { [weak self] in self?.host?.openRemoteHome(on: id) }
        builder.add("Add Project…") { [weak self] in self?.host?.addRemoteProject(on: id) }
        builder.section()
        addConnectionItems(&builder, [server])
        builder.add("Edit…") { [weak self] in self?.editServer(id) }
        builder.submenu("Move to Group", moveMenu([id]))
        if server.state == .connected {
            builder.section()
            builder.add("Restart Server…") { [weak self] in self?.confirmControl(id, restart: true) }
            builder.add("Stop Server…") { [weak self] in self?.confirmControl(id, restart: false) }
        }
        if server.missing && RemoteRelease.installableVersion != nil {
            builder.add("Install Tab…") { [weak self] in self?.confirmInstall(id) }
        }
        if server.incompatible && RemoteRelease.installableVersion != nil {
            builder.add("Copy Update Command") { [weak self] in self?.model.copyUpdateCommand() }
        }
        builder.section()
        builder.add("Forget…") { [weak self] in self?.confirmForget([id]) }
        return builder.menu
    }

    /// The menu of the servers ticked in the pane.
    public func selectionMenu() -> NSMenu? {
        let ids = model.listedIDs.filter(model.selection.contains)
        let members = ids.compactMap(model.status(of:))
        guard !members.isEmpty else { return nil }
        var builder = MenuBuilder()
        addConnectionItems(&builder, members)
        builder.submenu("Move to Group", moveMenu(ids))
        builder.section()
        builder.add(Self.forgetTitle(ids.count)) { [weak self] in self?.confirmForget(ids) }
        return builder.menu
    }

    /// A group's menu; the ungrouped servers can't be renamed or deleted.
    public func groupMenu(_ group: String?) -> NSMenu? {
        let ids = model.members(ofGroup: group)
        let members = ids.compactMap(model.status(of:))
        guard !members.isEmpty else { return nil }
        var builder = MenuBuilder()
        addConnectionItems(&builder, members)
        if let group {
            builder.section()
            builder.add("Rename Group…") { [weak self] in self?.renameGroup(group) }
            builder.add("Delete Group…") { [weak self] in self?.confirmDeleteGroup(group) }
        }
        builder.section()
        builder.add(Self.forgetTitle(ids.count)) { [weak self] in self?.confirmForget(ids) }
        return builder.menu
    }

    /// Move to Group's choices: each group, checked when it holds every one
    /// of `ids`, then No Group and New Group….
    public func moveMenu(_ ids: [ServerId]) -> NSMenu {
        let members = ids.compactMap(model.entry)
        let shared = { (group: String?) in members.allSatisfy { $0.group == group } }
        var builder = MenuBuilder()
        for group in model.groups {
            builder.add(group, checked: shared(group)) { [weak self] in self?.move(ids, to: group) }
        }
        builder.section()
        builder.add("No Group", checked: shared(nil)) { [weak self] in self?.move(ids, to: nil) }
        builder.add("New Group…") { [weak self] in self?.newGroup(for: ids) }
        return builder.menu
    }

    func showServerMenu(_ id: ServerId, in view: NSView, at point: NSPoint, selection: Bool = false) {
        serverMenu(id, selection: selection)?.popUp(positioning: nil, at: point, in: view)
    }

    func showGroupMenu(_ group: String?, in view: NSView, at point: NSPoint) {
        groupMenu(group)?.popUp(positioning: nil, at: point, in: view)
    }

    private func addConnectionItems(_ builder: inout MenuBuilder, _ members: [RemoteServerStatus]) {
        let choice = ConnectChoice(members)
        let ids = members.map(\.id)
        builder.add(choice.title) { [weak self] in
            switch choice {
            case .connect: self?.model.connect(ids)
            case .reconnect: self?.model.reconnect(ids)
            }
        }
        let live = members.filter(\.state.isLive).map(\.id)
        guard !live.isEmpty else { return }
        builder.add(live.count == 1 ? "Disconnect" : "Disconnect \(live.count) Servers") { [weak self] in
            self?.model.disconnect(live)
        }
    }

    static func forgetTitle(_ count: Int) -> String {
        count == 1 ? "Forget…" : "Forget \(count) Servers…"
    }

    // MARK: Actions

    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            host?.showRemoteError(error.localizedDescription)
        }
    }

    func move(_ ids: [ServerId], to group: String?) {
        attempt { try model.move(ids, toGroup: group) }
    }

    /// Names a new group and moves `ids` into it.
    public func newGroup(for ids: [ServerId]) {
        askName(title: "New Group", label: "Group name", value: "", confirm: "Move") { [weak self] name in
            self?.attempt { try self?.model.move(ids, toGroup: name) }
        }
    }

    public func renameGroup(_ group: String) {
        askName(title: "Rename Group", label: "Group name", value: group, confirm: "Rename") { [weak self] name in
            guard let self else { return }
            self.attempt { try self.model.regroup(self.model.members(ofGroup: group), as: name) }
        }
    }

    /// Asks, then deletes a group; its servers stay, ungrouped.
    public func confirmDeleteGroup(_ group: String) {
        ConfirmSheet.present(on: host?.remoteServersWindow, title: "Delete Group?",
                             message: "Delete “\(group)”? Its servers will not be removed.",
                             confirm: "Delete", destructive: true) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.attempt { try self.model.regroup(self.model.members(ofGroup: group), as: nil) }
        }
    }

    /// Asks once, then forgets every server in `ids`.
    public func confirmForget(_ ids: [ServerId]) {
        let names = ids.compactMap(model.entry).map(\.name)
        guard !names.isEmpty else { return }
        let single = names.count == 1
        ConfirmSheet.present(
            on: host?.remoteServersWindow,
            title: single ? "Forget \(names[0])?" : "Forget \(names.count) Servers?",
            message: single
                ? "Its projects and layouts leave this app; nothing on the server changes."
                : "Their projects and layouts leave this app; nothing on the servers changes.",
            confirm: "Forget", destructive: true
        ) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.attempt { try self.model.forget(ids) }
        }
    }

    /// Asks, then restarts or stops the server there.
    public func confirmControl(_ id: ServerId, restart: Bool) {
        guard let name = model.entry(id)?.name else { return }
        ConfirmSheet.present(
            on: host?.remoteServersWindow,
            title: restart ? "Restart the Server on \(name)?" : "Stop the Server on \(name)?",
            message: "All running terminal sessions on \(name) will end. Saved terminal output and settings will remain.",
            confirm: restart ? "Restart" : "Stop", destructive: true
        ) { [weak self] confirmed in
            if confirmed { self?.model.controlServer(id, restart: restart) }
        }
    }

    /// Asks, then installs this release there.
    public func confirmInstall(_ id: ServerId) {
        guard let name = model.entry(id)?.name, let version = RemoteRelease.installableVersion else { return }
        ConfirmSheet.present(on: host?.remoteServersWindow, title: "Install Tab \(version) on \(name)?",
                             message: RemoteInstall.description(version: version, destination: name),
                             confirm: "Install") { [weak self] confirmed in
            if confirmed { self?.model.install(id) }
        }
    }

    // MARK: Dialogs

    /// Opens the Add Server dialog, or Edit Server for `id`.
    public func editServer(_ id: ServerId?) {
        if let formSheet {
            formSheet.makeKeyAndOrderFront(nil)
            return
        }
        let sheet = ServerFormSheet(controller: self, editing: id)
        sheet.onClose = { [weak self] in
            self?.formSheet = nil
            self?.model.clearTest()
        }
        formSheet = sheet
        sheet.present(on: host?.remoteServersWindow)
    }

    /// Asks for the password of a server that logs in with one. It is kept
    /// in memory until Tab quits.
    public func askPassword(for id: ServerId) {
        guard passwordSheet == nil, let entry = model.entry(id) else { return }
        let wrong = model.status(of: id)?.failure == .authenticationFailed
        let sheet = PasswordSheet(name: entry.name, wrong: wrong) { [weak self] password in
            self?.passwordSheet = nil
            guard let password else { return }
            self?.model.setPassword(password, for: id)
        }
        passwordSheet = sheet
        sheet.present(on: host?.remoteServersWindow)
    }

    private func askName(title: String, label: String, value: String, confirm: String,
                         done: @escaping (String) -> Void) {
        guard nameSheet == nil else { return }
        let sheet = NamePromptSheet(title: title, label: label, value: value, confirm: confirm) { [weak self] name in
            self?.nameSheet = nil
            if let name { done(name) }
        }
        nameSheet = sheet
        sheet.present(on: host?.remoteServersWindow)
    }

    // MARK: Factories

    /// The Remote Servers pane's controller.
    public func makePane() -> RemoteServersPaneController {
        RemoteServersPaneController(controller: self)
    }

    /// A browser of `server`'s folders from `start` (its Home), for Add
    /// Project → Remote. `choose` gets the folder to add.
    public func makeFolderBrowser(server: ServerId, start: ServerPath,
                                  choose: @escaping (ServerPath) -> Void) -> RemoteFolderBrowser? {
        guard let name = model.entry(server)?.name else { return nil }
        let host = host
        return RemoteFolderBrowser(serverName: name, start: start, list: { path in
            guard let api = host?.remoteServerAPI(server) else { throw ClientError.disconnected }
            return try await api.listFolders(path)
        }, choose: choose)
    }
}
