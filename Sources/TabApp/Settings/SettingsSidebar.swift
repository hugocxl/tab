import AppKit
import SwiftUI

/// A category's icon: an SF Symbol on a gradient rounded square, like the
/// icons in System Settings.
struct SettingsIcon: View {
    let category: SettingsCategory
    var side: CGFloat = 20

    var body: some View {
        let icon = category.icon
        let shape = RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
        shape
            .fill(LinearGradient(colors: [SwiftUI.Color(hex: icon.top), SwiftUI.Color(hex: icon.bottom)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .overlay(shape.inset(by: 0.5).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .overlay(
                Image(systemName: icon.symbol)
                    .font(.system(size: side * 0.56, weight: .semibold))
                    .foregroundStyle(SwiftUI.Color(hex: icon.glyph))
            )
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

extension SwiftUI.Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// The Settings sidebar: the server tile, then the categories in groups.
/// The search field is the window's sidebar search.
struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel

    /// The categories under the server tile, split where a group starts.
    static let groups: [[SettingsCategory]] = SettingsCategory.allCases
        .filter { $0 != .server }
        .reduce(into: [[]]) { groups, category in
            if category.startsGroup && !(groups.last?.isEmpty ?? true) { groups.append([]) }
            groups[groups.count - 1].append(category)
        }

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { if let category = $0 { model.select(category) } })) {
            Section {
                ServerTile(state: model.store.serverState)
                    .tag(SettingsCategory.server)
            }
            ForEach(Self.groups, id: \.self) { group in
                Section {
                    ForEach(group, id: \.self) { category in
                        Label {
                            Text(category.title)
                        } icon: {
                            SettingsIcon(category: category)
                        }
                        .tag(category)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// The server's row: the app icon, "Server" and its connection state.
struct ServerTile: View {
    let state: ServerConnectionState

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Server").font(.body.weight(.semibold))
                Text(state.title).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Server, \(state.title)")
    }
}
