import SwiftUI
import TabCore

/// Appearance previews share the same actions as searchable settings rows.
struct InterfacePage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        Form {
            if let build = model.lastBuild {
                ForEach(build.groups) { group in
                    Section {
                        if group.section == "Appearance" {
                            appearanceChoices
                                .padding(.vertical, 6)
                                .listRowBackground(theme?.card)
                        }
                        ForEach(rows(of: group)) { row in
                            SettingRowView(row: row, model: model)
                                .listRowBackground(theme?.card)
                        }
                    } header: {
                        Text(group.section)
                    } footer: {
                        if group.section == "Appearance" {
                            ForEach(["color-scheme", "interface-style"], id: \.self) { id in
                                if let error = model.store.errors[id] { Text(error).foregroundStyle(theme?.danger ?? .red) }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background { theme?.background.ignoresSafeArea() }
    }

    /// The group's rows, without the two the previews above replace.
    private func rows(of group: SettingsPageBuilder.Group) -> [SettingRow] {
        group.blocks.compactMap { block in
            guard case .row(let row) = block,
                  !["color-scheme", "interface-style"].contains(row.id),
                  row.id != "glass-panes" || model.store.settings.appearance.interfaceStyle == .glass else { return nil }
            return row
        }
    }

    private var appearanceChoices: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 16) {
                colorChoices.frame(width: max(geometry.size.width - 33, 0) * 0.6)
                SwiftUI.Divider()
                styleChoices
            }
        }
        .frame(height: 116)
    }

    private var colorChoices: some View {
        let selected = InterfaceColorScheme.allCases.firstIndex(of: model.store.settings.appearance.colorScheme) ?? 0
        return choices("Color scheme", titles: ["Auto", "Light", "Dark"], selected: selected, isStyle: false) { index in
            model.store.updateAppearance("color-scheme") { $0.colorScheme = InterfaceColorScheme.allCases[index] }
        }
    }

    private var styleChoices: some View {
        let selected = model.store.settings.appearance.interfaceStyle == InterfaceStyle.glass ? 1 : 0
        return choices("Interface style", titles: ["Classic", "Glass"], selected: selected, isStyle: true) { index in
            model.store.updateAppearance("interface-style") { $0.interfaceStyle = index == 1 ? InterfaceStyle.glass : InterfaceStyle.classic }
        }
    }

    private func choices(_ title: String, titles: [String], selected: Int, isStyle: Bool,
                         choose: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).fontWeight(.semibold).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(titles.indices, id: \.self) { index in
                    Button { choose(index) } label: {
                        VStack(spacing: 8) {
                            preview(index: index, isStyle: isStyle)
                                .frame(maxWidth: .infinity).frame(height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 15))
                                .overlay(RoundedRectangle(cornerRadius: 18)
                                    .stroke(selected == index ? (theme?.accent ?? .accentColor) : .clear, lineWidth: 3)
                                    .padding(-4))
                            Text(titles[index]).fontWeight(selected == index ? .semibold : .regular)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title): \(titles[index])")
                    .accessibilityAddTraits(selected == index ? [.isSelected] : [])
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func preview(index: Int, isStyle: Bool) -> some View {
        let accent = theme?.accent ?? .accentColor
        let solid = Color(nsColor: AppTheme.card(model.store.theme.palette).nsColor)
        return ZStack {
            LinearGradient(colors: [accent.opacity(0.65), accent, accent.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geometry in
                Ellipse().fill(accent.opacity(0.6))
                    .frame(width: geometry.size.width * 1.8, height: 40)
                    .rotationEffect(.degrees(-35)).offset(x: -20, y: 35)
            }
            if isStyle {
                Circle().fill(index == 1 ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(solid))
                    .overlay(Circle().strokeBorder((theme?.text ?? .primary).opacity(0.25), lineWidth: 0.75))
                    .frame(width: 48, height: 48)
            } else {
                let light = Color(nsColor: AppTheme.card(AppTheme.resolve(catalog: model.store.theme.catalog,
                    darkTheme: model.store.settings.appearance.darkTheme, lightTheme: model.store.settings.appearance.lightTheme, dark: false).1).nsColor)
                let dark = Color(nsColor: AppTheme.card(AppTheme.resolve(catalog: model.store.theme.catalog,
                    darkTheme: model.store.settings.appearance.darkTheme, lightTheme: model.store.settings.appearance.lightTheme, dark: true).1).nsColor)
                VStack(spacing: 3) {
                    HStack(spacing: 3) {
                        ForEach(0..<3) { _ in Circle().fill(accent).frame(width: 4, height: 4) }
                        Spacer()
                    }
                    RoundedRectangle(cornerRadius: 3).strokeBorder(accent.opacity(0.45)).frame(height: 19)
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(accent.opacity(0.45))
                        RoundedRectangle(cornerRadius: 3).strokeBorder(accent.opacity(0.45))
                    }
                }
                .padding(5).frame(width: 51, height: 51)
                .background {
                    HStack(spacing: 0) {
                        (index == 2 ? dark : light)
                        (index == 1 ? light : dark)
                    }
                    .opacity(model.store.settings.appearance.interfaceStyle == .glass && model.store.settings.appearance.glassPanes ? 0.65 : 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(accent.opacity(0.4)))
                .shadow(color: accent.opacity(0.35), radius: 5, y: 3)
            }
        }
    }
}
