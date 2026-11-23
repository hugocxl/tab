import AppKit
import SwiftUI
import TabApp
import TabCore

/// Settings → Plugins → QuickShot: the capture shortcut, where captures go
/// and the permissions they need.
struct QuickShotSettingsView: View {
    let store: SettingsStore
    let config: QuickShotConfig
    @ObservedObject var status: QuickShotStatus
    let plugin: QuickShotPlugin
    @Environment(\.settingsTheme) private var theme
    @State private var recordError: String?

    var body: some View {
        Form {
            Section {
                Picker("Capture with", selection: binding(\.trigger)) {
                    Text("Left ⌘ + Right ⌘").tag(QuickShotConfig.Trigger.commandKeys)
                    Text("Custom shortcut").tag(QuickShotConfig.Trigger.shortcut)
                }
                .listRowBackground(theme?.card)
                if config.trigger == .shortcut {
                    LabeledContent("Shortcut") {
                        ShortcutRecorderField(
                            chord: config.shortcut,
                            placeholder: "Click to record",
                            label: "QuickShot shortcut",
                            onRecord: record,
                            onError: { recordError = $0 }
                        )
                        .fixedSize()
                    }
                    .listRowBackground(theme?.card)
                }
                LabeledContent("Status") {
                    Text(status.trigger.title)
                        .foregroundStyle(status.trigger.needsAttention ? (theme?.danger ?? .red) : (theme?.secondaryText ?? .secondary))
                }
                .listRowBackground(theme?.card)
            } header: {
                header("Shortcut", detail: triggerDetail)
            } footer: {
                if let recordError {
                    Text(recordError).foregroundStyle(theme?.danger ?? .red)
                }
            }

            Section {
                Picker("Copy to clipboard", selection: binding(\.clipboard)) {
                    Text("File path").tag(QuickShotConfig.Clipboard.path)
                    Text("Image").tag(QuickShotConfig.Clipboard.image)
                }
                .listRowBackground(theme?.card)
                Picker("Save to", selection: binding(\.destination)) {
                    Text("Desktop").tag(QuickShotConfig.Destination.desktop)
                    Text("Temporary folder, deleted after 24 hours").tag(QuickShotConfig.Destination.temporary)
                }
                .listRowBackground(theme?.card)
                Toggle("Play shutter sound", isOn: binding(\.playsSound))
                    .listRowBackground(theme?.card)
                Toggle("Show preview", isOn: binding(\.showsPreview))
                    .listRowBackground(theme?.card)
                HStack {
                    Button("Take Screenshot") { plugin.capture() }
                    Button("Show in Finder") { plugin.revealFolder() }
                    Spacer()
                }
                .listRowBackground(theme?.card)
            } header: {
                header("Capture", detail: "QuickShot saves the display under the pointer as a full-resolution PNG.")
            }

            Section {
                permissionRow(
                    "Screen Recording",
                    allowed: status.screenRecordingAllowed,
                    pane: "Privacy_ScreenCapture",
                    request: { CGRequestScreenCaptureAccess() }
                )
                if config.trigger == .commandKeys {
                    permissionRow(
                        "Input Monitoring",
                        allowed: status.inputMonitoringAllowed,
                        pane: "Privacy_ListenEvent",
                        request: { CGRequestListenEventAccess() }
                    )
                }
            } header: {
                header("Permissions", detail: "macOS asks once. If Tab was denied, allow it in System Settings, then return to Tab.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background { theme?.background.ignoresSafeArea() }
        .onAppear { plugin.refresh(reset: false) }
    }

    private var triggerDetail: String {
        switch config.trigger {
        case .commandKeys:
            return "Press both Command keys together from any app. This needs Input Monitoring."
        case .shortcut:
            return "Press your shortcut from any app. It needs no extra permission."
        }
    }

    private func header(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ title: String, allowed: Bool, pane: String, request: @escaping () -> Bool) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(allowed ? "Allowed" : "Not allowed")
                    .foregroundStyle(allowed ? (theme?.secondaryText ?? .secondary) : (theme?.danger ?? .red))
                if !allowed {
                    Button("Allow…") {
                        if !request() { PrivacyPermission.openSettings(pane) }
                        plugin.refresh(reset: true)
                    }
                }
            }
        }
        .listRowBackground(theme?.card)
    }

    /// Accepts a chord that has a modifier, a key QuickShot can listen for,
    /// and no Tab command already bound to it.
    private func record(_ chord: KeyChord) -> String? {
        if let problem = QuickShotShortcutRules.problem(with: chord, keymap: store.settings.keymap) { return problem }
        var next = config
        next.shortcut = chord
        save(next)
        return nil
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<QuickShotConfig, Value>) -> Binding<Value> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { value in
                var next = config
                next[keyPath: keyPath] = value
                save(next)
            }
        )
    }

    private func save(_ next: QuickShotConfig) {
        guard next != config else { return }
        store.updatePluginConfig(.quickshot, next)
    }
}

/// Which recorded chords can trigger QuickShot.
enum QuickShotShortcutRules {
    static func problem(with chord: KeyChord, keymap: Keymap) -> String? {
        let modifiers = chord.modifiers
        guard !modifiers.intersection([.command, .control, .option]).isEmpty else {
            return "Use ⌘, ⌃ or ⌥ so the shortcut doesn't block typing."
        }
        guard !modifiers.contains(.function) else {
            return "Shortcuts with fn can't be used system-wide."
        }
        guard KeyCodes.virtualKeyCode(for: chord.key) != nil else {
            return "QuickShot can't listen for \(chord.display)."
        }
        if keymap.action(for: chord) != nil {
            return "Tab already uses \(chord.display)."
        }
        return nil
    }
}
