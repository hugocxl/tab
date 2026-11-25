import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import IOSurface
import TabProtocol
import UniformTypeIdentifiers

/// What agents need of a simulator on this Mac beyond what its pane does:
/// its accessibility tree, its points, its apps and its logs.
@MainActor
public protocol SimulatorAutomation: SimulatorSession {
    /// Pixels per point of the screen.
    func pointScale() async throws -> Double
    /// Whether the surface is already upright, as an emulator's frames are;
    /// otherwise it is the panel's portrait and the orientation turns it.
    var surfaceIsUpright: Bool { get }
    /// The front app's elements, depth first, framed in points on the
    /// upright screen, without refs.
    func elements() async throws -> [SimulatorElement]
    func launch(_ app: String) async throws
    func terminate(_ app: String) async throws
    func install(_ path: String) async throws
    func uninstall(_ app: String) async throws
    func apps() async throws -> [SimulatorApp]
    func logs(_ options: SimulatorLogOptions) async throws -> String
    func setLocation(latitude: Double, longitude: Double) async throws
    /// Puts text on the simulator's pasteboard.
    func setPasteboard(_ text: String) async throws
}

extension LocalSimulators {
    /// What `surface` shows, turned upright by `turns` counterclockwise
    /// quarter turns and scaled by `scale`, as PNG or JPEG.
    public static func image(_ surface: IOSurface, turns: Int, scale: Double, format: SimulatorImageFormat,
                             quality: Int) -> Data? {
        var image = CIImage(ioSurface: surface)
        if turns % 4 != 0 {
            image = image.transformed(by: CGAffineTransform(rotationAngle: CGFloat(turns % 4) * .pi / 2))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        if scale > 0, abs(scale - 1) > 0.001 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            image = image.cropped(to: image.extent.integral)
        }
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        let data = NSMutableData()
        let type = format == .jpeg ? UTType.jpeg : UTType.png
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] : [:]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])
}

// MARK: iOS

extension IOSSimulatorSession: SimulatorAutomation {
    public var surfaceIsUpright: Bool { false }

    public func pointScale() async throws -> Double {
        if let scale = screenScale { return scale }
        let bridge = IOSSimulatorBridge.shared
        let udid = udid
        let scale = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double, Error>) in
            bridge.queue.async {
                continuation.resume(with: Result { IOSSimulatorBridge.screenScale(try bridge.simulator(udid)) ?? 1 })
            }
        }
        screenScale = scale
        return scale
    }

    public func elements() async throws -> [SimulatorElement] {
        let bridge = IOSSimulatorBridge.shared
        let accessibility = IOSSimulatorAccessibility.shared
        let udid = udid
        let simulator = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AnyObject, Error>) in
            bridge.queue.async { continuation.resume(with: Result { try bridge.simulator(udid) }) }
        }
        nonisolated(unsafe) let device = simulator
        let nodes = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[IOSSimulatorAccessibility.Node], Error>) in
            accessibility.queue.async {
                continuation.resume(with: Result { try accessibility.read(device, udid: udid) })
            }
        }
        return nodes.map(\.element)
    }

    public func launch(_ app: String) async throws { try await IOSSimulatorControl.launch(udid, app) }
    public func terminate(_ app: String) async throws { try await IOSSimulatorControl.terminate(udid, app) }
    public func install(_ path: String) async throws { try await IOSSimulatorControl.install(udid, path) }
    public func uninstall(_ app: String) async throws { try await IOSSimulatorControl.uninstall(udid, app) }
    public func apps() async throws -> [SimulatorApp] { try await IOSSimulatorControl.apps(udid) }
    public func logs(_ options: SimulatorLogOptions) async throws -> String { try await IOSSimulatorControl.logs(udid, options) }

    public func setLocation(latitude: Double, longitude: Double) async throws {
        try await IOSSimulatorControl.setLocation(udid, latitude: latitude, longitude: longitude)
    }

    public func setPasteboard(_ text: String) async throws { try await IOSSimulatorControl.setPasteboard(udid, text) }
}
