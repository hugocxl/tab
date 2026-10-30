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
        session = URLSession(configuration: configuration, delegate: UpdateRedirectPolicy(), delegateQueue: nil)
    }

    public init(session: URLSession) {
        self.session = session
    }

    /// The newest release that replaces this build, if any, across `feedURLs`.
    /// A feed that can't be read or trusted only fails the check when every
    /// feed fails.
    public func latest(
        current: String = Release.version,
        feedURLs: [URL] = UpdateFeed.urls,
        signingKey: Data? = UpdateFeed.signingKey
    ) async throws -> UpdateManifest? {
        var newest: UpdateManifest?
        var failure: Error?
        var answered = false
        for url in feedURLs {
            do {
                let manifest = try UpdateFeed.parse(try await feed(url), current: current, signedBy: signingKey)
                answered = true
                guard let manifest else { continue }
                if let known = newest, !ReleaseVersion.isNewer(manifest.version, than: known.version) { continue }
                newest = manifest
            } catch {
                // A feed that can't be trusted says more than one that can't be reached.
                if failure == nil || (Self.isTransport(failure) && !Self.isTransport(error)) { failure = error }
            }
        }
        if !answered, let failure { throw failure }
        return newest
    }

    private func feed(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try Self.checkStatus(response)
        var data = Data()
        for try await byte in bytes {
            guard data.count < UpdateFeed.maximumFeedSize else { throw UpdateError.invalidFeed("The update feed is too large") }
            data.append(byte)
        }
        return data
    }

    /// Streams a bounded release into `directory`, then verifies its size
    /// and checksum. No partial or rejected download is kept.
    public func download(_ manifest: UpdateManifest, into directory: URL) async throws -> URL {
        let destination = directory.appendingPathComponent("update." + manifest.url.pathExtension.lowercased())
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: destination) } }
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw UpdateError.download("Could not create the download file")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: manifest.url))
        defer { bytes.task.cancel() }
        try Self.checkStatus(response)
        let limit = min(manifest.size ?? UpdateFeed.maximumDownloadSize, UpdateFeed.maximumDownloadSize)
        var count: Int64 = 0
        var buffer = Data()
        for try await byte in bytes {
            count += 1
            guard count <= limit else { throw UpdateError.sizeMismatch }
            buffer.append(byte)
            if buffer.count == 65_536 {
                try output.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try output.write(contentsOf: buffer)
        try output.synchronize()
        try Self.verify(destination, sha256: manifest.sha256, size: manifest.size)
        complete = true
        return destination
    }

    /// Checks a downloaded file against its expected size and SHA-256.
    public static func verify(_ file: URL, sha256 expected: String, size: Int64?) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let actualSize = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        if let size, actualSize != size { throw UpdateError.sizeMismatch }
        guard actualSize <= UpdateFeed.maximumDownloadSize else { throw UpdateError.sizeMismatch }
        guard !expected.isEmpty else {
            guard size != nil else { throw UpdateError.checksumMismatch }
            return
        }
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

    private static func isTransport(_ error: Error?) -> Bool {
        guard let error = error as? UpdateError else { return true }
        if case .download = error { return true }
        return false
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError.download("the server answered \(http.statusCode)")
        }
    }
}

/// GitHub redirects assets to its CDN; HTTPS downloads must stay HTTPS.
private final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard task.originalRequest?.url?.scheme != "https" || request.url?.scheme == "https" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
