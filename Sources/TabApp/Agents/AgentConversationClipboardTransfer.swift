import AppKit
import CoreFoundation

/// Source-sized PNGs cross the local WK bridge in bounded chunks. No pasteboard
/// mutation occurs until every byte arrived and the complete PNG validates.
@MainActor
final class AgentConversationClipboardTransfer {
    private final class Pending {
        let url: URL
        let handle: FileHandle
        let length: UInt64
        let flavors: [String: String]
        var activity = Date()
        var received: UInt64 = 0
        init(length: UInt64, flavors: [String: String]) throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("tab-clipboard-" + UUID().uuidString)
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ModelError("The image clipboard transfer could not start.")
            }
            handle = try FileHandle(forWritingTo: url)
            self.length = length; self.flavors = flavors
        }
        deinit { try? handle.close(); try? FileManager.default.removeItem(at: url) }
    }
    private var pending: [String: Pending] = [:]
    private let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func cancel() { pending.removeAll() }

    func handle(_ payload: [String: Any]) throws -> Any {
        pending = pending.filter { Date().timeIntervalSince($0.value.activity) < 120 }
        guard let phase = payload["phase"] as? String else {
            try AgentConversationClipboard.write(payload, to: pasteboard); return true
        }
        if phase == "begin" {
            guard pending.count < 2, let length = Self.integer(payload["byteLength"]), length > 0,
                  let flavors = payload["flavors"] as? [String: String], flavors.count <= 8,
                  flavors.reduce(0, { $0 + $1.value.utf8.count }) <= AgentConversationClipboard.maximumBytes else {
                throw ModelError("Invalid image clipboard transfer metadata.")
            }
            let id = UUID().uuidString
            pending[id] = try Pending(length: length, flavors: flavors)
            return id
        }
        guard let id = payload["transferId"] as? String, let transfer = pending[id] else {
            throw ModelError("This image clipboard transfer expired.")
        }
        do {
            switch phase {
            case "chunk":
                guard let offset = Self.integer(payload["offset"]), offset == transfer.received,
                      let encoded = payload["dataBase64"] as? String, encoded.utf8.count <= 349_528,
                      let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 256 * 1024,
                      UInt64(bytes.count) <= transfer.length - transfer.received else {
                    throw ModelError("Invalid image clipboard chunk.")
                }
                try transfer.handle.write(contentsOf: bytes)
                transfer.received += UInt64(bytes.count)
                transfer.activity = Date()
                return true
            case "commit":
                defer { pending.removeValue(forKey: id) }
                guard transfer.received == transfer.length else { throw ModelError("The image clipboard transfer is incomplete.") }
                try transfer.handle.close()
                let bytes = try Data(contentsOf: transfer.url, options: .mappedIfSafe)
                guard UInt64(bytes.count) == transfer.length else { throw ModelError("The image clipboard transfer changed.") }
                try AgentConversationClipboard.write(["flavors": transfer.flavors], to: pasteboard, pngBytes: bytes)
                return true
            case "abort": pending.removeValue(forKey: id); return true
            default: throw ModelError("Unsupported image clipboard transfer phase.")
            }
        } catch { pending.removeValue(forKey: id); throw error }
    }

    private static func integer(_ value: Any?) -> UInt64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= 9_007_199_254_740_991,
              value.doubleValue.rounded(.towardZero) == value.doubleValue else { return nil }
        return value.uint64Value
    }
}
