import XCTest
@testable import TabProtocol

/// Tunnel and simulator traffic: its frames and messages round trip, and
/// readers that don't know a kind or a field still read the rest.
final class PaneTrafficTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try WireJSON.decode(T.self, from: try WireJSON.encode(value)), value, file: file, line: line)
    }

    func testStreamFramesCarryBytesOnTheirChannel() throws {
        let data = try FrameEncoder.encode(stream: Data([1, 2, 3]), channel: ChannelId(9))
        var reader = FrameReader()
        let frame = try XCTUnwrap(try reader.frames(from: data).first)
        XCTAssertEqual(try frame.decoded(), .stream(ChannelId(9), Data([1, 2, 3])))
        let control = Frame(kind: .stream, channel: .control, payload: Data([1]))
        XCTAssertThrowsError(try control.decoded(), "bytes never go on the control channel")
    }

    func testVideoFramesRoundTripWithParameterSetsOnlyOnKeyframes() throws {
        let key = VideoFrame(seq: 7, keyframe: true, turns: 1, width: 1170, height: 2532,
                             parameterSets: [Data([0x67, 1, 2]), Data([0x68, 3])], sample: Data([0, 0, 0, 1, 0x65]))
        XCTAssertEqual(try VideoFrame.decode(key.encoded()), key)
        let delta = VideoFrame(seq: 8, keyframe: false, width: 1170, height: 2532, parameterSets: [Data([9])],
                               sample: Data([0, 0, 0, 1, 0x41]))
        let decoded = try VideoFrame.decode(delta.encoded())
        XCTAssertEqual(decoded.parameterSets, [], "only keyframes carry parameter sets")
        XCTAssertEqual(decoded.sample, delta.sample)
        XCTAssertEqual(delta.encoded().prefix(VideoFrame.headerSize).count, 12)
        XCTAssertThrowsError(try VideoFrame.decode(Data([0, 0, 0, 1, 1, 0])), "a truncated header is malformed")
        var badTurns = key.encoded()
        badTurns[5] = 4
        XCTAssertThrowsError(try VideoFrame.decode(badTurns), "turns stay below a full circle")
        var videoReader = FrameReader()
        let frame = try XCTUnwrap(try videoReader.frames(from: FrameEncoder.encode(video: key, channel: ChannelId(4))).first)
        XCTAssertEqual(try frame.decoded(), .video(ChannelId(4), key))
    }

    func testTunnelAndSimulatorMessagesRoundTrip() {
        let simulator = SimulatorRef.iOS("A1B2")
        let requests: [RequestBody] = [
            .openTunnel(host: "localhost", port: 3000), .closeTunnel(ChannelId(3)), .listSimulators,
            .simulatorAction(simulator: simulator, action: .rotate(turns: -1)),
            .simulatorAction(simulator: .android("Pixel_8"), action: .input([.touch(x: 0.5, y: 0.25, down: true),
                                                                       .key(usage: 4, down: false), .button(.back)])),
            .simulatorAction(simulator: simulator, action: .type("hi")), .simulatorAction(simulator: simulator, action: .openURL("myapp://x")),
            .simulatorAction(simulator: simulator, action: .setHardwareKeyboard(false)),
            .attachSimulator(AttachSimulator(simulator: simulator, maxPixels: 2_000_000, codecs: [.hevc, .h264])),
            .detachSimulator(ChannelId(5)), .simulatorScreenshot(simulator),
        ]
        for request in requests { roundTrip(Message.request(RequestId(1), request)) }
        let replies: [ReplyBody] = [
            .tunnelOpened(channel: ChannelId(2)), .tunnelFailed(.refused), .tunnelClosed,
            .simulators([SimulatorInfo(simulator: simulator, name: "iPhone", runtime: "iOS 27.0", booted: true, buttons: [.home],
                                       hardwareKeyboardSwitch: true)]),
            .simulatorSettings(SimulatorSettings(booted: true, dark: false, orientation: .landscapeLeft)),
            .simulatorAttached(SimulatorStream(channel: ChannelId(6), codec: .h264, width: 600, height: 1300)),
            .simulatorDetached, .simulatorScreenshot(png: Data([0x89, 0x50])),
        ]
        for reply in replies { roundTrip(Message.reply(RequestId(1), reply)) }
        let channel: [SessionMessage] = [.credit(65536), .streamEnd, .streamClosed(nil), .streamClosed(.timedOut),
                                         .simulatorInput([.touch(x: 0, y: 1, down: false)]), .requestKeyframe, .simulatorStopped]
        for message in channel { roundTrip(message) }
        roundTrip(Message.event(.changed(topic: .simulators, revision: 3)))
    }

    func testNewerFieldsAndValuesDecode() throws {
        let info = try WireJSON.decode(SimulatorInfo.self, from: Data(#"""
        {"simulator":{"platform":"iOS","id":"X"},"name":"iPhone","booted":true,"buttons":["home","crown"],"bezel":"round"}
        """#.utf8))
        XCTAssertEqual(info.simulator, .iOS("X"))
        XCTAssertEqual(info.buttons, [], "a button this build doesn't know drops the list, not the simulator")
        let failure = try WireJSON.decode(ReplyBody.self, from: Data(#"{"type":"tunnelFailed","failure":"firewalled"}"#.utf8))
        XCTAssertEqual(failure, .tunnelFailed(.unknown("firewalled")))
        let input = try WireJSON.decode(SimulatorInput.self, from: Data(#"{"type":"pinch","scale":2}"#.utf8))
        XCTAssertEqual(input, .unknown("pinch"))
        let action = try WireJSON.decode(SimulatorAction.self, from: Data(#"{"type":"shake"}"#.utf8))
        XCTAssertEqual(action, .unknown("shake"))
        let request = try WireJSON.decode(Message.self, from: Data(#"""
        {"type":"request","id":2,"body":{"type":"openTunnel","host":"localhost","port":8081,"via":"ipv6"}}
        """#.utf8))
        XCTAssertEqual(request, .request(RequestId(2), .openTunnel(host: "localhost", port: 8081)))
    }

    func testSimulatorDriveRoundTripsAndOlderBuildsSkipNewerSteps() throws {
        let drive = SimulatorDrive(steps: [
            .tap(.ref("e3"), count: 2, hold: 0), .tap(.point(x: 10.5, y: 20), count: 1, hold: 1),
            .swipe(from: .point(x: 1, y: 2), to: .label("Done"), duration: 0.3), .scroll(.down, distance: 0.5, within: nil),
            .scroll(.left, distance: 0.8, within: .identifier("carousel")), .type("héllo"), .fill(.ref("e5"), text: "Ada"),
            .key("cmd+a"), .button(.home), .wait(seconds: 0.5), .waitFor(.label("Saved"), gone: true, timeout: 3),
            .launch(app: "com.example"), .terminate(app: "com.example"), .install(path: "/tmp/A.app"),
            .uninstall(app: "com.example"), .openURL("myapp://x"), .location(latitude: 41.4, longitude: 2.17),
        ], settle: true, snapshot: SimulatorSnapshotOptions(interactiveOnly: true),
           screenshot: SimulatorScreenshotOptions(format: .jpeg, quality: 60), apps: true,
           logs: SimulatorLogOptions(app: "com.example", seconds: 30, lines: 50))
        roundTrip(Message.request(RequestId(1), .simulatorDrive(simulator: .iOS("A1B2"), drive: drive)))
        let element = SimulatorElement(ref: "e3", role: "button", label: "General", identifier: "general", value: nil,
                                       x: 16, y: 380, width: 370, height: 52, enabled: true, interactive: true, depth: 2)
        roundTrip(Message.reply(RequestId(1), .simulatorDriven(SimulatorDriveResult(
            screen: SimulatorScreen(width: 402, height: 874, scale: 3), elements: [element], added: [element], removed: [],
            changed: [], unchanged: 4, image: Data([1, 2]), imageFormat: .png, apps: [SimulatorApp(id: "com.example", name: "Example")],
            logs: "line", notes: ["a note"]))))

        // A newer client's step, target or field reaches an older server as unknown, not as a failure.
        let newer = try WireJSON.decode(SimulatorDrive.self, from: Data(#"""
        {"steps":[{"type":"pinch","scale":2},{"type":"tap","target":{"type":"text","text":"OK"},"force":1}],"video":true}
        """#.utf8))
        XCTAssertEqual(newer.steps, [.unknown("pinch"), .tap(.unknown("text"), count: 1, hold: 0)])
        XCTAssertFalse(newer.settle)
        let sparse = try WireJSON.decode(SimulatorElement.self, from: Data(#"{"ref":"e1","role":"cell","x":1,"y":2}"#.utf8))
        XCTAssertEqual(sparse.width, 0)
        XCTAssertTrue(sparse.enabled, "a missing enabled reads as enabled")
    }

    func testSimulatorDriveValidationBoundsAgentInput() {
        func drive(_ steps: [SimulatorStep]) -> RequestBody { .simulatorDrive(simulator: .iOS("X"), drive: SimulatorDrive(steps: steps)) }
        XCTAssertNoThrow(try drive([.tap(.ref("e1"), count: 1, hold: 0)]).validate())
        XCTAssertThrowsError(try drive([.tap(.ref("e1"), count: 0, hold: 0)]).validate())
        XCTAssertThrowsError(try drive([.tap(.point(x: .nan, y: 1), count: 1, hold: 0)]).validate())
        XCTAssertThrowsError(try drive([.wait(seconds: -1)]).validate())
        XCTAssertThrowsError(try drive([.wait(seconds: 3600)]).validate())
        XCTAssertThrowsError(try drive([.scroll(.down, distance: 2, within: nil)]).validate())
        XCTAssertThrowsError(try drive([.location(latitude: 91, longitude: 0)]).validate())
        XCTAssertThrowsError(try drive([.type("a\u{0}b")]).validate())
        XCTAssertThrowsError(try drive(Array(repeating: .wait(seconds: 0), count: SimulatorDrive.maxSteps + 1)).validate())
        XCTAssertThrowsError(try RequestBody.simulatorDrive(simulator: .iOS("X"), drive: SimulatorDrive(
            screenshot: SimulatorScreenshotOptions(quality: 0))).validate())
    }

    func testValidationRefusesOutOfRangeTraffic() {
        XCTAssertThrowsError(try RequestBody.openTunnel(host: "", port: 80).validate())
        XCTAssertThrowsError(try RequestBody.openTunnel(host: "localhost", port: 0).validate())
        XCTAssertThrowsError(try RequestBody.openTunnel(host: "evil host", port: 80).validate())
        XCTAssertThrowsError(try RequestBody.openTunnel(host: String(repeating: "a", count: 300), port: 80).validate())
        XCTAssertNoThrow(try RequestBody.openTunnel(host: "::1", port: 80).validate())
        XCTAssertThrowsError(try SessionMessage.credit(Limits.tunnelWindow + 1).validate())
        XCTAssertThrowsError(try SessionMessage.simulatorInput([.touch(x: .nan, y: 0, down: true)]).validate())
        XCTAssertThrowsError(try SessionMessage.simulatorInput(Array(repeating: .button(.home), count: Limits.maxSimulatorInput + 1)).validate())
        XCTAssertThrowsError(try RequestBody.simulatorAction(simulator: .iOS("../x"), action: .boot).validate())
        XCTAssertThrowsError(try RequestBody.attachSimulator(AttachSimulator(simulator: .iOS("X"), maxPixels: 0)).validate())
    }
}
