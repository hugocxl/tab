import SwiftUI

/// The Settings window's content, laid out like System Settings: a sidebar
/// with search, the server tile and the categories, and the page as a grouped
/// form under a toolbar with back, forward and the page's title.
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let theme = SettingsTheme(model.store.theme)
        NavigationSplitView {
            SettingsSidebar(model: model)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(SettingsWindowController.sidebarWidth)
        } detail: {
            SettingsPage(model: model)
                .navigationTitle(model.title)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        ControlGroup {
                            Button("Back", systemImage: "chevron.left", action: model.goBack)
                                .disabled(!model.canGoBack)
                            Button("Forward", systemImage: "chevron.right", action: model.goForward)
                                .disabled(!model.canGoForward)
                        }
                        .controlGroupStyle(.navigation)
                    }
                    if let file = model.configurationFile {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Edit in \(file)") { model.store.openConfiguration(file) }
                        }
                    }
                }
        }
        .searchable(
            text: Binding(get: { model.query }, set: { model.search($0) }),
            placement: .sidebar,
            prompt: "Search Settings"
        )
        .environment(\.settingsTheme, theme)
        .foregroundStyle(theme.text)
        .tint(theme.accent)
    }
}
