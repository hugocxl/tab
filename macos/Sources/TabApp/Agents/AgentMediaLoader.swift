import AppKit
import ImageIO
import TabCore

/// Loads the media of one conversation's assistant messages. A source is requested
/// only while some view observes it; observers of the same source share one request,
/// the request is cancelled when the last observer leaves, and a failure is forgotten
/// then so the next appearance retries. Loaded media stay in a least-recently-used
/// cache bounded by `costLimit` bytes.
@MainActor
final class AgentMediaLoader {
    /// Bytes and, for images, a decoded preview bounded to `previewPixels`.
    struct Entry {
        var data: Data
        var mimeType: String
        var image: NSImage?
        /// The original pixel size, which bounds the tile: images are never upscaled.
        var pixelSize: CGSize?
        var cost: Int { data.count + Int((image?.size.width ?? 0) * (image?.size.height ?? 0) * 4) }
    }

    enum State {
        case loading
        case loaded(Entry)
        case failed(String)
        /// A web image the remote-image setting holds back; `clickable` when a click loads it.
        case blocked(host: String, clickable: Bool)

        var entry: Entry? { if case .loaded(let entry) = self { return entry }; return nil }
        var isLoading: Bool { if case .loading = self { return true }; return false }
    }

    typealias Observer = @MainActor (State) -> Void
    /// Fetches an http(s) URL: its bytes and the response MIME type.
    typealias RemoteFetch = @Sendable (URL, Int) async throws -> (data: Data, mimeType: String?)
    /// Resolves a project file through the conversation's project server.
    typealias WorkspaceMedia = @MainActor (String) async throws -> AgentConversationFileActions.Media

    nonisolated static let maximumDataURIBytes = 16 * 1024 * 1024
    nonisolated static let maximumMediaBytes = 16 * 1024 * 1024
    static let previewPixels = 1200

    var fetchRemote: RemoteFetch = { url, limit in try await AgentMediaLoader.urlSessionFetch(url, limit: limit) }
    /// Unset, project files fail to load.
    var workspaceMedia: WorkspaceMedia?
    /// The least-recently-used cache bound, in bytes of data and decoded pixels.
    var costLimit = 64 * 1024 * 1024 { didSet { evict() } }
    /// Whether web images load: the user's setting, read at each request.
    var remotePolicy: () -> RemoteImagePolicy = { AgentSettings().remoteImages }
    /// Web sources the user clicked to load in this conversation.
    private var approvedRemote: Set<String> = []
    private var blockedMedia: [String: AgentMarkdownMedia] = [:]

    /// Requests started over the loader's lifetime.
    private(set) var requestCount = 0
    private var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var observers: [String: [Int: Observer]] = [:]
    private var recency: [String] = []
    private(set) var cachedCost = 0
    private var nextObserver = 0

    func state(for source: String) -> State? {
        guard let state = states[source] else { return nil }
        if case .loaded = state { touch(source) }
        return state
    }

    /// Reports the current state now and every later change, starting the request
    /// when the source is neither cached nor loading.
    func observe(_ media: AgentMarkdownMedia, _ observer: @escaping Observer) -> AgentLazyRequestObservation {
        let key = media.source
        nextObserver += 1
        let id = nextObserver
        observers[key, default: [:]][id] = observer
        let observation = AgentLazyRequestObservation { [weak self] in self?.release(key, observer: id) }
        if let state = state(for: key) {
            observer(state)
            return observation
        }
        if let blocked = blockedState(media) {
            blockedMedia[key] = media
            observer(blocked)
            return observation
        }
        start(media)
        if let state = states[key] { observer(state) }
        return observation
    }

