import AppKit
import TabApp
import TabClient
import TabCore

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

let folder = SingleInstance.folder(in: CommandLine.arguments)
let instance: ProfileLock
do {
    guard let claimed = try SingleInstance.claim(folder: folder, dirs: dirs) else { exit(0) }
    instance = claimed
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}

withExtendedLifetime(instance) {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate(dirs: dirs, folder: folder)
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
