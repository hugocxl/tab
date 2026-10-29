import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabClient

// TEMPORARY QA probe; removed before finishing.
final class QAProbeTests: XCTestCase {
    func testProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["QA_TAB_DIR"], let sessionText = env["QA_SESSION"],
              let session = SessionId(string: sessionText) else { throw XCTSkip("probe") }
        let seconds = Double(env["QA_SECONDS"] ?? "3") ?? 3
        let server = LocalServer(dirs: TabDirs(root: URL(fileURLWithPath: dir)), executable: nil)
        let client = try await server.connect(kind: .desktop, start: false)
        defer { client.close() }
        let cols = UInt16(env["QA_COLS"] ?? "80") ?? 80
        let attachment = env["QA_NORESIZE"] != nil ? try await client.attachWithoutResize(session: session)
            : try await client.attach(session: session, size: Size(cols: cols, rows: 24))
        var grid = RunGrid(snapshot: attachment.snapshot)
        print("QA snapshot prompts=\(attachment.snapshot.prompts) process=\(String(describing: attachment.process)) graphics=\(String(describing: attachment.snapshot.graphics))")
        if let input = env["QA_INPUT"] {
            try client.sendRaw(channel: attachment.channel, Data(input.replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\e", with: "\u{1B}").utf8))
        }
        if env["QA_CLEAR"] != nil { try client.clear(channel: attachment.channel) }
        let deadline = Date().addingTimeInterval(seconds)
        let task = Task {
            for await event in attachment.events {
                switch event {
                case .frame(let frame):
                    grid.apply(frame)
                    try? client.ack(channel: attachment.channel, seq: frame.seq)
                    print("QA frame seq=\(frame.seq) reset=\(frame.reset) rows=\(frame.rows.map(\.index)) graphics=\(frame.graphics.map { "images=\($0.images.count) placements=\($0.placements.count)" } ?? "nil")")
                case .metadata(let event):
                    print("QA meta \(event)")
                case .ended(let reason): print("QA ended \(reason)")
                case .resized(let size): print("QA resized \(size)")
                }
                if Date() > deadline { break }
            }
        }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        task.cancel()
        print("QA screen:\n" + grid.screenText(lines: 24))
        try? await client.detach(channel: attachment.channel)
    }
}
