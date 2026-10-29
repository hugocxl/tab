import CryptoKit
import Foundation
import TabCore

/// Fetches the feed and the release, through a session the app configures
/// (with its proxy when the proxy is used for the whole app).
public struct UpdateDownloader: Sendable {
    public let session: URLSession

    /// - Parameter configuration: such as one carrying the app's proxy.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpAdditionalHeaders = (configuration.httpAdditionalHeaders ?? [:])
            .merging(["User-Agent": "Tab/\(Release.version)"]) { _, new in new }
        session = URLSession(configuration: configuration)
    }

    public init(session: URLSession) {
        self.session = session
    }

    /// The release that replaces this build, if any.
    public func latest(current: String = Release.version) async throws -> UpdateManifest? {
        var request = URLRequest(url: UpdateFeed.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
        try Self.checkStatus(response)
        return try UpdateFeed.parse(data, current: current)
    }

    /// Downloads the release into `directory` and verifies its size and
    /// checksum; a file that fails is removed.
    public func download(_ manifest: UpdateManifest, into directory: URL) async throws -> URL {
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(for: URLRequest(url: manifest.url))
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
        let destination = directory.appendingPathComponent("update." + manifest.url.pathExtension.lowercased())
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateError.download(error.localizedDescription)
        }
        do {
            try Self.checkStatus(response)
            try Self.verify(destination, sha256: manifest.sha256, size: manifest.size)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// Checks a downloaded file against its expected size and SHA-256.
    public static func verify(_ file: URL, sha256 expected: String, size: Int64?) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let actualSize = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        if let size, actualSize != size { throw UpdateError.sizeMismatch }
        guard actualSize <= UpdateFeed.maximumDownloadSize else { throw UpdateError.sizeMismatch }
        guard try sha256(of: file) == expected.lowercased() else { throw UpdateError.checksumMismatch }
    }

    /// The file's SHA-256 as lowercase hex, read in chunks.
    public static func sha256(of file: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError.download("the server answered \(http.statusCode)")
        }
    }
}
