import AppKit
import TabCore

extension SettingsModel {
    func buildPrivacy(_ b: SettingsPageBuilder) {
        for permission in PrivacyPermission.allCases {
            let access = store.host?.privacyAccess(permission) ?? .notAsked
            var controls: [SettingControl] = [.label(access.title, access == .denied ? .error : .secondary)]
            if access == .denied || access == .limited {
                controls.append(b.button("Open \(permission.title) Settings", icon: .externalLink) {
                    PrivacyPermission.openSettings(permission.settingsPane)
                })
            }
            b.row(permission.settingId, .row(controls), label: permission.title)
        }
        b.note(PrivacyPermission.camera.settingId, "Programs in Tab's terminals ask macOS for access as Tab, so these answers are theirs. macOS asks the first time a program wants one, and you change an answer in System Settings.")
        b.row("privacy-automation", b.button("Open Settings") { PrivacyPermission.openSettings("Privacy_Automation") })
        b.row("privacy-files", b.button("Open Settings") { PrivacyPermission.openSettings("Privacy_AllFiles") })
    }
}
