import CryptoKit
import Foundation
import TabProtocol

/// A CLI a vendor publishes as a manifest of its latest release, `{version, url, sha512}`, such
/// as Antigravity's. Tab installs it the way the provider source's AntigravityInstallation.ts
/// does: download, check the SHA-512 the manifest names, unpack, and only then put it in place.
enum AgentProviderRelease {
    struct Manifest: Equatable, Sendable {
        var version: String
        var url: URL
        var sha512: String
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// The manifest for this Mac, which is always Apple silicon.
    static func manifestURL(_ template: String) -> URL? {
        URL(string: template.replacingOccurrences(of: "{target}", with: "darwin_arm64"))
    }

    /// Where Tab keeps the releases it installs, one folder per version.
    static func versionsDirectory(_ spec: AgentProviderSpec, home: URL) -> URL {
        home.appendingPathComponent(".local/share/\(spec.executable ?? "agent")-cli/versions", isDirectory: true)
    }

    /// Where the command goes, a folder on agents' `PATH`.
    static func linkURL(_ spec: AgentProviderSpec, home: URL) -> URL {
        home.appendingPathComponent(".local/bin/\(spec.executable ?? "agent")")
    }

    /// A manifest only names a release on Google's own storage, as a full SHA-512.
    static func parse(_ data: Data) -> Manifest? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              let link = json["url"] as? String, let url = URL(string: link), url.scheme == "https",
              url.host == "storage.googleapis.com",
              let sha512 = json["sha512"] as? String,
              sha512.range(of: "^[0-9a-fA-F]{128}$", options: .regularExpression) != nil else { return nil }
        return Manifest(version: version, url: url, sha512: sha512.lowercased())
    }

    static func manifest(_ url: URL) async throws -> Manifest {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
        guard (response as? HTTPURLResponse)?.statusCode == 200, let manifest = parse(data) else {
            throw Failure(message: "The release manifest at \(url.host ?? "its server") couldn't be read.")
        }
        return manifest
    }

    /// Installs the latest release of `spec` and links its command. Returns what it did, line by line.
    static func install(_ spec: AgentProviderSpec, executableInArchive: String = "antigravity",
                        home: URL = URL(fileURLWithPath: NSHomeDirectory())) async throws -> String {
        guard let template = spec.releaseManifest, let url = manifestURL(template) else {
            throw Failure(message: "\(spec.name) publishes no release Tab can install.")
        }
        let manifest = try await manifest(url)
        var log = ["\(spec.name) \(manifest.version) from \(manifest.url.absoluteString)"]
        let (download, response) = try await URLSession.shared.download(for: URLRequest(url: manifest.url, timeoutInterval: 600))
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: "Downloading \(spec.name) failed with status \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        let digest = try await runBlocking { try sha512(of: download) }
        guard digest == manifest.sha512 else {
            throw Failure(message: "The download's SHA-512 doesn't match the manifest's, so it wasn't installed.")
        }
        log.append("SHA-512 matches the manifest.")
        let versions = versionsDirectory(spec, home: home)
        let target = versions.appendingPathComponent(manifest.version, isDirectory: true)
        let binary = target.appendingPathComponent(executableInArchive)
        if !FileManager.default.isExecutableFile(atPath: binary.path) {
            let staging = versions.appendingPathComponent(".\(manifest.version)-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let output = try await runBlocking {
                try ProcessRunner.run("/usr/bin/tar", ["-xzf", download.path, "-C", staging.path], timeout: 300)
            }
            guard output.succeeded else { throw Failure(message: "Unpacking \(spec.name) failed: \(output.stderrText)") }
            let unpacked = staging.appendingPathComponent(executableInArchive)
            guard FileManager.default.isExecutableFile(atPath: unpacked.path) else {
                throw Failure(message: "The \(spec.name) download has no \(executableInArchive) to run.")
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: staging, to: target)
        }
        try link(binary, at: linkURL(spec, home: home))
        log.append("Installed in \(target.path) and linked as \(linkURL(spec, home: home).path).")
        return log.joined(separator: "\n")
    }

    /// Points `link` at `binary`, replacing only a link, never a file someone else put there.
    static func link(_ binary: URL, at link: URL) throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try? FileManager.default.attributesOfItem(atPath: link.path) {
            guard existing[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw Failure(message: "\(link.path) already exists and isn't a link, so Tab left it as it is.")
            }
            try FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
    }

    static func sha512(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA512()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
