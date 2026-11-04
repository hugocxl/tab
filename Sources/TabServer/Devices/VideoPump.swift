import Foundation
import TabProtocol

/// Sends one channel's device screen under the outbox's one-frame credit:
/// a frame is encoded only when the channel has credit, and a screen that
/// drew meanwhile is only marked dirty, so the next credit encodes the
/// screen as it is then. The encoder sees only frames it sends, so P-frames
/// stay valid when a slow client gets fewer of them. Idle screens send
/// nothing. Everything runs on `queue`.
final class VideoPump: @unchecked Sendable {
    let channel: ChannelId
    private let queue: DispatchQueue
    private let outbox: Outbox
    /// Encodes the screen now; a keyframe when asked. `nil` skips it.
    private let encode: (_ keyframe: Bool) throws -> VideoFrame?
    /// The round trip of each acknowledged frame, to adapt the bitrate.
    private let acknowledged: (TimeInterval) -> Void
    private var dirty = false
    private var needsKeyframe = true
    private var seq: UInt32 = 0
    private var sentAt: Date?
    private var stopped = false
    /// Frames wait until the client knows the channel, after the attach reply.
    private var began = false

    init(channel: ChannelId, queue: DispatchQueue, outbox: Outbox,
         encode: @escaping (_ keyframe: Bool) throws -> VideoFrame?,
         acknowledged: @escaping (TimeInterval) -> Void = { _ in }) {
        self.channel = channel
        self.queue = queue
        self.outbox = outbox
        self.encode = encode
        self.acknowledged = acknowledged
    }

    /// Opens the channel's video lane; call once before frames.
    func open() {
        outbox.openVideo(channel) { [weak self] in
            guard let self else { return }
            queue.async { self.creditReturned() }
        }
    }

    /// The screen drew; `keyframe` when the next frame must start over,
    /// such as after a new surface or a client's request.
    func screenChanged(keyframe: Bool = false) {
        queue.async { [self] in
            dirty = true
            if keyframe { needsKeyframe = true }
            pump()
        }
    }

    /// The attach reply is queued: frames may follow it.
    func begin() {
        queue.async { [self] in
            began = true
            dirty = true
            needsKeyframe = true
            pump()
        }
    }

    func stop() {
        queue.async { [self] in stopped = true }
    }

    private func creditReturned() {
        if let sentAt {
            acknowledged(Date().timeIntervalSince(sentAt))
            self.sentAt = nil
        }
        pump()
    }

    private func pump() {
        guard began, !stopped, dirty, outbox.hasVideoCredit(channel) else { return }
        dirty = false
        let keyframe = needsKeyframe
        let frame: VideoFrame?
        do {
            frame = try encode(keyframe)
        } catch {
            ServerLog.error("device frame not encoded: \(error)")
            return
        }
        guard var frame else { return }
        if frame.keyframe { needsKeyframe = false }
        seq &+= 1
        frame.seq = seq
        sentAt = Date()
        if !outbox.push(video: frame, on: channel) { sentAt = nil }
    }
}
