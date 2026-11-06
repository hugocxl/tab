import CoreImage
import Foundation
import ImageIO
import IOSurface
import TabProtocol
import UniformTypeIdentifiers

/// Simulators on this Mac, reached directly.
public enum LocalSimulators {
    /// A session for `simulator` on this Mac.
    @MainActor
    public static func session(for simulator: SimulatorRef) -> SimulatorSession {
        switch simulator.platform {
        case .iOS: IOSSimulatorSession(udid: simulator.id)
        case .android: AndroidSession(avd: simulator.id)
        }
    }

    /// Opens `url` on a running simulator.
    public static func openURL(_ url: String, on simulator: SimulatorRef) async throws {
        switch simulator.platform {
        case .iOS:
            try await IOSSimulatorControl.openURL(simulator.id, url)
        case .android:
            guard let emulator = AndroidEmulators.running().first(where: { $0.avd == simulator.id }) else {
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
