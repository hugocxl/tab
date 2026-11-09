import AppKit
import SwiftUI
import TabCore

/// Theme previews for the two system appearances, using the existing settings actions.
struct ThemesPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var appTheme: AppTheme
    @Environment(\.settingsTheme) private var theme

    init(model: SettingsModel) {
        self.model = model
        appTheme = model.store.theme
    }

    var body: some View {
        Form {
            ForEach(["application", "configuration"], id: \.self) { id in
                if let message = model.store.errors[id] {
                    Section {
                        HStack(alignment: .firstTextBaseline) {
                            Label {
                                Text(message)
                            } icon: {
                                Image(.triangleAlertFill, size: 13)
                            }
                                .foregroundStyle(theme?.danger ?? .red)
                            Spacer()
                            Button("Dismiss") { model.store.dismissError(id) }
                        }
                        .listRowBackground(theme?.card)
                    }
                }
            }
            mode(dark: false)
            mode(dark: true)
            if !model.store.theme.catalog.errors.isEmpty {
                Section {
                    ForEach(model.store.theme.catalog.errors, id: \.self) { problem in
                        Text(problem).font(.subheadline).foregroundStyle(theme?.danger ?? .red)
                            .listRowBackground(theme?.card)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background { theme?.background.ignoresSafeArea() }
    }

    private func mode(dark: Bool) -> some View {
        let appearance = model.store.settings.appearance
        let selected = dark ? appearance.darkTheme : appearance.lightTheme
        let catalog = appTheme.catalog
        let defaultName = dark ? ThemeCatalog.defaultDark : ThemeCatalog.defaultLight
        let current = catalog.find(selected)?.name ?? defaultName
        let defaults = catalog.entries.filter { $0.name == defaultName }
        let remaining = catalog.entries.filter { $0.name != defaultName }
        // Keep every existing choice available, with this mode's colors first.
        let others = remaining.filter { ChromePalette(scheme: $0.scheme).isLight != dark }
            + remaining.filter { ChromePalette(scheme: $0.scheme).isLight == dark }
        let error = model.store.errors[dark ? "dark-theme" : "light-theme"]
        return Section {
            ScrollViewReader { proxy in
                SwiftUI.ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        if !defaults.isEmpty {
                            themeGroup("Default", entries: defaults, selected: current, dark: dark)
                            Rectangle()
                                .fill(theme?.secondaryText.opacity(0.2) ?? .clear)
                                .frame(width: 1, height: 76)
                                .padding(.top, 40)
                        }
                        themeGroup("Themes", entries: others, selected: current, dark: dark)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    if current != defaultName { proxy.scrollTo(current, anchor: .center) }
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(theme?.card)
        } header: {
            HStack(spacing: 6) {
                Text(dark ? "Dark Mode" : "Light Mode")
                if appTheme.interfaceIsDark == dark {
                    Text("Active").foregroundStyle(.secondary).fontWeight(.regular)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if catalog.find(selected) == nil {
                    Text("“\(selected)” is unavailable. Using \(defaultName).")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.subheadline).foregroundStyle(theme?.danger ?? .red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func themeGroup(_ title: String, entries: [ThemeEntry], selected: String, dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(entries, id: \.name) { entry in
                    ThemePreviewCard(entry: entry, selected: entry.name == selected, appTheme: model.store.theme) {
                        model.store.setTheme(dark: dark, entry.name)
                    }
                    .id(entry.name)
                }
            }
        }
    }
}

private struct ThemePreviewCard: View {
    let entry: ThemeEntry
    let selected: Bool
    let appTheme: AppTheme
    let choose: () -> Void
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 9) {
                preview
                    .overlay {
                        RoundedRectangle(cornerRadius: 22)
                            .strokeBorder(selected ? SwiftUI.Color(nsColor: appTheme.info) : foreground.opacity(0.12), lineWidth: selected ? 3 : 1)
                    }
                Text(entry.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? theme?.text ?? .primary : theme?.secondaryText ?? .secondary)
                    .lineLimit(1)
                    .frame(width: 144)
            }
            .padding(3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.name)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(entry.name)
    }

    private var preview: some View {
        VStack(spacing: 13) {
            HStack(spacing: 10) {
                Text("Aa").font(.system(size: 27, weight: .medium))
                    .foregroundStyle(foreground)
                Spacer(minLength: 0)
                Text("~/").font(.system(size: 21, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color(entry.scheme.selectionForeground, fallback: foregroundRGB))
                    .padding(.horizontal, 5).frame(height: 30)
                    .background(color(entry.scheme.selectionBackground, fallback: accentRGB), in: RoundedRectangle(cornerRadius: 6))
                Text("_").font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color(entry.scheme.cursorText, fallback: backgroundRGB))
                    .frame(width: 17, height: 30)
                    .background(color(entry.scheme.cursorColor, fallback: accentRGB), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: -3) {
                ForEach(0..<8) { index in
                    Circle()
                        .fill(SwiftUI.Color(nsColor: (entry.scheme.palette[index] ?? foregroundRGB).nsColor))
                        .frame(width: 18, height: 18)
                        .overlay { Circle().strokeBorder(previewBackground, lineWidth: 1) }
                        .zIndex(Double(8 - index))
                }
            }
        }
        .padding(13)
        .frame(width: 150, height: 94)
        .background(previewBackground, in: RoundedRectangle(cornerRadius: 22))
    }

    private var backgroundRGB: TabCore.RGBColor { entry.scheme.background ?? TabCore.RGBColor(appTheme.bg) }
    private var foregroundRGB: TabCore.RGBColor { entry.scheme.foreground ?? TabCore.RGBColor(appTheme.fg) }
    private var accentRGB: TabCore.RGBColor { entry.scheme.palette[4] ?? TabCore.RGBColor(appTheme.accent) }
    private var previewBackground: SwiftUI.Color { SwiftUI.Color(nsColor: backgroundRGB.nsColor) }
    private var foreground: SwiftUI.Color { SwiftUI.Color(nsColor: foregroundRGB.nsColor) }

    private func color(_ value: CellColor?, fallback: TabCore.RGBColor) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: (value?.resolve(foreground: foregroundRGB, background: backgroundRGB) ?? fallback).nsColor)
    }
}
