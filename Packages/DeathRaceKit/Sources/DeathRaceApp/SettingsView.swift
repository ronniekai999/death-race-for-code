import AppCore
import ConfigKit
import LegendsUI
import SwiftUI
import VTCore

/// Settings: the pages down the side, the chosen page's settings beside them, all in the
/// theme's colors. Every control writes the file and the app applies it at once.
struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
            Rectangle().fill(model.palette.line).frame(width: 1)
            SettingsPageView(model: model)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(model.palette.ground)
        // Up under the transparent title bar; the pages leave room for the traffic lights.
        .ignoresSafeArea()
        .environment(\.legends, model.palette)
        .preferredColorScheme(model.palette.isLight ? .light : .dark)
    }
}

struct SettingsSidebar: View {
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsCatalog.Page.allCases) { page in
                SidebarItem(page: page, isSelected: model.page == page) { model.page = page }
            }
            Spacer(minLength: 0)
        }
        // Clear of the traffic lights, which sit over the content.
        .padding(.top, 48)
        .padding(.horizontal, 12)
        .frame(width: 196)
        .background(model.palette.groundDeep)
    }
}

struct SidebarItem: View {
    let page: SettingsCatalog.Page
    let isSelected: Bool
    let select: () -> Void
    @Environment(\.legends) private var palette

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol).frame(width: 18)
                Text(page.rawValue)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? palette.ink : palette.inkMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? palette.surface : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct SettingsPageView: View {
    let model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(model.page.rawValue)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(model.palette.ink)
                switch model.page {
                case .keys: KeysPage()
                case .energy: EnergyPage(model: model)
                case .advanced: AdvancedPage(model: model)
                default: EmptyView()
                }
                ForEach(SettingsCatalog.groups(on: model.page)) { group in
                    SettingsGroupView(group: group, model: model)
                }
                if let problem = model.problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(model.palette.danger)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 48)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A titled card of settings.
struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.legends) private var palette

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(palette.inkFaint)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
        }
    }
}

struct SettingsGroupView: View {
    let group: SettingsCatalog.Group
    let model: SettingsModel

    var body: some View {
        SettingsCard(title: group.title) {
            ForEach(group.settings) { setting in
                SettingRow(setting: setting, model: model)
                if setting.id != group.settings.last?.id {
                    Rectangle().fill(model.palette.line).frame(height: 1)
                }
            }
        }
    }
}

struct SettingRow: View {
    let setting: SettingsCatalog.Setting
    let model: SettingsModel

    private var isTheme: Bool {
        if case .theme = setting.control { return true }
        return false
    }

    var body: some View {
        if isTheme {
            ThemeSwatches(setting: setting, model: model).padding(.vertical, 14)
        } else {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(setting.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(model.palette.ink)
                    if let note = setting.note {
                        Text(note).font(.system(size: 11)).foregroundStyle(model.palette.inkFaint)
                    }
                }
                Spacer(minLength: 12)
                SettingControl(setting: setting, model: model)
            }
            .padding(.vertical, 10)
        }
    }
}

struct SettingControl: View {
    let setting: SettingsCatalog.Setting
    let model: SettingsModel

    var body: some View {
        switch setting.control {
        case .toggle:
            Toggle(setting.label, isOn: model.bool(setting))
                .toggleStyle(.neon)
                .labelsHidden()
        case .choice(let choices):
            Picker(setting.label, selection: model.text(setting)) {
                ForEach(choices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 250)
        case .number(let range, let step, let unit):
            NumberControl(value: model.number(setting), range: range, step: step, unit: unit)
        case .megabytes(let range):
            NumberControl(
                value: model.number(setting), range: Double(range.lowerBound)...Double(range.upperBound), step: 10,
                unit: "MB")
        case .text(let placeholder):
            TextControl(setting: setting, model: model, placeholder: placeholder)
        case .fontFamily(let italic):
            FontControl(setting: setting, model: model, italic: italic)
        case .gridSize:
            GridControl(setting: setting, model: model)
        case .theme:
            EmptyView()
        }
    }
}

/// A slider and its value. The file is written when the drag ends, not on every step.
struct NumberControl: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    @State private var draft = 0.0
    @State private var dragging = false
    @Environment(\.legends) private var palette

    var body: some View {
        HStack(spacing: 10) {
            NeonSlider(value: $draft, in: range, step: step) { editing in
                dragging = editing
                if !editing { value.wrappedValue = draft }
            }
            .frame(width: 160)
            Text("\(Self.format(draft)) \(unit)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(palette.inkMuted)
                .frame(width: 72, alignment: .trailing)
        }
        .onAppear { draft = value.wrappedValue }
        .onChange(of: value.wrappedValue) { _, new in
            if !dragging { draft = new }
        }
    }

    static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }
}

/// Free text, written on Return or when the field loses focus, and only when the user
/// changed it: the file may have changed meanwhile (an edit in an editor), and its value
/// then shows here instead of being written over.
struct TextControl: View {
    let setting: SettingsCatalog.Setting
    let model: SettingsModel
    let placeholder: String
    @State private var draft = ""
    /// The file's value when `draft` last came from it.
    @State private var original = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 280)
            .focused($focused)
            .onSubmit { commit() }
            .onAppear {
                draft = model.textValue(setting)
                original = draft
            }
            .onChange(of: model.textValue(setting)) { _, value in
                // Untouched, the field follows the file.
                if draft == original { draft = value }
                original = value
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
    }

    private func commit() {
        guard draft != original else { return }
        model.set(setting, .text(draft))
    }
}

