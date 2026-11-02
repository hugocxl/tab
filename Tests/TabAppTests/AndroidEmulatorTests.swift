import IOSurface
import XCTest
@testable import TabApp

final class AndroidEmulatorTests: XCTestCase {
    func testProtobufRoundTripsTheFieldsTheControlAPIUses() {
        var touch = ProtobufWriter()
        touch.int32(1, 540)
        touch.int32(2, 1_200)
        touch.int32(4, 0)
        var event = ProtobufWriter()
        event.message(1, touch)
        event.string(4, "GoHome")
        let reader = ProtobufReader(event.data)
        let decoded = reader.message(1)
        XCTAssertEqual(decoded?.uint(1), 540)
        XCTAssertEqual(decoded?.uint(2), 1_200)
        XCTAssertNil(decoded?.uint(4), "proto3 leaves defaults out, so a lift sends no pressure")
        XCTAssertEqual(reader.bytes(4).map { String(decoding: $0, as: UTF8.self) }, "GoHome")
        XCTAssertTrue(ProtobufReader(Data([0x08, 0xFF])).fields.isEmpty, "a truncated varint stops reading")
    }

    func testFramesDecodeAndCopyIntoABGRASurfaceUpright() throws {
        var rotation = ProtobufWriter()
        rotation.varint(1, 1)
        var format = ProtobufWriter()
        format.varint(1, 1)
        format.message(2, rotation)
        format.varint(3, 2)
        format.varint(4, 1)
        var image = ProtobufWriter()
        image.message(1, format)
        // Field 4, eight bytes: a red then a blue RGBA pixel.
        var message = image.data
        message.append(Data([0x22, 8, 255, 0, 0, 255, 0, 0, 255, 255]))
        let frame = try XCTUnwrap(AndroidFrame(message))
        XCTAssertEqual(frame.width, 2)
        XCTAssertEqual(frame.height, 1)
        XCTAssertEqual(frame.turns, 1)
        let surface = try XCTUnwrap(frame.copy(into: nil))
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual([bytes[0], bytes[1], bytes[2], bytes[3]], [0, 0, 255, 255], "red in BGRA")
        XCTAssertEqual([bytes[4], bytes[5], bytes[6], bytes[7]], [255, 0, 0, 255], "blue in BGRA")
        XCTAssertTrue(frame.copy(into: surface) === surface, "a same-size frame reuses the surface")
        XCTAssertNil(AndroidFrame(Data([0x22, 2, 0, 0])), "pixels shorter than the size are refused")
    }

    func testDiscoveryFilesAndAVDConfigsDescribeEmulators() throws {
        let values = AndroidEmulators.parseINI("""
        avd.name=Pixel_8_API_35
        port.serial = 5554
        grpc.port=8554
        grpc.token=secret=with=equals
        """)
        let emulator = try XCTUnwrap(AndroidEmulators.emulator(pid: 42, values))
        XCTAssertEqual(emulator.serial, "emulator-5554")
        XCTAssertEqual(emulator.grpcPort, 8554)
        XCTAssertEqual(emulator.grpcToken, "secret=with=equals")
        XCTAssertFalse(emulator.needsUnsupportedAuth)
        let studio = try XCTUnwrap(AndroidEmulators.emulator(pid: 7, ["avd.name": "A", "port.serial": "5556", "grpc.jwks": "/x"]))
        XCTAssertTrue(studio.needsUnsupportedAuth)
        XCTAssertNil(AndroidEmulators.emulator(pid: 7, ["avd.name": "A"]))
        let device = AndroidEmulators.device(name: "Pixel_Tablet_API_35", config: [
            "image.sysdir.1": "system-images/android-35/google_apis/arm64-v8a/", "hw.device.name": "pixel_tablet",
        ])
        XCTAssertEqual(device.displayName, "Pixel Tablet API 35")
        XCTAssertEqual(device.runtime, "Android API 35")
        XCTAssertTrue(device.isTablet)
    }

    func testHPACKIntegersUseTheirPrefixAndContinuationBytes() {
        var data = Data()
        GRPCClient.appendInteger(10, prefixBits: 5, to: &data)
        GRPCClient.appendInteger(1337, prefixBits: 5, to: &data)
        XCTAssertEqual([UInt8](data), [10, 31, 154, 10], "RFC 7541 C.1.1 and C.1.2")
        var header = Data()
        GRPCClient.appendLiteral("te", "trailers", to: &header)
        XCTAssertEqual([UInt8](header), [0x00, 2] + Array("te".utf8) + [8] + Array("trailers".utf8))
    }
}
