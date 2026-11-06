import SwiftUI
import TabMobileKit
import TabProtocol

/// Settings: paired Macs, the terminal's text and themes, and versions.
struct SettingsView: View {
    let app: AppModel
    @Bindable var preferences: Preferences
    var onPair: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var forgetting: ServerModel?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(app.servers) { server in
                        ServerRow(server: server)
                            .swipeActions {
                                Button("Forget", role: .destructive) { forgetting = server }
                            }
                    }
                    Button {
                        dismiss()
                        onPair()
                    } label: {
                        Label("Pair Another Mac", systemImage: "qrcode.viewfinder")
                    }
                } header: {
                    Text("Macs")
                } footer: {
                    Text("To stop a device on the Mac, revoke it in Tab's Mobile settings.")
                }

                Section("Terminal") {
                    LabeledContent("Text Size") {
                        Stepper(value: $preferences.fontSize, in: 8...28, step: 1) {
                            Text("\(Int(preferences.fontSize)) pt").monospacedDigit()
                        }
                    }
                    ThemePicker(title: "Dark Theme", selection: $preferences.darkTheme)
                    ThemePicker(title: "Light Theme", selection: $preferences.lightTheme)
                    TerminalSample(preferences: preferences)
                        .listRowInsets(EdgeInsets())
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    LabeledContent("Speaks Tab", value: "Protocol \(ProtocolVersion.supported.map { String($0.rawValue) }.joined(separator: ", "))")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .confirmationDialog("Forget \(forgetting?.server.name ?? "this Mac")?", isPresented: .init(
                get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }
            ), titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    if let server = forgetting { app.forget(server.id) }
                }
            } message: {
                Text("You'll need a new pairing code to connect again.")
            }
        }
    }
}

private struct ServerRow: View {
    let server: ServerModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.server.name).font(.body.weight(.semibold))
                Text(server.server.lastHost ?? server.server.hosts.first ?? "")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(TabListViewController.describe(server.status))
                .font(.footnote)
                .foregroundStyle(server.status == .connected ? .green : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ThemePicker: View {
    let title: String
    @Binding var selection: String
    @State private var query = ""

    var body: some View {
        NavigationLink {
            List(Preferences.themeNames.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) },
                 id: \.self) { name in
                Button {
                    selection = name
                } label: {
                    HStack {
                        Text(name).foregroundStyle(.primary)
                        Spacer()
                        if name == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle(title)
        } label: {
            LabeledContent(title, value: selection)
        }
    }
}

/// A few lines in the chosen theme and size.
private struct TerminalSample: View {
    let preferences: Preferences
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = TerminalPalette(scheme: preferences.scheme(dark: colorScheme == .dark), dark: colorScheme == .dark)
        let font = Font.system(size: preferences.fontSize, design: .monospaced)
        VStack(alignment: .leading, spacing: 2) {
            let path = Text("~/code/tab").foregroundStyle(color(palette, 4))
            let branch = Text("main").foregroundStyle(color(palette, 5))
            Text("\(path) \(branch) ❯ swift test").foregroundStyle(SwiftUI.Color(palette.uiColor(palette.foreground)))
            Text("✔ Executed 412 tests, with 0 failures").foregroundStyle(color(palette, 2))
        }
        .font(font)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SwiftUI.Color(palette.uiColor(palette.background)))
    }

    private func color(_ palette: TerminalPalette, _ index: UInt8) -> SwiftUI.Color {
        SwiftUI.Color(palette.uiColor(palette.rgb(.indexed(index)) ?? palette.foreground))
    }
}
