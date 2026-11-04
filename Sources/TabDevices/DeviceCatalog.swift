import Foundation
import TabCore
import TabProtocol

/// Every simulator and emulator on this Mac, and a watch that says when one
/// boots, stops, appears or goes: CoreSimulator's notifications for
/// simulators and the discovery folder for emulators, so nothing polls.
public final class DeviceCatalog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.hugocorta.tab.devices.catalog", qos: .utility)
    private let changed: @Sendable () -> Void
    private let bridge = SimulatorBridge.shared
    private var watching = false
    private var registrations: [String: (device: AnyObject, token: UInt)] = [:]
    private var setRegistration: (set: AnyObject, token: UInt)?
    private var folderWatch: DispatchSourceFileSystemObject?

    /// - Parameter changed: runs on a background queue after a change.
    public init(changed: @escaping @Sendable () -> Void) {
        self.changed = changed
    }

    deinit {
        folderWatch?.cancel()
    }

    /// Every device: running ones first, iOS before Android. A platform
    /// whose tools are missing adds nothing. Runs `simctl` off the caller's thread.
    public func list() async -> [DeviceInfo] {
        let simulators = ((try? await SimulatorControl.devices()) ?? []).map { simulator in
            DeviceInfo(device: .simulator(simulator.udid), name: simulator.name, runtime: simulator.runtime,
                       booted: simulator.isBooted, isTablet: simulator.name.hasPrefix("iPad"), buttons: [.home, .lock],
                       hardwareKeyboardSwitch: true)
        }
        let android = await Task.detached(priority: .utility) { () -> [DeviceInfo] in
            let running = Set(AndroidEmulators.running().map(\.avd))
            return AndroidEmulators.virtualDevices().map { avd in
                DeviceInfo(device: .emulator(avd.name), name: avd.displayName, runtime: avd.runtime,
                           booted: running.contains(avd.name), isTablet: avd.isTablet,
                           buttons: [.back, .home, .recents, .lock], hardwareKeyboardSwitch: false)
            }
        }.value
        let all = (simulators + android).prefix(Limits.maxDeviceList)
        return all.enumerated().sorted { a, b in
            if a.element.booted != b.element.booted { return a.element.booted }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Starts calling `changed` on changes; later calls do nothing.
    public func watch() {
        queue.async { [self] in
            guard !watching else { return }
            watching = true
            watchAndroid()
        }
        bridge.queue.async { [self] in watchSimulators() }
    }

    private func watchSimulators() {
        dispatchPrecondition(condition: .onQueue(bridge.queue))
        if setRegistration == nil, let set = try? bridge.deviceSet(),
           let token = bridge.registerNotifications(set, queue: queue, handler: { [weak self] in self?.simulatorsChanged() }) {
            setRegistration = (set, token)
        }
        let devices = (try? bridge.devices()) ?? []
        var seen = Set<String>()
        for device in devices {
            guard let udid = SimulatorBridge.udid(of: device) else { continue }
            seen.insert(udid)
            guard registrations[udid] == nil,
                  let token = bridge.registerNotifications(device, queue: queue, handler: { [weak self] in self?.changed() })
            else { continue }
            registrations[udid] = (device, token)
        }
        for (udid, entry) in registrations where !seen.contains(udid) {
            bridge.unregisterNotifications(entry.device, entry.token)
            registrations[udid] = nil
        }
    }

    /// A device was added or removed: follow the new ones too.
    private func simulatorsChanged() {
        bridge.queue.async { [self] in watchSimulators() }
        changed()
    }

    private func watchAndroid() {
        let folder = AndroidEmulators.discoveryFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        folderWatch = source
    }
}
