import Darwin
import Foundation
import TabCore
import TabProtocol
import XCTest
@testable import TabClient
@testable import TabServer

/// Exercises session and control event delivery over pipes without Unix sockets.
final class SessionEventDeliveryTests: XCTestCase {
    func testPrintfMetadataAndProgressReachAnAttachedClient() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dirs = TabDirs(root: root)
        try WireJSON.encode(ServerSettingsDoc(defaultShell: "/bin/bash", shellIntegration: false))
            .write(to: dirs.serverSettings)
        let server = try Server(configuration: ServerConfiguration(dirs: dirs, uploads: root.appendingPathComponent("uploads")))
        defer {
            server.endAllSessions()
            server.closeConnections()
        }
        var upstream: [Int32] = [0, 0]
        var downstream: [Int32] = [0, 0]
        guard pipe(&upstream) == 0 else { throw POSIXError(.EIO) }
        guard pipe(&downstream) == 0 else {
            close(upstream[0])
            close(upstream[1])
            throw POSIXError(.EIO)
        }
        let serverStream = try FileDescriptorStream(readDescriptor: upstream[0], writeDescriptor: downstream[1])
        let clientStream = try FileDescriptorStream(readDescriptor: downstream[0], writeDescriptor: upstream[1])
        defer {
            serverStream.close()
            clientStream.close()
        }
        server.accept(stream: serverStream, origin: .local)
        let client = try await ServerClient.connect(stream: clientStream, kind: .desktop)
        defer { client.close() }
        let output = "\u{07}\u{1b}]52;c;aGVsbG8=\u{07}\u{1b}]2;Metadata fixture\u{07}"
            + "\u{1b}[?1000h\u{1b}[?1004h\u{1b}[?1007h\u{1b}[?1h\u{1b}[?2004h\u{1b}[6 q"
            + "\u{1b}]9;4;1;42\u{07}"
        let escaped = output.utf8.map { String(format: "\\0%03o", $0) }.joined()
        let home = try await client.catalogPage().home
        let session = try await client.createSession(CreateSession(project: home, directory: ServerPath(root.path),
            size: Size(cols: 80, rows: 24), command: "read ready; printf '%b' '\(escaped)'; sleep 30"))
        let attachment = try await client.attach(session: session.id, size: Size(cols: 80, rows: 24))
        try await client.syncSessionReferences(sessions: [session.id])
        let metadata = expectation(description: "attached metadata and frame")
        let progress = expectation(description: "control progress")
        var inputModes = InputModes()
        inputModes.mouseTracking = true
        inputModes.focusEvents = true
        let expectedInputModes = inputModes
        let channelReader = Task {
            var seen = Set<MetadataEvent>()
            var modes = false
            for await event in attachment.events {
                if case .metadata(let value) = event { seen.insert(value) }
                if case .frame(let frame) = event {
                    modes = modes || (frame.modes.applicationCursorKeys && frame.modes.bracketedPaste)
                    try? client.ack(channel: attachment.channel, seq: frame.seq)
                }
                if modes && seen.isSuperset(of: [.bell, .clipboardWrite("hello"), .title("Metadata fixture"),
                    .cursorBlinking(false), .inputModes(expectedInputModes)]) {
                    metadata.fulfill()
                    return
                }
            }
        }
        let controlReader = Task {
            for await event in client.events {
                if case .progress(let id, let value) = event, id == session.id,
                   value.progress?.state == .running, value.progress?.percent == 42 {
                    progress.fulfill()
                    return
                }
            }
        }
        defer {
            channelReader.cancel()
            controlReader.cancel()
        }
        try client.sendRaw(channel: attachment.channel, Data("ready\r".utf8))
        await fulfillment(of: [metadata, progress], timeout: 8)
        try await client.endSession(session.id)
    }
}
