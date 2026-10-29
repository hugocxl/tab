import AppKit
import TabClient
import TabCore
import XCTest
@testable import TabApp

/// Exercises the remote controllers without showing a window or starting the app.
@MainActor
final class RemoteServersSnapshotTests: XCTestCase {
    func testRenderRemoteControllers() async throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_REMOTE_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TAB_REMOTE_SNAPSHOT_DIR to render remote controllers")
        }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let askpass = AskpassServer(socket: root.appendingPathComponent("unused.sock"), program: "/usr/bin/false")
        let host = FakeRemoteHost(settingsURL: root.appendingPathComponent("unused-settings.json"))
        let model = RemoteServersModel(entries: [], askpass: askpass, host: host)
        let controller = RemoteServersController(model: model)
        let empty = HostMenuView(controller: controller)
        try render(empty, size: NSSize(width: 300, height: empty.fittingSize.height), root: root, name: "hosts-empty")
        XCTAssertTrue(labels(empty).contains("No remote servers yet."))
        XCTAssertTrue(labels(empty).contains("Add Server…"))

        let build = ServerEntry(name: "Build Mac", ssh: "builder@build.example", port: 2222, group: "Work")
        let dev = ServerEntry(name: "Development", ssh: "me@dev.example", passwordLogin: true, group: "Work")
        let home = ServerEntry(name: "Home Mac", ssh: "home", group: "Personal")
        let vm = ServerEntry(name: "VM", ssh: "", sshCommand: "/usr/local/bin/vm ssh dev --")
        model.sync([build, dev, home, vm])
        host.snapshots[build.id] = RemoteConnectionSnapshot(state: .connected)
        host.snapshots[home.id] = RemoteConnectionSnapshot(.reconnecting(attempt: 2), failure: .disconnected)
        let hosts = HostMenuView(controller: controller)
        try render(hosts, size: NSSize(width: 300, height: hosts.fittingSize.height), root: root, name: "hosts-grouped")
        model.selection.tick(build.id, range: false, shown: model.listedIDs)
        model.selection.tick(home.id, range: true, shown: model.listedIDs)
        let pane = controller.makePane()
        try render(pane.view, size: NSSize(width: 1100, height: 720), root: root, name: "servers-selected")
        try render(pane.view, size: NSSize(width: 740, height: 640), root: root, name: "servers-narrow")
        XCTAssertEqual(pane.view.bounds.width, 740)
        let search = try XCTUnwrap(descendant(SearchField.self, in: pane.view))
        let header = try XCTUnwrap(search.superview)
        search.stringValue = "build"
        search.onChange?(search.stringValue)
        XCTAssertTrue(search.superview === header, "refreshing results must keep the search field in place")
        XCTAssertEqual(model.selection.ids, [build.id])
        search.stringValue = ""
        search.onChange?(search.stringValue)

        let add = ServerFormSheet(controller: controller, editing: nil)
        try renderSheet(add, root: root, name: "server-add")
        let password = ServerFormSheet(controller: controller, editing: dev.id)
        try renderSheet(password, root: root, name: "server-password")
        let custom = ServerFormSheet(controller: controller, editing: vm.id)
        try renderSheet(custom, root: root, name: "server-custom")
        let prompt = PasswordSheet(name: dev.name, wrong: true) { _ in }
        try renderSheet(prompt, root: root, name: "password-refused")

        let folders = RemoteFolderBrowser(serverName: dev.name, start: "/Users/me", list: { _ in
            ["/Users/me/Applications", "/Users/me/code", "/Users/me/Documents"]
        }, choose: { _ in })
        try await Task.sleep(nanoseconds: 30_000_000)
        try render(folders, size: NSSize(width: 480, height: 420), root: root, name: "remote-folders")

        let proxy = ProxySheet(model: ProxyModel(file: root.appendingPathComponent("unused-proxy.json")), oldServer: false) { _ in }
        proxy.window.isReleasedWhenClosed = false
        proxy.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        try capture(try XCTUnwrap(proxy.window.contentView), root: root, name: "proxy-setup")
        proxy.window.close()
        let proxyModel = ProxyModel(file: root.appendingPathComponent("proxy-fixture.json"))
        defer { try? FileManager.default.removeItem(at: proxyModel.file) }
        try proxyModel.save(ProxySettings(kind: .socks5, host: "127.0.0.1", port: 1080, username: "me",
                                         password: "synthetic-password", bypass: "localhost, .example.com", global: true))
        let socks = ProxySheet(model: proxyModel, oldServer: false) { _ in }
        socks.window.isReleasedWhenClosed = false
        socks.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        try capture(try XCTUnwrap(socks.window.contentView), root: root, name: "proxy-socks5-global")
        socks.window.close()
    }

    private func labels(_ view: NSView) -> [String] {
        let text = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return text + view.subviews.flatMap(labels)
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let found = view as? T { return found }
        return view.subviews.compactMap { descendant(type, in: $0) }.first
    }

    private func renderSheet(_ sheet: SheetWindow, root: URL, name: String) throws {
        sheet.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        sheet.layoutIfNeeded()
        sheet.fitContent()
        try capture(try XCTUnwrap(sheet.contentView), root: root, name: name)
        sheet.close()
    }

    private func render(_ view: NSView, size: NSSize, root: URL, name: String) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        let background = ThemedBackground { $0.bg }
        background.addSubview(view)
        view.pinEdges(to: background)
        window.contentView = background
        window.setContentSize(size)
        try capture(background, root: root, name: name)
        window.close()
    }

    private func capture(_ view: NSView, root: URL, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: root.appendingPathComponent(name + ".png"))
    }
}
