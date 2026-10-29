import Darwin
import Foundation
import TabServer

// `tabd --socket PATH --settings PATH --log PATH`, with `TAB_DIR` selecting
// the profile folder. Started detached by the app or the CLI.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("tabd: \(message)\n".utf8))
    exit(code)
}

let configuration: ServerConfiguration
do {
    configuration = try ServerConfiguration.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error)", code: 2)
}

do {
    try FileManager.default.createDirectory(at: configuration.dirs.root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try ServerLog.open(configuration.log)
} catch {
    fail("cannot open the log: \(error)", code: 1)
}

do {
    let server = try Server(configuration: configuration)
    let git = GitService(projects: server, events: server)
    server.install(ServerServices(
        git: git,
        worktreeGuard: git.operationGuard,
        files: FilesService(projects: server, events: server),
        detector: AgentDetector(),
        remote: RemoteAccess(dirs: configuration.dirs, server: server.info, events: server)))
    try server.run()
} catch let error as ServerStartError {
    ServerLog.error("\(error)")
    if case .alreadyRunning = error { fail("\(error)", code: 0) }
    fail("\(error)", code: 1)
} catch {
    ServerLog.error("server failed: \(error)")
    fail("\(error)", code: 1)
}
