import AppKit
import SwiftUI
import TabCore

/// The local server's actual build and controls, independent of update-chip dismissal.
struct ServerSettingsHeader: View {
    @ObservedObject var model: SettingsModel
    let build: SettingsPageBuilder
    var appVersion = Release.version
    @Environment(\.settingsTheme) private var theme

    private var store: SettingsStore { model.store }
    private var outdated: Bool {
        UpdateDecision.isOutdated(serverVersion: store.serverVersion, appVersion: appVersion)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local server").font(.title3.weight(.semibold))
                        Text(status).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    control(store.serverState == .running ? "stop-server" : "server")
                }
                if store.serverState == .running {
                    SwiftUI.Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(outdated ? "Restart to finish updating" : "Server version")
                                .font(.body.weight(.medium))
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        control("restart-server")
                    }
                }
                if let error = store.host?.serverRestartFailure {
                    Text(error).foregroundStyle(theme?.danger ?? .red)
                }
                ForEach(["server", "stop-server", "restart-server"], id: \.self) { id in
                    if let error = store.errors[id] {
                        Text(error).foregroundStyle(theme?.danger ?? .red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }

    private var status: String {
        if store.serverRestarting { return "Restarting the server…" }
        if store.serverBusy { return "Stopping the server…" }
        if let version = store.serverVersion { return "Running · Version \(version)" }
        return store.serverState.title
    }

    private var detail: String {
        if let version = store.serverVersion {
            if outdated { return UpdateChip.serverUpdateMessage(version: version) }
            return "The server is running \(Release.appName) \(version)."
        }
        return "This server did not report its version."
    }

    @ViewBuilder
    private func control(_ id: String) -> some View {
        if let control = build.rows.first(where: { $0.id == id })?.control {
            SettingControlView(control: control, model: model)
        }
    }
}
