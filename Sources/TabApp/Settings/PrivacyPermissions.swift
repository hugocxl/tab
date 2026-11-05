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
}

/// What macOS answered for one permission.
public enum PrivacyAccess: Sendable, Equatable {
    case allowed
    /// Allowed in part, such as calendars without reading or some photos.
    case limited
    case denied
    /// A device policy decides.
    case restricted
    case notAsked

    public var title: String {
        switch self {
        case .allowed: "Allowed"
        case .limited: "Limited"
        case .denied: "Denied"
        case .restricted: "Set by your organization"
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
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .authorizedAlways: .allowed
            case .denied: .denied
            case .restricted: .restricted
            case .notDetermined: .notAsked
            @unknown default: .allowed
            }
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
}