struct FontControl: View {
    let setting: SettingsCatalog.Setting
    let model: SettingsModel
    let italic: Bool

    var body: some View {
        Picker(setting.label, selection: model.text(setting)) {
            if italic {
                Text("The font's own").tag("")
            }
            ForEach(model.fontFamilies, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 250)
    }
}

struct GridControl: View {
    let setting: SettingsCatalog.Setting
    let model: SettingsModel
    @Environment(\.legends) private var palette

    var body: some View {
        HStack(spacing: 14) {
            Stepper(value: model.columns(setting), in: 20...500) {
                Text("\(model.gridValue(setting).columns) columns").foregroundStyle(palette.inkMuted)
            }
            Stepper(value: model.rows(setting), in: 4...200) {
                Text("\(model.gridValue(setting).rows) rows").foregroundStyle(palette.inkMuted)
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
    }
}

/// The eight themes as small windows: the ground, a card in the terminal's background with
/// six of its colors, and the gradient. Choosing one applies it at once.
struct ThemeSwatches: View {
    let setting: SettingsCatalog.Setting
    let model: SettingsModel

    private let columns = [GridItem](repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(ThemeCatalog.all) { theme in
                ThemeSwatch(theme: theme, isCurrent: theme.id == model.textValue(setting)) {
                    model.set(setting, .text(theme.id))
                }
            }
        }
    }
}

struct ThemeSwatch: View {
    let theme: NamedTheme
    let isCurrent: Bool
    let choose: () -> Void
    @Environment(\.legends) private var palette

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 8) {
                ThemePreview(theme: theme).frame(height: 64)
                Text(theme.name)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? palette.ink : palette.inkMuted)
                    .lineLimit(1)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isCurrent ? AnyShapeStyle(palette.borderGradient) : AnyShapeStyle(palette.line),
                        lineWidth: isCurrent ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

struct ThemePreview: View {
    let theme: NamedTheme

    var body: some View {
        let chrome = theme.chrome
        let terminal = theme.terminal.palette
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(swiftUIColor(chrome.ground))
            VStack(alignment: .leading, spacing: 5) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: chrome.gradient.map(swiftUIColor), startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: 44, height: 7)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(swiftUIColor(terminal.background))
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 3) {
                            ForEach(1..<7) { index in
                                Circle().fill(swiftUIColor(terminal.colors[index])).frame(width: 6, height: 6)
                            }
                        }
                        .padding(6)
                    }
            }
            .padding(8)
        }
    }
}

/// The read-only list of shortcuts, from the same table as the menus.
struct KeysPage: View {
    @Environment(\.legends) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("These are the shortcuts the menus show. They can't be changed yet.")
                .font(.system(size: 12))
                .foregroundStyle(palette.inkMuted)
            ForEach(Action.Group.allCases, id: \.self) { group in
                KeysGroup(group: group)
            }
        }
    }
}

struct KeysGroup: View {
    let group: Action.Group
    @Environment(\.legends) private var palette

    var body: some View {
        let actions = ActionCatalog.all.filter { $0.group == group && $0.shortcut != nil }
        SettingsCard(title: group.rawValue) {
            ForEach(actions) { action in
                HStack {
                    Text(action.paletteTitle).foregroundStyle(palette.ink)
                    Spacer()
                    Text(action.shortcut?.description ?? "")
                        .font(.system(size: 12, weight: .semibold).monospaced())
                        .foregroundStyle(palette.inkMuted)
                }
                .font(.system(size: 13))
                .padding(.vertical, 8)
            }
        }
    }
}

/// "Right now": what Death Race is using, measured while the page is open.
struct EnergyPage: View {
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard(title: "Right now") {
                HStack(spacing: 0) {
                    EnergyMeterView(title: "Processor", value: model.energy?.cpuText)
                    EnergyMeterView(title: "Wakeups", value: model.energy?.wakeupsText)
                    EnergyMeterView(title: "Drawing", value: model.energy?.framesText)
                }
                .padding(.vertical, 12)
            }
            Text("Measured every two seconds while this page is open; its own reading is left out.")
                .font(.system(size: 11))
                .foregroundStyle(model.palette.inkFaint)
            Text(
                "Tabs in the background already work on the efficiency cores, and draw nothing until they are shown."
            )
            .font(.system(size: 11))
            .foregroundStyle(model.palette.inkFaint)
        }
        .task { @MainActor in
            while !Task.isCancelled {
                model.sample()
                try? await Task.sleep(for: .seconds(EnergyMeter.interval))
            }
        }
        .onDisappear { model.stopSampling() }
    }
}

struct EnergyMeterView: View {
    let title: String
    let value: String?
    @Environment(\.legends) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.inkFaint)
            Text(value ?? "Measuring…")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AdvancedPage: View {
    let model: SettingsModel

    var body: some View {
        SettingsCard(title: "The settings file") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Every setting lives in one text file. This window edits it, and changes made in an editor show up here at once."
                )
                .font(.system(size: 12))
                .foregroundStyle(model.palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                Text(model.filePath)
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(model.palette.ink)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button("Open in Editor") { model.onOpenFile?() }
                    Button("Show in Finder") { model.onRevealFile?() }
                    Button("Reload") { model.onReload?() }
                }
            }
            .padding(.vertical, 14)
        }
    }
}

/// A theme color for SwiftUI.
func swiftUIColor(_ rgb: RGB) -> Color {
    Color(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
}
