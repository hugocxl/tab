import Foundation
import TabProtocol

/// Where a session delivers one attachment's events: a connection's outbox
/// for one channel. Calls come from the session's queue.
protocol SessionSink: AnyObject, Sendable {
    /// The attach request's reply. Returns false when nobody receives it.
    func attached(_ snapshot: AttachSnapshot, process: ForegroundProcess?) -> Bool
    /// Returns false once the channel is gone.
    func frame(_ frame: ScreenFrame) -> Bool
    func metadata(_ event: MetadataEvent) -> Bool
    func resized(_ size: Size) -> Bool
    /// The session ended; the channel closes.
    func ended(_ reason: ExitReason)
    /// The attach failed before a snapshot.
    func failed(_ error: ErrorReply)
}

/// What a session tells the server about itself.
protocol SessionOwnerDelegate: AnyObject, Sendable {
    func sessionMetadataChanged(_ session: SessionId, _ metadata: SessionMetadata)
    func sessionProgressChanged(_ session: SessionId, _ progress: SessionProgress)
    /// The program ended and the last save finished (`saved` when it succeeded).
    func sessionFinished(_ owner: SessionOwner, reason: ExitReason, saved: Bool)
}

/// A screen that passes `SavedScreen.validate()`: one row per line, runs
/// within the width, the cursor inside.
enum ScreenShape {
    static func rows(_ rows: [Row], size: Size) -> [Row] {
        var shaped = (0..<Int(size.rows)).map { Row(index: UInt16($0), runs: []) }
        for row in rows where Int(row.index) < shaped.count {
            shaped[Int(row.index)].runs = fit(row.runs, cols: size.cols)
        }
        return shaped
    }

    static func fit(_ runs: [Run], cols: UInt16) -> [Run] {
        var used = 0
        var kept: [Run] = []
        for run in runs where run.width > 0 {
            guard used + Int(run.width) <= Int(cols) else { break }
            used += Int(run.width)
            kept.append(run)
        }
        return kept
    }

    static func cursor(_ cursor: Cursor, size: Size) -> Cursor {
        var cursor = cursor
        cursor.row = min(cursor.row, size.rows &- 1)
        cursor.col = min(cursor.col, size.cols &- 1)
        return cursor
    }
}
