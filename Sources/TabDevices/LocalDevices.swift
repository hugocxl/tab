import CoreImage
import Foundation
import ImageIO
import IOSurface
import TabProtocol
import UniformTypeIdentifiers

/// Devices on this Mac, reached directly.
public enum LocalDevices {
    /// A session for `device` on this Mac.
    @MainActor
    public static func session(for device: DeviceRef) -> DeviceSession {
        switch device.platform {
        case .iOS: SimulatorSession(udid: device.id)
        case .android: AndroidSession(avd: device.id)
        }
    }

    /// Opens `url` on a running device.
    public static func openURL(_ url: String, on device: DeviceRef) async throws {
        switch device.platform {
        case .iOS:
            try await SimulatorControl.openURL(device.id, url)
        case .android:
            guard let emulator = AndroidEmulators.running().first(where: { $0.avd == device.id }) else {
                throw AndroidError.failed("The emulator isn't running")
            }
            try await AndroidEmulators.openURL(emulator, url)
        }
    }

    /// What `surface` shows, as a PNG.
    public static func png(_ surface: IOSurface) -> Data? {
        let image = CIImage(ioSurface: surface)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
