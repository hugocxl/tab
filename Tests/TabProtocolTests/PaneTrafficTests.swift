import XCTest
@testable import TabProtocol

/// Tunnel and device traffic: its frames and messages round trip, and
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

    func testTunnelAndDeviceMessagesRoundTrip() {
        let device = DeviceRef.simulator("A1B2")
        let requests: [RequestBody] = [
            .openTunnel(host: "localhost", port: 3000), .closeTunnel(ChannelId(3)), .listDevices,
            .deviceAction(device: device, action: .rotate(turns: -1)),
            .deviceAction(device: .emulator("Pixel_8"), action: .input([.touch(x: 0.5, y: 0.25, down: true),
                                                                       .key(usage: 4, down: false), .button(.back)])),
            .deviceAction(device: device, action: .type("hi")), .deviceAction(device: device, action: .openURL("myapp://x")),
            .deviceAction(device: device, action: .setHardwareKeyboard(false)),
            .attachDevice(AttachDevice(device: device, maxPixels: 2_000_000, codecs: [.hevc, .h264])),
            .detachDevice(ChannelId(5)), .deviceScreenshot(device),
        ]
        for request in requests { roundTrip(Message.request(RequestId(1), request)) }
        let replies: [ReplyBody] = [
            .tunnelOpened(channel: ChannelId(2)), .tunnelFailed(.refused), .tunnelClosed,
            .devices([DeviceInfo(device: device, name: "iPhone", runtime: "iOS 27.0", booted: true, buttons: [.home],
                                 hardwareKeyboardSwitch: true)]),
            .deviceSettings(DeviceSettings(booted: true, dark: false, orientation: .landscapeLeft)),
            .deviceAttached(DeviceStream(channel: ChannelId(6), codec: .h264, width: 600, height: 1300)),
            .deviceDetached, .deviceScreenshot(png: Data([0x89, 0x50])),
        ]
        for reply in replies { roundTrip(Message.reply(RequestId(1), reply)) }
        let channel: [SessionMessage] = [.credit(65536), .streamEnd, .streamClosed(nil), .streamClosed(.timedOut),
                                         .deviceInput([.touch(x: 0, y: 1, down: false)]), .requestKeyframe, .deviceStopped]
        for message in channel { roundTrip(message) }
        roundTrip(Message.event(.changed(topic: .devices, revision: 3)))
    }

    func testNewerFieldsAndValuesDecode() throws {
        let info = try WireJSON.decode(DeviceInfo.self, from: Data(#"""
        {"device":{"platform":"iOS","id":"X"},"name":"iPhone","booted":true,"buttons":["home","crown"],"bezel":"round"}
        """#.utf8))
        XCTAssertEqual(info.device, .simulator("X"))
        XCTAssertEqual(info.buttons, [], "a button this build doesn't know drops the list, not the device")
        let failure = try WireJSON.decode(ReplyBody.self, from: Data(#"{"type":"tunnelFailed","failure":"firewalled"}"#.utf8))
        XCTAssertEqual(failure, .tunnelFailed(.unknown("firewalled")))
        let input = try WireJSON.decode(DeviceInput.self, from: Data(#"{"type":"pinch","scale":2}"#.utf8))
        XCTAssertEqual(input, .unknown("pinch"))
        let action = try WireJSON.decode(DeviceAction.self, from: Data(#"{"type":"shake"}"#.utf8))
        XCTAssertEqual(action, .unknown("shake"))
        let request = try WireJSON.decode(Message.self, from: Data(#"""
        {"type":"request","id":2,"body":{"type":"openTunnel","host":"localhost","port":8081,"via":"ipv6"}}
        """#.utf8))
        XCTAssertEqual(request, .request(RequestId(2), .openTunnel(host: "localhost", port: 8081)))
    }

    func testValidationRefusesOutOfRangeTraffic() {
        XCTAssertThrowsError(try RequestBody.openTunnel(host: "", port: 80).validate())
        XCTAssertThrowsError(try RequestBody.openTunnel(host: "localhost", port: 0).validate())
        XCTAssertThrowsError(try RequestBody.openTunnel(host: "evil host", port: 80).validate())
        XCTAssertThrowsError(try RequestBody.openTunnel(host: String(repeating: "a", count: 300), port: 80).validate())
        XCTAssertNoThrow(try RequestBody.openTunnel(host: "::1", port: 80).validate())
        XCTAssertThrowsError(try SessionMessage.credit(Limits.tunnelWindow + 1).validate())
        XCTAssertThrowsError(try SessionMessage.deviceInput([.touch(x: .nan, y: 0, down: true)]).validate())
        XCTAssertThrowsError(try SessionMessage.deviceInput(Array(repeating: .button(.home), count: Limits.maxDeviceInput + 1)).validate())
        XCTAssertThrowsError(try RequestBody.deviceAction(device: .simulator("../x"), action: .boot).validate())
        XCTAssertThrowsError(try RequestBody.attachDevice(AttachDevice(device: .simulator("X"), maxPixels: 0)).validate())
    }
}
