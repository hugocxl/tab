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
            timeout: 5, limit: 65_536
        )
        return try JSONDecoder().decode(BuildInfo.self, from: output.stdout)
    }

    /// Both executables must describe the same release and protocol set.
    /// Older servers without build metadata fall back to their version;
    /// the matching CLI supplies the release's protocol set.
    static func check(in directory: URL, version: String) throws -> BuildInfo {
        let client = try read(directory.appendingPathComponent(Executable.cli))
        guard client.version == version, !client.protocolVersions.isEmpty else {
            throw UpdateError.invalidBundle("The bundled client and server do not match the release.")
        }
        let executable = directory.appendingPathComponent(Executable.server)
        if let server = try? read(executable) {
            guard client == server else {
                throw UpdateError.invalidBundle("The bundled client and server do not match the release.")
            }
            return server
        }
        let output = try BoundedProcess.run(
            program: executable.path, arguments: ["--version"],
            environment: ProcessInfo.processInfo.environment, directory: directory.path,
            timeout: 5, limit: 65_536
        )
        guard String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "tabd \(version)" else {
            throw UpdateError.invalidBundle("The bundled client and server do not match the release.")
        }
        return client
    }
}
