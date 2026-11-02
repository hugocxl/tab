import AppKit
import SwiftUI
import TabClient
import TabCore

/// The open page, or the search results, as a grouped form like System
/// Settings: a section per group of rows, notes under them.
struct SettingsPage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        if model.category == .changelog && !model.isSearching {
            ChangelogPage(changelog: model.changelog, installed: Release.version)
        } else if model.category == .interface && !model.isSearching {
            InterfacePage(model: model)
        } else if model.category == .appearance && !model.isSearching {
            ThemesPage(model: model)
        } else if model.category == .keyboard && !model.isSearching {
            ShortcutsPage(model: model)
        } else {
            settings
        }
    }

    private var settings: some View {
        Form {
            ForEach(["application", "configuration"], id: \.self) { id in
                if let message = model.store.errors[id] {
                    Section {
                        HStack(alignment: .firstTextBaseline) {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(theme?.danger ?? .red)
                            Spacer()
                            Button("Dismiss") { model.store.dismissError(id) }
                        }
                    }
                }
            }
            if let build = model.lastBuild {
                if build.groups.isEmpty && build.isSearching {
                    Section {
                        Text("No settings match “\(model.query)”.").foregroundStyle(.secondary)
                    }
                }
                if model.category == .server && !model.isSearching {
                    Section {
                        ServerSettingsHeader(model: model, build: build)
                            .listRowBackground(theme?.card)
                    }
                }
                ForEach(build.groups.filter { model.isSearching || model.category != .server || $0.category != .server }) { group in
                    let parts = Self.parts(of: group)
                    ForEach(parts.indices, id: \.self) { index in
                        section(parts[index], title: index == 0 ? build.title(group) : nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background { theme?.background.ignoresSafeArea() }
    }

    /// A run of rows and the notes that follow them.
    private struct Part {
        var rows: [SettingRow] = []
        var notes: [SettingControl] = []
    }

    /// Splits a group where a note is followed by more rows.
    private static func parts(of group: SettingsPageBuilder.Group) -> [Part] {
        var parts: [Part] = [Part()]
        for block in group.blocks {
            switch block {
            case .row(let row):
                if !parts[parts.count - 1].notes.isEmpty && !parts[parts.count - 1].rows.isEmpty { parts.append(Part()) }
                parts[parts.count - 1].rows.append(row)
            case .below(let note):
                parts[parts.count - 1].notes.append(note)
            }
        }
        return parts
    }

    @ViewBuilder
    private func section(_ part: Part, title: String?) -> some View {
        if part.rows.isEmpty {
            // Notes with no rows above them, such as the Commands page's heading.
            Section {
                ForEach(part.notes.indices, id: \.self) { index in
                    SettingControlView(control: part.notes[index], model: model)
                        .listRowBackground(theme?.card)
                }
            } header: {
                if let title { Text(title) }
            }
        } else {
            Section {
                ForEach(part.rows) { row in
                    SettingRowView(row: row, model: model)
                        .listRowBackground(theme?.card)
                }
            } header: {
                if let title { Text(title) }
            } footer: {
                if !part.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(part.notes.indices, id: \.self) { index in
                            SettingControlView(control: part.notes[index], model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A setting's label with its description and refusal under it.
private struct SettingLabel: View {
    let row: SettingRow
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.label)
            if let description = row.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = row.error {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(theme?.danger ?? .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row: the label beside its control, or above it when stacked. A row
/// without a label is its control alone, and a disclosure row opens a page.
struct SettingRowView: View {
    let row: SettingRow
    @ObservedObject var model: SettingsModel

    var body: some View {
        if row.label.isEmpty, let control = row.control {
            SettingControlView(control: control, model: model)
        } else if case .disclosure(let open)? = row.control {
            Button(action: open) {
                LabeledContent {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                } label: {
                    SettingLabel(row: row)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if let control = row.control, !row.stacked {
            LabeledContent {
                SettingControlView(control: control, model: model)
            } label: {
                SettingLabel(row: row)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                SettingLabel(row: row)
                if let control = row.control {
                    SettingControlView(control: control, model: model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A `SettingControl` as native controls.
struct SettingControlView: View {
    let control: SettingControl
    @ObservedObject var model: SettingsModel

    var body: some View {
        switch control {
        case .toggle(let spec):
            Toggle(spec.label, isOn: Binding(get: { spec.isOn }, set: { spec.change($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!spec.enabled)
        case .choice(let spec):
            ChoiceView(spec: spec)
        case .segmented(let spec):
            Picker(spec.label, selection: Binding(get: { spec.selected }, set: { spec.change($0) })) {
                ForEach(spec.titles.indices, id: \.self) { index in
                    Text(spec.titles[index]).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        case .stepper(let spec):
            StepperView(spec: spec)
        case .fontName(let family, let style):
            Text(family)
                .font(Font(NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family, .face: style]),
                                  size: NSFont.systemFontSize) ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)))
        case .preview(let spec):
            TerminalPreviewView(spec: spec)
        case .disclosure:
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        case .text(let spec):
            TextFieldView(spec: spec, model: model)
        case .button(let spec):
            ButtonView(spec: spec)
        case .color(let spec):
            ColorPicker(spec.label, selection: Binding(
                get: { spec.color.map { SwiftUI.Color(nsColor: $0.nsColor) } ?? .clear },
                set: { spec.pick(TabCore.RGBColor(NSColor($0))) }
            ), supportsOpacity: false)
            .labelsHidden()
        case .shortcut(let spec):
            ShortcutRecorderView(spec: spec)
                .fixedSize()
        case .label(let text, let style):
            LabelView(text: text, style: style)
        case .keys(let chord):
            Text(chord.display)
                .font(.body.monospaced())
                .accessibilityLabel(chord.rawValue)
        case .qrCode(let code):
            QRCodeImage(code: code)
                .frame(width: 200, height: 200)
        case .row(let children):
            HStack(spacing: 8) {
                ForEach(children.indices, id: \.self) { index in
                    SettingControlView(control: children[index], model: model)
                }
            }
        case .column(let children, let trailing):
            VStack(alignment: trailing ? .trailing : .leading, spacing: 8) {
                ForEach(children.indices, id: \.self) { index in
                    SettingControlView(control: children[index], model: model)
                }
            }
        }
    }
}

private struct LabelView: View {
    let text: String
    let style: SettingControl.LabelStyle
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        switch style {
        case .body:
            Text(text)
        case .secondary:
            Text(text).foregroundStyle(.secondary)
        case .note:
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .error:
            Text(text).font(.subheadline).foregroundStyle(theme?.danger ?? .red).fixedSize(horizontal: false, vertical: true)
        case .monospaced:
            Text(text).font(.body.monospaced())
        case .badge:
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct ChoiceView: View {
    let spec: ChoiceSpec

    var body: some View {
        if spec.isMenu {
            Menu(spec.placeholder ?? spec.label) {
                ForEach(spec.items.indices, id: \.self) { index in
                    Button(spec.items[index].title) { spec.change(spec.items[index].id) }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            picker
        }
    }

    private var picker: some View {
        Picker(spec.label, selection: Binding(get: { spec.selected }, set: { spec.change($0) })) {
            if let placeholder = spec.placeholder, !spec.items.contains(where: { $0.id == spec.selected }) {
                Text(placeholder).tag(spec.selected)
                SwiftUI.Divider()
            }
            ForEach(spec.items.indices, id: \.self) { index in
                let item = spec.items[index]
                if item.separatorBefore { SwiftUI.Divider() }
                Text(item.title).tag(item.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

/// A number field with stepper arrows, saved on Return, leaving it, or a step.
private struct StepperView: View {
    let spec: StepperSpec
    @State private var text: String
    @FocusState private var focused: Bool

    init(spec: StepperSpec) {
        self.spec = spec
        _text = State(initialValue: spec.text)
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField(spec.label, text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .monospacedDigit()
                .frame(width: 56)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .onChange(of: spec.value) { _, _ in
                    if !focused { text = spec.text }
                }
            Stepper(spec.label) {
                spec.commit(min(spec.value + spec.step, spec.range.upperBound))
            } onDecrement: {
                spec.commit(max(spec.value - spec.step, spec.range.lowerBound))
            }
            .labelsHidden()
            if let unit = spec.unit {
                Text(unit).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }

    private func commit() {
        guard let value = spec.parse(text) else {
            text = spec.text
            return
        }
        text = StepperSpec.format(value, step: spec.step)
        if value != spec.value { spec.commit(value) }
    }
}

/// A terminal sample on its terminal background; the cursor sample blinks
/// at the chosen speed.
private struct TerminalPreviewView: View {
    let spec: PreviewSpec
    @Environment(\.displayScale) private var scale

    var body: some View {
        if spec.preview == .cursor, let interval = spec.settings.cursorBlink.interval {
            TimelineView(.periodic(from: .now, by: interval)) { context in
                sample(cursor: Int(context.date.timeIntervalSinceReferenceDate / interval) % 2 == 0)
            }
        } else {
            sample(cursor: true)
        }
    }

    private func sample(cursor: Bool) -> some View {
        HStack(spacing: 0) {
            if let image = spec.preview.image(settings: spec.settings, palette: spec.palette, cursor: cursor, scale: scale) {
                Image(nsImage: image).accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SwiftUI.Color(cgColor: spec.palette.cgColor(spec.palette.background)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}

/// A text field saved on Return, on leaving it, or when Settings closes.
private struct TextFieldView: View {
    let spec: TextSpec
    @ObservedObject var model: SettingsModel
    @State private var text: String
    @FocusState private var focused: Bool

    init(spec: TextSpec, model: SettingsModel) {
        self.spec = spec
        self.model = model
        _text = State(initialValue: spec.value)
    }

    var body: some View {
        TextField(spec.label, text: $text, prompt: Text(spec.placeholder), axis: spec.multiline ? .vertical : .horizontal)
            .lineLimit(spec.multiline ? 4...10 : 1...1)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
            .labelsHidden()
            .font(spec.monospaced ? .body.monospaced() : .body)
            .frame(width: spec.width)
            .frame(maxWidth: spec.width == nil ? .infinity : nil)
            .disabled(!spec.enabled)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: text) { _, new in
                guard focused else { return }
                spec.change?(new)
                let commit = spec.commit
                model.editing(spec.id) { commit(new) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onChange(of: spec.value) { _, new in
                if !focused { text = new }
            }
    }

    private func commit() {
        model.editing(spec.id, save: nil)
        guard text != spec.value else { return }
        spec.commit(text)
    }
}

private struct ButtonView: View {
    let spec: ButtonSpec

    var body: some View {
        let button = Button(role: spec.style == .destructive ? .destructive : nil, action: spec.action) {
            if let symbol = spec.symbol {
                Image(systemName: symbol).accessibilityLabel(spec.title)
            } else {
                Text(spec.title)
            }
        }
        .disabled(!spec.enabled)
        .help(spec.help ?? (spec.symbol == nil ? "" : spec.title))
        if spec.symbol != nil {
            button.buttonStyle(.borderless)
        } else if spec.style == .primary {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }
}

/// The AppKit shortcut recorder, which records key chords SwiftUI can't.
private struct ShortcutRecorderView: NSViewRepresentable {
    let spec: ShortcutSpec

    func makeNSView(context: Context) -> ShortcutRecorder {
        let recorder = ShortcutRecorder(chord: spec.chord, placeholder: spec.placeholder, label: spec.label)
        update(recorder)
        return recorder
    }

    func updateNSView(_ recorder: ShortcutRecorder, context: Context) {
        update(recorder)
    }

    private func update(_ recorder: ShortcutRecorder) {
        recorder.placeholder = spec.placeholder
        if !recorder.isRecording && recorder.chord != spec.chord { recorder.setChord(spec.chord) }
        recorder.onRecord = spec.record
        recorder.onError = spec.error
    }
}

/// A QR code, dark modules on white with its quiet zone.
private struct QRCodeImage: View {
    let code: QRCode

    var body: some View {
        Canvas { context, size in
            let span = CGFloat(code.size + 2 * QRCode.quietZone)
            let module = floor(min(size.width, size.height) / span)
            guard module > 0 else { return }
            let origin = CGPoint(
                x: ((size.width - module * span) / 2).rounded() + module * CGFloat(QRCode.quietZone),
                y: ((size.height - module * span) / 2).rounded() + module * CGFloat(QRCode.quietZone)
            )
            var path = Path()
            for y in 0..<code.size {
                for x in 0..<code.size where code.isDark(x: x, y: y) {
                    path.addRect(CGRect(x: origin.x + CGFloat(x) * module, y: origin.y + CGFloat(y) * module, width: module, height: module))
                }
            }
            context.fill(path, with: .color(.black))
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Pairing code")
        .accessibilityAddTraits(.isImage)
    }
}
