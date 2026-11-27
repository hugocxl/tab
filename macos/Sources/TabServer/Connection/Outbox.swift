import Foundation
import TabProtocol

/// What a connection's writer sends next: control messages first, then
/// channel messages, then at most one screen frame in flight per channel,
/// then at most one simulator video frame in flight per channel, then tunnel
/// bytes. A screen frame that can't go yet merges into the waiting one, so a
/// slow client never piles up frames; a simulator encodes only when its channel
/// has credit; tunnels send only what their reader granted.
final class Outbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var control: [Message] = []
    private var controlHead = 0
    private var channelMessages: [ChannelId: [SessionMessage]] = [:]
    private var frames: [ChannelId: ScreenFrame] = [:]
    /// Channels whose last frame was acknowledged (or that got none yet).
    private var credit: [ChannelId: Bool] = [:]
    private var sent: [ChannelId: UInt64] = [:]
    private var videos: [ChannelId: VideoLane] = [:]
    /// Tunnel bytes and the messages ordered with them, by channel.
    private var streams: [ChannelId: [StreamItem]] = [:]
    /// Tunnels that may still queue; a closed one drains what it queued.
    private var openStreams: Set<ChannelId> = []
    private var lastStream = ChannelId(0)

    private struct VideoLane {
        var credit = true
        var waiting: VideoFrame?
        var sent: UInt32?
        /// Runs off the lock when the client acknowledged the last frame.
        var onCredit: @Sendable () -> Void
    }

    private enum StreamItem {
        case bytes(Data)
        case message(SessionMessage)
    }
    private var closed = false
    /// Sends what is queued for control, then ends.
    private var finishing = false

    var isClosed: Bool { condition.withLock { closed } }

    // MARK: Control

    func push(_ message: Message) {
        condition.withLock {
            guard !closed, !finishing else { return }
            if coalesce(message) { return }
            control.append(message)
            condition.signal()
        }
    }

    /// Replaces a queued message the new one makes stale.
    private func coalesce(_ message: Message) -> Bool {
        guard case .event(let event) = message else { return false }
        for index in controlHead..<control.count {
            guard case .event(let queued) = control[index] else { continue }
            switch (queued, event) {
            case (.changed(let topic, let old), .changed(let newTopic, let revision)) where topic == newTopic:
                control[index] = .event(.changed(topic: topic, revision: max(old, revision)))
                return true
            case (.agentChatChanged(let session, let old), .agentChatChanged(let newSession, let revision))
                where session == newSession:
                control[index] = .event(.agentChatChanged(session: session, revision: max(old, revision)))
                return true
            case (.sessionMetadata(let session, _), .sessionMetadata(let newSession, _)) where session == newSession,
                 (.progress(let session, _), .progress(let newSession, _)) where session == newSession:
                control[index] = message
                return true
            case (.gitChanged(let project), .gitChanged(let newProject)) where project == newProject:
                return true
            case (.filesChanged(let project, var changes), .filesChanged(let newProject, let newChanges))
                where project == newProject && changes.root == newChanges.root:
                changes.merge(newChanges)
                control[index] = .event(.filesChanged(project: project, changes: changes))
                return true
            default:
                continue
            }
        }
        return false
    }

    /// Drops queued metadata and progress events of sessions this client no longer shows.
    func dropSessionEvents(keeping sessions: Set<SessionId>) {
        condition.withLock {
            control.removeSubrange(controlHead..<control.count, where: { message in
                guard case .event(let event) = message else { return false }
                switch event {
                case .sessionMetadata(let session, _), .progress(let session, _): return !sessions.contains(session)
                default: return false
                }
            })
        }
    }

    // MARK: Channels

    func openChannel(_ channel: ChannelId) {
        condition.withLock {
            guard !closed else { return }
            credit[channel] = true
        }
    }

    /// Stops a channel's frames; `flush` still sends its queued messages,
    /// such as `ended`.
    func closeChannel(_ channel: ChannelId, flush: Bool = false) {
        condition.withLock {
            credit[channel] = nil
            frames[channel] = nil
            sent[channel] = nil
            if !flush { channelMessages[channel] = nil }
        }
    }

    /// Queues a message on an open channel; false once it is closed.
    @discardableResult
    func push(_ message: SessionMessage, on channel: ChannelId) -> Bool {
        condition.withLock {
            guard !closed, credit[channel] != nil || videos[channel] != nil || openStreams.contains(channel) else {
                return false
            }
            var queued = channelMessages[channel] ?? []
            if let index = queued.firstIndex(where: { Self.sameKind($0, message) }) {
                if case .credit(let old) = queued[index], case .credit(let new) = message {
                    queued[index] = .credit(old &+ new)
                } else {
                    queued[index] = message
                }
            } else {
                queued.append(message)
            }
            channelMessages[channel] = queued
            condition.signal()
            return true
        }
    }

    private static func sameKind(_ lhs: SessionMessage, _ rhs: SessionMessage) -> Bool {
        switch (lhs, rhs) {
        case (.resized, .resized): true
        case (.credit, .credit): true
        case (.metadata(let old), .metadata(let new)):
            switch (old, new) {
            case (.title, .title), (.directory, .directory), (.foregroundProcess, .foregroundProcess),
                 (.history, .history), (.inputModes, .inputModes), (.cursorBlinking, .cursorBlinking),
                 (.links, .links), (.screenPrompts, .screenPrompts), (.clipboardWrite, .clipboardWrite):
                true
            default: false
            }
        default: false
        }
    }

    /// Queues a frame, merging it into one still waiting; false once the channel is closed.
    func push(_ frame: ScreenFrame, on channel: ChannelId) -> Bool {
        condition.withLock {
            guard !closed, credit[channel] != nil else { return false }
            if var waiting = frames[channel] {
                waiting.merge(frame)
                frames[channel] = waiting
            } else {
                frames[channel] = frame
            }
            condition.signal()
            return true
        }
    }

    /// The client drew frame `seq`; the next one may go.
    func ack(_ seq: UInt64, on channel: ChannelId) {
        let onCredit: (@Sendable () -> Void)? = condition.withLock {
            if var lane = videos[channel] {
                guard lane.sent.map(UInt64.init) == seq, !lane.credit, lane.waiting == nil else { return nil }
                lane.credit = true
                lane.sent = nil
                videos[channel] = lane
                return lane.onCredit
            }
            guard sent[channel] == seq, credit[channel] == false else { return nil }
            credit[channel] = true
            condition.signal()
            return nil
        }
        onCredit?()
    }

    // MARK: Simulator video

    /// Opens a simulator channel; `onCredit` runs whenever the client
    /// acknowledged the frame in flight, so the simulator may encode the next.
    func openVideo(_ channel: ChannelId, onCredit: @escaping @Sendable () -> Void) {
        condition.withLock {
            guard !closed else { return }
            videos[channel] = VideoLane(onCredit: onCredit)
        }
    }

    /// Whether a frame may be encoded for `channel` now.
    func hasVideoCredit(_ channel: ChannelId) -> Bool {
        condition.withLock { videos[channel]?.credit == true && !closed }
    }

    /// Queues an encoded frame; false without credit or once closed.
    @discardableResult
    func push(video frame: VideoFrame, on channel: ChannelId) -> Bool {
        condition.withLock {
            guard !closed, var lane = videos[channel], lane.credit else { return false }
            lane.credit = false
            lane.waiting = frame
            videos[channel] = lane
            condition.signal()
            return true
        }
    }

    /// Stops a simulator channel; `flush` still sends its queued messages.
    func closeVideo(_ channel: ChannelId, flush: Bool = false) {
        condition.withLock {
            videos[channel] = nil
            if !flush { channelMessages[channel] = nil }
        }
    }

    // MARK: Tunnels

    func openStream(_ channel: ChannelId) {
        condition.withLock {
            guard !closed else { return }
            openStreams.insert(channel)
        }
    }

    /// Queues tunnel bytes, in order with `push(streamMessage:)`.
    @discardableResult
    func push(stream data: Data, on channel: ChannelId) -> Bool {
        pushStream(.bytes(data), on: channel)
    }

    /// Queues a message that must follow the bytes queued before it, such
    /// as `streamEnd`.
    @discardableResult
    func push(streamMessage message: SessionMessage, on channel: ChannelId) -> Bool {
        pushStream(.message(message), on: channel)
    }

    private func pushStream(_ item: StreamItem, on channel: ChannelId) -> Bool {
        condition.withLock {
            guard !closed, openStreams.contains(channel) else { return false }
            streams[channel, default: []].append(item)
            condition.signal()
            return true
        }
    }

    /// Stops queuing on a tunnel; `flush` still sends what it queued.
    func closeStream(_ channel: ChannelId, flush: Bool = false) {
        condition.withLock {
            openStreams.remove(channel)
            if !flush {
                streams[channel] = nil
                channelMessages[channel] = nil
            }
        }
    }

    // MARK: Writer

    /// Blocks until something can be sent; `nil` once closed.
    func next() -> Data? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if controlHead < control.count {
                let message = control[controlHead]
                controlHead += 1
                if controlHead > 256, controlHead * 2 > control.count {
                    control.removeFirst(controlHead)
                    controlHead = 0
                }
                if let data = encode({ try FrameEncoder.encode(message) }) { return data }
                continue
            }
            if closed || finishing { return nil }
            if let channel = channelMessages.keys.min(), var queued = channelMessages[channel], !queued.isEmpty {
                let message = queued.removeFirst()
                channelMessages[channel] = queued.isEmpty ? nil : queued
                if let data = encode({ try FrameEncoder.encode(message, channel: channel) }) { return data }
                continue
            }
            if let channel = frames.keys.first(where: { credit[$0] == true }), let frame = frames.removeValue(forKey: channel) {
                credit[channel] = false
                sent[channel] = frame.seq
                if let data = encode({ try FrameEncoder.encode(screen: frame, channel: channel) }) { return data }
                credit[channel] = true
                continue
            }
            if let channel = videos.first(where: { $0.value.waiting != nil })?.key, var lane = videos[channel],
               let frame = lane.waiting {
                lane.waiting = nil
                lane.sent = frame.seq
                videos[channel] = lane
                if let data = encode({ try FrameEncoder.encode(video: frame, channel: channel) }) { return data }
                continue
            }
            if let channel = nextStream(), var queued = streams[channel], !queued.isEmpty {
                let item = queued.removeFirst()
                streams[channel] = queued.isEmpty ? nil : queued
                lastStream = channel
                let data: Data?
                switch item {
                case .bytes(let bytes): data = encode({ try FrameEncoder.encode(stream: bytes, channel: channel) })
                case .message(let message): data = encode({ try FrameEncoder.encode(message, channel: channel) })
                }
                if let data { return data }
                continue
            }
            condition.wait()
        }
    }

    /// The tunnel after the last one served, so one busy tunnel can't starve the rest.
    private func nextStream() -> ChannelId? {
        guard !streams.isEmpty else { return nil }
        return streams.keys.filter { $0 > lastStream }.min() ?? streams.keys.min()
    }

    private func encode(_ body: () throws -> Data) -> Data? {
        do {
            return try body()
        } catch {
            ServerLog.error("message not sent: \(error)")
            return nil
        }
    }

    /// Sends what is already queued on the control channel, then stops.
    func finish() {
        condition.withLock {
            finishing = true
            condition.broadcast()
        }
    }

    func close() {
        condition.withLock {
            closed = true
            control.removeAll()
            controlHead = 0
            channelMessages.removeAll()
            frames.removeAll()
            credit.removeAll()
            sent.removeAll()
            videos.removeAll()
            streams.removeAll()
            openStreams.removeAll()
            condition.broadcast()
        }
    }
}

extension ScreenFrame {
    /// Folds a newer frame in: its rows replace older ones, cursor and modes
    /// are the latest, and a reset starts over.
    mutating func merge(_ newer: ScreenFrame) {
        if newer.reset {
            let graphics = newer.graphics ?? self.graphics
            self = newer
            self.graphics = graphics
            return
        }
        var byIndex = Dictionary(rows.map { ($0.index, $0) }, uniquingKeysWith: { _, new in new })
        for row in newer.rows { byIndex[row.index] = row }
        rows = byIndex.keys.sorted().compactMap { byIndex[$0] }
        seq = newer.seq
        size = newer.size
        cursor = newer.cursor
        modes = newer.modes
        historyRows = newer.historyRows
        if newer.graphics != nil { graphics = newer.graphics }
    }
}

private extension Array {
    mutating func removeSubrange(_ range: Range<Int>, where shouldRemove: (Element) -> Bool) {
        let kept = self[range].filter { !shouldRemove($0) }
        replaceSubrange(range, with: kept)
    }
}
