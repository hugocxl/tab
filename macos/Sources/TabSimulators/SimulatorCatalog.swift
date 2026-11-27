import Foundation
import TabCore
import TabProtocol

/// Every simulator and emulator on this Mac, and a watch that says when one
/// boots, stops, appears or goes: CoreSimulator's notifications for
/// simulators and the discovery folder for emulators, so nothing polls.
public final class SimulatorCatalog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.hugocorta.tab.simulators.catalog", qos: .utility)
    private let changed: @Sendable () -> Void
    private let bridge = IOSSimulatorBridge.shared
    private var watching = false
    private var registrations: [String: (simulator: AnyObject, token: UInt)] = [:]
    private var setRegistration: (set: AnyObject, token: UInt)?
    private var folderWatch: DispatchSourceFileSystemObject?

    /// - Parameter changed: runs on a background queue after a change.
    public init(changed: @escaping @Sendable () -> Void) {
        self.changed = changed
    }

    deinit {
        folderWatch?.cancel()
    }

    /// Every simulator: running ones first, iOS before Android. A platform
    /// whose tools are missing adds nothing. Runs `simctl` off the caller's thread.
    public func list() async -> [SimulatorInfo] {
        let simulators = ((try? await IOSSimulatorControl.simulators()) ?? []).map { simulator in
            SimulatorInfo(simulator: .iOS(simulator.udid), name: simulator.name, runtime: simulator.runtime,
                          booted: simulator.isBooted, isTablet: simulator.name.hasPrefix("iPad"), buttons: [.home, .lock],
                          hardwareKeyboardSwitch: true)
        }
        let android = await Task.detached(priority: .utility) { () -> [SimulatorInfo] in
            let running = Set(AndroidEmulators.running().map(\.avd))
            return AndroidEmulators.virtualDevices().map { avd in
                SimulatorInfo(simulator: .android(avd.name), name: avd.displayName, runtime: avd.runtime,
                              booted: running.contains(avd.name), isTablet: avd.isTablet,
                              buttons: [.back, .home, .recents, .lock], hardwareKeyboardSwitch: false)
            }
        }.value
        let all = (simulators + android).prefix(Limits.maxSimulatorList)
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
        bridge.queue.async { [self] in watchIOSSimulators() }
    }

    private func watchIOSSimulators() {
        dispatchPrecondition(condition: .onQueue(bridge.queue))
        if setRegistration == nil, let set = try? bridge.deviceSet(),
           let token = bridge.registerNotifications(set, queue: queue, handler: { [weak self] in self?.iOSSimulatorsChanged() }) {
            setRegistration = (set, token)
        }
        let simulators = (try? bridge.simulators()) ?? []
        var seen = Set<String>()
        for simulator in simulators {
            guard let udid = IOSSimulatorBridge.udid(of: simulator) else { continue }
            seen.insert(udid)
            guard registrations[udid] == nil,
                  let token = bridge.registerNotifications(simulator, queue: queue, handler: { [weak self] in self?.changed() })
            else { continue }
            registrations[udid] = (simulator, token)
        }
        for (udid, entry) in registrations where !seen.contains(udid) {
            bridge.unregisterNotifications(entry.simulator, entry.token)
            registrations[udid] = nil
        }
    }

    /// A simulator was added or removed: follow the new ones too.
    private func iOSSimulatorsChanged() {
        bridge.queue.async { [self] in watchIOSSimulators() }
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
