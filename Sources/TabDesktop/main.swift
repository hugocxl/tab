import AppKit
import TabApp
import TabClient
import TabCore

// Proxy tunnel, askpass and server-host runs answer and exit before any UI starts.
if let status = ProxyTunnel.runIfRequested() {
    exit(status)
}
if let status = AskpassServer.runIfRequested() {
    exit(status)
}
if CommandLine.arguments.dropFirst().first == ServerHost.flag {
    exit(ServerHost.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
}

let dirs: TabDirs
do {
    dirs = try TabDirs.profile()
} catch {
    FileHandle.standardError.write(Data("Tab: \(error)\n".utf8))
    exit(1)
}

// One app per profile: hand the folder to the running one.
let folder = SingleInstance.folder(in: CommandLine.arguments)
if SingleInstance.handOver(folder: folder, dirs: dirs) {
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(dirs: dirs, folder: folder)
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
