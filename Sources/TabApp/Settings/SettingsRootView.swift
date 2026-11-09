import SwiftUI

/// The Settings window's content, laid out like System Settings: a sidebar
/// with search, the server tile and the categories, and the page as a grouped
/// form under a toolbar with back, forward and the page's title.
struct SettingsRootView: View {
    let remoteController: RemoteServersController?
    @ObservedObject var model: SettingsModel

    var body: some View {
        let theme = SettingsTheme(model.store.theme)
        NavigationSplitView {
            SettingsSidebar(model: model)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(SettingsWindowController.sidebarWidth)
        } detail: {
            SettingsPage(remoteController: remoteController, model: model)
                .navigationTitle(model.title)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        ControlGroup {
                            Button(action: model.goBack) {
                                Label { Text("Back") } icon: { Image(.chevronLeft, size: 13) }
                            }
                                .disabled(!model.canGoBack)
                            Button(action: model.goForward) {
                                Label { Text("Forward") } icon: { Image(.chevronRight, size: 13) }
                            }
                                .disabled(!model.canGoForward)
                        }
                        .controlGroupStyle(.navigation)
                    }
                }
        }
        .searchable(
            text: Binding(get: { model.query }, set: { model.search($0) }),
            placement: .sidebar,
            prompt: "Search Settings"
        )
        .background { SettingsGlassBackground(theme: model.store.theme).ignoresSafeArea() }
        .environment(\.settingsTheme, theme)
        .foregroundStyle(theme.text)
        .tint(theme.accent)
    }
}

/// Settings uses the same desktop-sampling native material as the workspace.
private struct SettingsGlassBackground: NSViewRepresentable {
    @ObservedObject var theme: AppTheme

    func makeNSView(context: Context) -> GlassView {
        GlassView(style: .workspace, behindWindow: true)
    }

    func updateNSView(_ view: GlassView, context: Context) {
        view.isHidden = !theme.glassEnabled
        view.appearance = theme.nsAppearance
        view.tint = theme.chrome.withAlphaComponent(theme.isLight ? 0.35 : 0.65)
    }
}
