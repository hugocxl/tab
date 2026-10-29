import Foundation
import TabCore
import TabProtocol

/// Reads release metadata without starting a server or connecting to one.
enum BundledBuild {
    static func read(_ executable: URL) throws -> BuildInfo {
        let output = try BoundedProcess.run(
            program: executable.path, arguments: ["--build-info"],
            environment: ProcessInfo.processInfo.environment,
            directory: executable.deletingLastPathComponent().path,
            timeout: 5, limit: 65_536, cancellation: AICancellation()
        )
        return try JSONDecoder().decode(BuildInfo.self, from: output.stdout)
    }

    /// Both executables must describe the same release and protocol set.
    static func check(in directory: URL, version: String) throws -> BuildInfo {
        let client = try read(directory.appendingPathComponent(Executable.cli))
        let server = try read(directory.appendingPathComponent(Executable.server))
        guard client == server, server.version == version, !server.protocolVersions.isEmpty else {
            throw UpdateError.invalidBundle("The bundled client and server do not match the release.")
        }
        return server
    }
}
