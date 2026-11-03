import AppKit
import TabCore

extension SettingsModel {
    func buildPrivacy(_ b: SettingsPageBuilder) {
        let permissions = PrivacyPermission.allCases.map { permission -> SettingControl in
            let access = store.host?.privacyAccess(permission) ?? .notAsked
            var controls: [SettingControl] = [.label(permission.title), .label(access.title, access == .denied ? .error : .secondary)]
            if access == .denied || access == .limited {
                controls.append(b.button("Open \(permission.title) Settings", symbol: "arrow.up.forward.app") {
                    PrivacyPermission.openSettings(permission.settingsPane)
                })
            }
            return .row(controls)
        }
        b.row("privacy-permissions", .column(permissions), stacked: true)
        b.note("privacy-permissions", "macOS asks the first time a program wants one; nothing is asked ahead of time.")
        b.row("privacy-automation", b.button("Open Settings") { PrivacyPermission.openSettings("Privacy_Automation") })
        b.row("privacy-files", b.button("Open Settings") { PrivacyPermission.openSettings("Privacy_AllFiles") })
    }
}
