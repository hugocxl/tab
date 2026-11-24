import SwiftUI
import TabApp
import TabCore

/// Settings → Plugins → AI Usage: how often the panel reads the limits and how it shows them.
struct UsageSettingsView: View {
    let store: SettingsStore
    let config: UsageConfig
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        Form {
            Section {
                Picker("Refresh", selection: binding(\.refreshMinutes)) {
                    ForEach(refreshChoices, id: \.self) { minutes in
                        Text(UsageConfig.refreshTitle(minutes)).tag(minutes)
                    }
                }
                .listRowBackground(theme?.card)
            } header: {
                header("Updates", detail: "While the AI Usage panel shows, it asks each agent's CLI for its limits again on this schedule. Each reading starts the CLIs briefly; none starts a conversation.")
            }

            Section {
                Picker("Order", selection: binding(\.order)) {
                    Text("Closest to its limit first").tag(UsageConfig.Order.urgency)
                    Text("By provider").tag(UsageConfig.Order.provider)
                }
                .listRowBackground(theme?.card)
                Picker("Show", selection: binding(\.figure)) {
                    Text("What is used").tag(UsageConfig.Figure.used)
                    Text("What is left").tag(UsageConfig.Figure.left)
                }
                .listRowBackground(theme?.card)
                Picker("Running low under", selection: binding(\.lowThreshold)) {
                    ForEach([15, 20, 30, 40], id: \.self) { percent in
                        Text("\(percent)% left").tag(percent)
                    }
                }
                .listRowBackground(theme?.card)
            } header: {
                header("Display", detail: "The panel's own buttons change the order and figures until Tab restarts; these are what it starts with.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// The preset intervals, plus a hand-edited one so the picker shows it.
    private var refreshChoices: [Int] {
        UsageConfig.refreshChoices.contains(config.refreshMinutes)
            ? UsageConfig.refreshChoices : (UsageConfig.refreshChoices + [config.refreshMinutes]).sorted()
    }

    private func header(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<UsageConfig, Value>) -> Binding<Value> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { value in
                var next = config
                next[keyPath: keyPath] = value
                store.updatePluginConfig(.usage, next)
            }
        )
    }
}
