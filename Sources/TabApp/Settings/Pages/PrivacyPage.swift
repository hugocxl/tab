import AppKit
import TabCore

extension SettingsModel {
    func buildPrivacy(_ b: SettingsPageBuilder) {
        for permission in PrivacyPermission.allCases {
            let access = store.host?.privacyAccess(permission) ?? .notAsked
            b.row(permission.settingId, privacyControl(b, permission, access),
                  label: permission.title, description: permission.detail(access))
        }
        b.note(PrivacyPermission.camera.settingId, "Programs you run in Tab's terminals ask macOS as Tab, so what you allow here applies to them. macOS asks only once; after that, change an answer in System Settings › Privacy & Security.")

        b.row("privacy-automation", b.button("Open System Settings") { PrivacyPermission.openSettings("Privacy_Automation") })
        switch store.host?.fullDiskAccess() {
        case true?:
            b.row("privacy-files", .status("Allowed", .success))
        case false?:
            b.row("privacy-files", .row([.status("Not allowed", .neutral), openSettings(b, "Privacy_AllFiles")]),
                  description: "Lets programs read protected folders, such as Mail and Safari data. macOS never asks for it: turn on Tab in System Settings.")
        case nil:
            b.row("privacy-files", openSettings(b, "Privacy_AllFiles"))
        }

        let policy = store.settings.agents.remoteImages
        b.row("agent-remote-images", b.popUp("agent-remote-images", RemoteImagePolicy.allCases.map { Choice(id: $0.rawValue, title: $0.title) },
                                             selected: policy.rawValue) { [store] id in
            store.updateAgents("agent-remote-images") { $0.remoteImages = RemoteImagePolicy(rawValue: id) ?? .clickToLoad }
        })
    }

    /// A pill for macOS's answer and the button that changes it: Grant
    /// Access before macOS has asked, System Settings once it has.
    private func privacyControl(_ b: SettingsPageBuilder, _ permission: PrivacyPermission, _ access: PrivacyAccess) -> SettingControl {
        switch access {
        case .allowed:
            return .status("Allowed", .success)
        case .notAsked:
            let waiting = privacyRequests.contains(permission)
            return b.button(waiting ? "Waiting for macOS…" : "Grant Access", style: .primary, enabled: !waiting,
                            help: "Shows macOS's prompt to allow Tab \(permission.title.lowercased()) access.") { [weak self] in
                self?.requestPrivacyAccess(permission)
            }
        case .limited:
            return .row([.status("Limited", .warning), openSettings(b, permission.settingsPane)])
        case .denied:
            return .row([.status("Denied", .danger), openSettings(b, permission.settingsPane)])
        case .restricted:
            return .status("Restricted", .neutral)
        }
    }

    private func openSettings(_ b: SettingsPageBuilder, _ pane: String) -> SettingControl {
        b.button("Open System Settings") { PrivacyPermission.openSettings(pane) }
    }
}
