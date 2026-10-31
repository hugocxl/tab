import AppKit
import Darwin
import WebKit

/// WKDownload owns the immutable Blob already fetched by the source renderer.
/// A destination is exposed only after its complete bytes arrive successfully.
@MainActor
final class AgentConversationDownloadDelegate: NSObject, WKDownloadDelegate {
    var onFailure: ((Error) -> Void)?
    var chooseDestination: ((String) async -> URL?)?
    var onFinished: ((URL) -> Void)?
    private struct Pending {
        var download: WKDownload
        var destination: URL?
        var temporary: URL?
        var panel: NSSavePanel?
        var decision: Task<Void, Never>?
    }
    private var pending: [ObjectIdentifier: Pending] = [:]
    private var generation: UInt64 = 0

    func cancelAll() {
        generation &+= 1
        let values = Array(pending.values)
        pending.removeAll()
        for value in values {
            value.decision?.cancel()
            value.panel?.cancel(nil)
            value.download.cancel(nil)
            if let temporary = value.temporary { try? FileManager.default.removeItem(at: temporary) }
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let id = ObjectIdentifier(download), current = generation
        let name = (suggestedFilename as NSString).lastPathComponent
        pending[id] = Pending(download: download)
        pending[id]?.decision = Task { [weak self] in
            guard let self else { completionHandler(nil); return }
            let target: URL?
            if let chooseDestination = self.chooseDestination { target = await chooseDestination(name.isEmpty ? "Download" : name) }
            else {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name.isEmpty ? "Download" : name
                panel.canCreateDirectories = true
                self.pending[id]?.panel = panel
                target = await withCheckedContinuation { continuation in
                    panel.begin { result in continuation.resume(returning: result == .OK ? panel.url : nil) }
                }
            }
            guard !Task.isCancelled, self.generation == current, let target, target.isFileURL,
                  self.pending[id] != nil else { self.pending.removeValue(forKey: id); completionHandler(nil); return }
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".tab-download-" + UUID().uuidString)
            self.pending[id]?.destination = target
            self.pending[id]?.temporary = temporary
            self.pending[id]?.panel = nil
            self.pending[id]?.decision = nil
            completionHandler(temporary)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let value = pending.removeValue(forKey: ObjectIdentifier(download)),
              let temporary = value.temporary, let destination = value.destination else { return }
        guard rename(temporary.path, destination.path) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            try? FileManager.default.removeItem(at: temporary)
            onFailure?(error); return
        }
        onFinished?(destination)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let value = pending.removeValue(forKey: ObjectIdentifier(download)) else { return }
        value.decision?.cancel(); value.panel?.cancel(nil)
        if let temporary = value.temporary { try? FileManager.default.removeItem(at: temporary) }
        if (error as NSError).code != NSURLErrorCancelled { onFailure?(error) }
    }
}
