import AppKit
import AVFoundation
import Contacts
import CoreBluetooth
import CoreLocation
import EventKit
import Photos

/// Something macOS asks before a program uses it. Programs run in Tab's
/// terminals ask as Tab, so Tab's answer is theirs.
public enum PrivacyPermission: String, CaseIterable, Sendable {
    case camera, microphone, contacts, calendars, reminders, photos, location, bluetooth

    public var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .contacts: "Contacts"
        case .calendars: "Calendars"
        case .reminders: "Reminders"
        case .photos: "Photos"
        case .location: "Location Services"
        case .bluetooth: "Bluetooth"
        }
    }

    /// Its row in `SettingsCatalog`.
    public var settingId: String { "privacy-\(rawValue)" }

    /// The pane of System Settings › Privacy & Security that changes it.
    public var settingsPane: String {
        switch self {
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .contacts: "Privacy_Contacts"
        case .calendars: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .photos: "Privacy_Photos"
        case .location: "Privacy_LocationServices"
        case .bluetooth: "Privacy_Bluetooth"
        }
    }

    /// Opens System Settings at `pane` of Privacy & Security.
    @MainActor
    public static func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// What its row says, given macOS's answer.
    public func detail(_ access: PrivacyAccess) -> String? {
        switch access {
        case .allowed, .notAsked:
            return nil
        case .limited:
            switch self {
            case .calendars: return "Programs can add events but can't read them. Allow full access in System Settings."
            case .reminders: return "Programs can add reminders but can't read them. Allow full access in System Settings."
            case .photos: return "Programs can use only the photos you picked. Allow full access in System Settings."
            default: return "Programs have only part of this access. Allow full access in System Settings."
            }
        case .denied:
            if self == .location {
                return "Programs can't use it. Allow Tab, and turn on Location Services, in System Settings."
            }
            return "Programs can't use it. macOS won't ask again, so allow Tab in System Settings."
        case .restricted:
            return "Your organization or Screen Time manages this, so it can't be changed here."
        }
    }

    /// Asks macOS for this permission, which shows its prompt when it hasn't
    /// been answered. Returns whether macOS answered; `false` when it gave
    /// no answer in time, such as when the prompt is left open.
    @MainActor
    public func request() async -> Bool {
        switch self {
        case .camera: _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .contacts: _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .calendars: _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders: _ = try? await EKEventStore().requestFullAccessToReminders()
        case .photos: _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case .location:
            // With Location Services off, macOS shows no prompt.
            guard CLLocationManager.locationServicesEnabled() else { return true }
            return await LocationPrompt().run()
        case .bluetooth: return await BluetoothPrompt().run()
        }
        return true
    }
}

/// What macOS answered for one permission.
public enum PrivacyAccess: Sendable, Equatable {
    case allowed
    /// Allowed in part, such as calendars without reading or some photos.
    case limited
    case denied
    /// A device management or Screen Time policy decides.
    case restricted
    case notAsked

    public var title: String {
        switch self {
        case .allowed: "Allowed"
        case .limited: "Limited"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notAsked: "Not asked yet"
        }
    }

    /// This process's answer for `permission`, without asking.
    @MainActor
    public static func current(_ permission: PrivacyPermission) -> PrivacyAccess {
        switch permission {
        case .camera: capture(.video)
        case .microphone: capture(.audio)
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized: .allowed
            case .denied: .denied
            case .restricted: .restricted
            case .notDetermined: .notAsked
            @unknown default: .limited
            }
        case .calendars: events(.event)
        case .reminders: events(.reminder)
        case .photos:
            switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized: .allowed
            case .limited: .limited
            case .denied: .denied
            case .restricted: .restricted
            case .notDetermined: .notAsked
            @unknown default: .notAsked
            }
        case .location: location(CLLocationManager().authorizationStatus)
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: .allowed
            case .denied: .denied
            case .restricted: .restricted
            case .notDetermined: .notAsked
            @unknown default: .notAsked
            }
        }
    }

    fileprivate static func location(_ status: CLAuthorizationStatus) -> PrivacyAccess {
        switch status {
        case .authorizedAlways: .allowed
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notAsked
        @unknown default: .allowed
        }
    }

    private static func capture(_ media: AVMediaType) -> PrivacyAccess {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: .allowed
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notAsked
        @unknown default: .notAsked
        }
    }

    private static func events(_ entity: EKEntityType) -> PrivacyAccess {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess: .allowed
        case .writeOnly: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notAsked
        @unknown default: .allowed
        }
    }

    /// Whether Tab has Full Disk Access, which macOS never prompts for:
    /// only a process with it can open the user's privacy database. `nil`
    /// when the check can't tell.
    public static func fullDiskAccess() -> Bool? {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return errno == EPERM || errno == EACCES ? false : nil
    }
}

/// How long a delegate-based prompt waits for an answer before giving up;
/// the page refreshes again when Tab becomes active.
private let promptTimeout: Duration = .seconds(120)

/// Keeps a location manager until macOS answers its prompt.
@MainActor
private final class LocationPrompt: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Bool, Never>?

    func run() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.requestWhenInUseAuthorization()
            Task { [weak self] in
                try? await Task.sleep(for: promptTimeout)
                self?.finish(false)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus != .notDetermined { finish(true) }
    }

    private func finish(_ answered: Bool) {
        manager.delegate = nil
        continuation?.resume(returning: answered)
        continuation = nil
    }
}

/// Keeps a Bluetooth manager, whose creation shows the prompt, until macOS
/// answers it.
@MainActor
private final class BluetoothPrompt: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var continuation: CheckedContinuation<Bool, Never>?

    func run() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            // No "turn on Bluetooth" alert: only the permission is wanted.
            manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            Task { [weak self] in
                try? await Task.sleep(for: promptTimeout)
                self?.finish(false)
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if CBManager.authorization != .notDetermined { finish(true) }
    }

    private func finish(_ answered: Bool) {
        manager?.delegate = nil
        manager = nil
        continuation?.resume(returning: answered)
        continuation = nil
    }
}
