import Foundation
import TabClient
import TabCore
import TabProtocol

// The `tab` command line tool. See `CLIHelp.root` for the commands.

if let status = AskpassServer.runIfRequested() {
    exit(status)
}

do {
    try await CLI.run(Array(CommandLine.arguments.dropFirst()))
    exit(0)
} catch {
    CLI.fail(error)
}
