import AppKit
import SwiftUI
import TabCore

/// Settings → Plugins: install and uninstall optional right-sidebar plugins.
/// Plugins are loaded lazily on demand and removed from disk when uninstalled.
struct PluginsPage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        Form {
            Section {
                ForEach(PluginCatalog.all) { plugin in
                    PluginRow(plugin: plugin, model: model)
                        .listRowBackground(theme?.card)
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Available Plugins")
                    Text("Installed plugins appear in the right sidebar. Uninstalled plugins are removed from disk and not loaded by Tab.")
                        .font(.subheadline)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Plugins are installed into your Tab profile folder and loaded only when enabled.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background { theme?.background.ignoresSafeArea() }
    }
}

private struct PluginRow: View {
    let plugin: PluginDescriptor
    @ObservedObject var model: SettingsModel
    @Environment(\.settingsTheme) private var theme

    private var state: PluginInstallState {
        model.store.pluginState(plugin.id)
    }

    private var errorText: String? {
        if let err = model.store.errors["plugin.\(plugin.id.rawValue)"] { return err }
        if case .failed(let message) = state { return message }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            pluginIcon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.name)
                        .fontWeight(.medium)
                    if state.isInstalled {
                        Text("Installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(plugin.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorText {
                    Text(errorText)
                        .font(.subheadline)
                        .foregroundStyle(theme?.danger ?? .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            actionControl
        }
        .padding(.vertical, 4)
    }

    private var pluginIcon: some View {
        let icon = AppIcon(rawValue: plugin.iconName) ?? .extensions
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.quaternary.opacity(0.6))
            .overlay(
                Image(nsImage: icon.image(size: 16) ?? NSImage())
                    .renderingMode(.template)
                    .foregroundStyle(state.isInstalled ? (theme?.accent ?? .accentColor) : .secondary)
            )
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actionControl: some View {
        switch state {
        case .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .installed:
            Button("Uninstall", role: .destructive) {
                model.store.uninstallPlugin(plugin.id)
            }
            .buttonStyle(.bordered)
        case .notInstalled, .failed:
            Button("Install") {
                model.store.installPlugin(plugin.id)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