    /// The loaded media, waiting for a request when needed; cancelling the calling
    /// task releases its share of the request.
    func entry(for media: AgentMarkdownMedia) async throws -> Entry {
        if let entry = state(for: media.source)?.entry { return entry }
        // Asking for the bytes, as opening a preview does, is the click that loads it.
        if case .blocked(_, let clickable)? = blockedState(media) {
            guard clickable else { throw ModelError("Loading web images is turned off in Settings → Privacy.") }
            approvedRemote.insert(media.source)
        }
        let box = ObservationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Entry, Error>) in
                var resumed = false
                box.observation = observe(media) { [box] state in
                    guard !resumed else { return }
                    switch state {
                    case .loading: return
                    case .loaded(let entry): resumed = true; continuation.resume(returning: entry)
                    case .failed(let message): resumed = true; continuation.resume(throwing: ModelError(message))
                    case .blocked: resumed = true; continuation.resume(throwing: ModelError("Loading web images is turned off in Settings → Privacy."))
                    }
                    // The observation may not be stored yet when a cached state reports synchronously.
                    Task { @MainActor in box.observation?.cancel(); box.observation = nil }
                }
                box.onCancel = {
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: CancellationError())
                }
                if Task.isCancelled { box.cancel() }
            }
        } onCancel: {
            Task { @MainActor in box.cancel() }
        }
    }

    /// Whether `media` is a web image the setting holds back now.
    func blockedState(_ media: AgentMarkdownMedia) -> State? {
        guard case .remote(let url)? = AgentMediaSource(media.source), !approvedRemote.contains(media.source) else { return nil }
        switch remotePolicy() {
        case .always: return nil
        case .clickToLoad: return .blocked(host: url.host ?? url.absoluteString, clickable: true)
        case .never: return .blocked(host: url.host ?? url.absoluteString, clickable: false)
        }
    }

    /// The user clicked to load a held-back web image: views waiting on it start loading.
    func approve(_ source: String) {
        guard remotePolicy() != .never else { return }
        approvedRemote.insert(source)
        guard let media = blockedMedia.removeValue(forKey: source), observers[source]?.isEmpty == false, states[source] == nil else { return }
        start(media)
        if let state = states[source] { for observer in observers[source].map({ Array($0.values) }) ?? [] { observer(state) } }
    }

    /// Forgets every result and cancels every request, for another conversation.
    func reset() {
        approvedRemote.removeAll()
        blockedMedia.removeAll()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        states.removeAll()
        observers.removeAll()
        recency.removeAll()
        cachedCost = 0
    }

    private func start(_ media: AgentMarkdownMedia) {
        let key = media.source
        requestCount += 1
        states[key] = .loading
        let fetchRemote = fetchRemote, workspaceMedia = workspaceMedia
        tasks[key] = Task { [weak self] in
            let result: State
            do { result = .loaded(try await Self.load(media, fetchRemote: fetchRemote, workspaceMedia: workspaceMedia)) }
            catch is CancellationError { return }
            catch { result = .failed(error.message) }
            guard !Task.isCancelled, let self else { return }
            self.finish(key, result)
        }
    }

    private func finish(_ key: String, _ result: State) {
        tasks[key] = nil
        guard observers[key]?.isEmpty == false else {
            // Nobody waits any more: keep a success for later, never a failure.
            states[key] = nil
            if case .loaded(let entry) = result { store(key, entry) }
            return
        }
        if case .loaded(let entry) = result { store(key, entry) } else { states[key] = result }
        for observer in observers[key].map({ Array($0.values) }) ?? [] { observer(result) }
    }

    private func store(_ key: String, _ entry: Entry) {
        states[key] = .loaded(entry)
        cachedCost += entry.cost
        touch(key)
        evict()
    }

    private func touch(_ key: String) {
        if let index = recency.lastIndex(of: key) { recency.remove(at: index) }
        recency.append(key)
    }

    private func evict() {
        while cachedCost > costLimit, recency.count > 1 {
            let key = recency.removeFirst()
            if case .loaded(let entry)? = states[key] {
                cachedCost -= entry.cost
                states[key] = nil
            }
        }
    }

    private func release(_ key: String, observer id: Int) {
        observers[key]?[id] = nil
        guard observers[key]?.isEmpty != false else { return }
        observers[key] = nil
        switch states[key] {
        case .loading?:
            tasks.removeValue(forKey: key)?.cancel()
            states[key] = nil
        case .failed?: states[key] = nil
        default: break
        }
    }

    // MARK: Loading

    private static func load(_ media: AgentMarkdownMedia, fetchRemote: RemoteFetch, workspaceMedia: WorkspaceMedia?) async throws -> Entry {
        guard let source = AgentMediaSource(media.source) else { throw ModelError("This media link is not supported.") }
        let data: Data, mimeType: String
        switch source {
        case .data(let raw):
            let decoded = try await Task.detached(priority: .userInitiated) { try decodeDataURI(raw) }.value
            (data, mimeType) = (decoded.data, decoded.mimeType)
        case .remote(let url):
            let fetched = try await fetchRemote(url, maximumMediaBytes)
            guard fetched.data.count <= maximumMediaBytes else { throw ModelError("This media is larger than 16 MiB.") }
            (data, mimeType) = (fetched.data, fetched.mimeType ?? media.mimeType)
        case .file(let path):
            guard let workspaceMedia else { throw ModelError("Project files are unavailable in this conversation.") }
            let file = try await workspaceMedia(path)
            data = try await read(file.resource)
            mimeType = file.mimeType
        }
        try Task.checkCancellation()
        guard media.kind == .image else { return Entry(data: data, mimeType: mimeType) }
        guard let decoded = await decode(data) else { throw ModelError("Image unavailable") }
        try Task.checkCancellation()
        return Entry(data: data, mimeType: mimeType, image: decoded.image, pixelSize: decoded.pixelSize)
    }

    /// Reads a whole ranged resource in bounded chunks.
    static func read(_ resource: AgentConversationRangedResource) async throws -> Data {
        guard resource.length <= UInt64(maximumMediaBytes) else { throw ModelError("This media is larger than 16 MiB.") }
        var data = Data()
        data.reserveCapacity(Int(resource.length))
        while UInt64(data.count) < resource.length {
            try Task.checkCancellation()
            let length = UInt32(min(UInt64(AgentConversationRangedResource.chunkSize), resource.length - UInt64(data.count)))
            let chunk = try await resource.read(UInt64(data.count), length)
            guard chunk.count == Int(length) else { throw ModelError("The media changed while it was read.") }
            data.append(chunk)
        }
        return data
    }

    /// A preview bounded to `previewPixels`, decoded off the main thread, and the
    /// original pixel size.
    static func decode(_ data: Data) async -> (image: NSImage, pixelSize: CGSize?)? {
        let size = await Task.detached(priority: .userInitiated) { () -> CGSize? in
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
                  width > 0, height > 0 else { return nil }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }.value
        guard let image = await AgentAttachmentImporter.previewImage(data: data, pixels: previewPixels) else { return nil }
        return (image, size ?? image.size)
    }

    /// The bytes and MIME type of a `data:` URI, at most `maximumDataURIBytes`.
    nonisolated static func decodeDataURI(_ raw: String) throws -> (data: Data, mimeType: String) {
        guard let mime = AgentMediaSource.dataMIMEType(raw), let comma = raw.firstIndex(of: ",") else {
            throw ModelError("This data URI is malformed.")
        }
        let header = raw[raw.startIndex..<comma].lowercased()
        let payload = raw[raw.index(after: comma)...]
        let data: Data?
        if header.hasSuffix(";base64") {
            guard payload.utf8.count <= (maximumDataURIBytes / 3 + 1) * 4 + 4096 else { throw ModelError("This image is larger than 16 MiB.") }
            data = Data(base64Encoded: payload.filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters)
        } else {
            guard payload.utf8.count <= maximumDataURIBytes * 3 else { throw ModelError("This image is larger than 16 MiB.") }
            data = String(payload).removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, !data.isEmpty else { throw ModelError("This data URI is malformed.") }
        guard data.count <= maximumDataURIBytes else { throw ModelError("This image is larger than 16 MiB.") }
        return (data, mime)
    }

    /// No cookies, credentials or shared caches; every request times out after 20 s.
    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    nonisolated static func urlSessionFetch(_ url: URL, limit: Int) async throws -> (data: Data, mimeType: String?) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw ModelError("Only web media can be fetched.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("image/*, video/*, audio/*;q=0.8", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelError("The media server did not return the file.")
        }
        guard http.expectedContentLength <= Int64(limit) else { throw ModelError("This media is larger than 16 MiB.") }
        var data = Data()
        data.reserveCapacity(max(0, Int(http.expectedContentLength)))
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw ModelError("This media is larger than 16 MiB.") }
        }
        return (data, http.mimeType)
    }
}

/// Holds one awaiting observation so cancellation can end it from outside.
@MainActor
private final class ObservationBox {
    var observation: AgentLazyRequestObservation?
    var onCancel: (() -> Void)?

    func cancel() {
        let cancel = onCancel
        onCancel = nil
        cancel?()
        observation?.cancel()
        observation = nil
    }
}
