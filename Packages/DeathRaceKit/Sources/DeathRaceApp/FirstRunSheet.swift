import AppCore
import AppKit
import ConfigKit
import LegendsUI
import Observation
import SwiftUI

/// The welcome, on the window in front: a theme, the hosts `~/.ssh/config` names, and Lucid
/// Dreams' shortcut. Each choice is saved as it is made, the way Settings saves, so the window
/// behind takes a theme at once and Done only closes the sheet.
@MainActor
final class FirstRunSheet {
    let model: FirstRunModel
    private let sheet: ThemedSheet

    init(model: FirstRunModel, parent: NSWindow?, chrome: Chrome) {
        self.model = model
        sheet = ThemedSheet(title: "Welcome", parent: parent, chrome: chrome)
    }

    var panel: NSPanel { sheet.panel }

    func show() {
        sheet.show(FirstRunView(model: model))
    }

    func bringForward() {
        sheet.bringForward()
    }

    func close() {
        sheet.close()
    }

    /// The settings as the file now says: a theme chosen here or in an editor, and whether
    /// macOS took the shortcut.
    func update(config: Config, chrome: Chrome, shortcutWorks: Bool) {
        sheet.setChrome(chrome)
        let palette = LegendsPalette(chrome)
        if model.palette != palette { model.palette = palette }
        if model.theme != config.namedTheme.id { model.theme = config.namedTheme.id }
        if model.shortcut != config.lucidDreamsHotkey { model.shortcut = config.lucidDreamsHotkey }
        if model.shortcutWorks != shortcutWorks { model.shortcutWorks = shortcutWorks }
    }
}

/// What the welcome shows, and what its choices ask for. The app saves each one and reads
/// the file again, which brings the model up to date; the model keeps only why a choice
/// couldn't be saved.
@MainActor
@Observable
final class FirstRunModel {
    var palette: LegendsPalette
    /// The theme's id.
    var theme: String
    /// `lucid-dreams-hotkey` as the file says it.
    var shortcut: String
    /// False when macOS refused that shortcut.
    var shortcutWorks: Bool
    /// The names in ~/.ssh/config WRLD doesn't hold yet.
    var importable: [String]
    /// How many hosts were added from here.
    var added = 0
    /// Why the last choice couldn't be saved.
    var problem: String?

    /// Saves a theme; why it couldn't, when it couldn't.
    @ObservationIgnored var onTheme: ((String) -> String?)?
    /// Saves Lucid Dreams' shortcut; why it couldn't, when it couldn't.
    @ObservationIgnored var onShortcut: ((String) -> String?)?
    /// Adds hosts to WRLD by their ~/.ssh/config names; why it couldn't, when it couldn't.
    @ObservationIgnored var onImport: (([String]) -> String?)?
    @ObservationIgnored var onDone: (() -> Void)?

    init(palette: LegendsPalette, theme: String, shortcut: String, shortcutWorks: Bool, importable: [String]) {
        self.palette = palette
        self.theme = theme
        self.shortcut = shortcut
        self.shortcutWorks = shortcutWorks
        self.importable = importable
    }

    func choose(theme id: String) {
        problem = onTheme?(id)
    }

    func choose(shortcut value: String) {
        problem = onShortcut?(value)
    }

    func importHosts() {
        let names = importable
        guard !names.isEmpty else { return }
        if let failure = onImport?(names) {
            problem = failure
            return
        }
        added += names.count
        importable = []
        problem = nil
    }

    func done() {
        onDone?()
    }
}

/// The three parts, each under its label, and Done.
struct FirstRunView: View {
    let model: FirstRunModel
    /// The eight themes, four to a row. Rows of equal shares rather than a lazy grid: nothing
    /// here scrolls, and the panel takes its height from what the rows ask for.
    private let rows = stride(from: 0, to: ThemeCatalog.all.count, by: 4).map {
        Array(ThemeCatalog.all[$0..<min($0 + 4, ThemeCatalog.all.count)])
    }

    var body: some View {
        SheetLayout(
            symbol: "sparkles", title: "Welcome to Death Race for Code",
            subtitle: "Pick a look, bring in your servers and choose a shortcut. Each can be changed later."
        ) {
            LabeledField("Theme") {
                VStack(spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 10) {
                            ForEach(row) { theme in
                                ThemeSwatch(theme: theme, isCurrent: theme.id == model.theme) {
                                    model.choose(theme: theme.id)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            LabeledField("Your servers") { servers }
            LabeledField("Quick terminal") { quickTerminal }
            if let problem = model.problem {
                Text(problem)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(model.palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } buttons: {
            Button("Done") { model.done() }
                .buttonStyle(.wrld(.primary))
                .keyboardShortcut(.defaultAction)
        }
        // The model's palette, not the one the sheet was made with: a theme chosen here
        // recolours the welcome along with the window behind it.
        .environment(\.legends, model.palette)
        .preferredColorScheme(model.palette.isLight ? .light : .dark)
    }

    /// The offer to add what ~/.ssh/config names, what was added, or where to add one.
    @ViewBuilder private var servers: some View {
        if model.added > 0 {
            note(FirstRun.added(count: model.added) + " Open WRLD with ⌘O to see them.")
        } else if model.importable.isEmpty {
            note("Nothing in ~/.ssh/config to bring in. Add a host any time with Shell › New Host….")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WRLDBoard.importTitle(count: model.importable.count))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(model.palette.ink)
                        Text(FirstRun.names(model.importable))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(model.palette.inkMuted)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button("Add to WRLD") { model.importHosts() }.buttonStyle(.wrld(.plain))
                }
                note("They keep working in plain ssh too. Nothing in the file changes.")
            }
        }
    }

    /// Lucid Dreams' shortcut, chosen from four, and whether macOS took it.
    private var quickTerminal: some View {
        let chosen = FirstRun.shortcut(matching: model.shortcut)
        return VStack(alignment: .leading, spacing: 8) {
            note("Lucid Dreams drops a terminal from the top of the screen, over any app.")
            HStack(spacing: 6) {
                ForEach(FirstRun.shortcuts) { option in
                    Button(option.title) { model.choose(shortcut: option.value) }
                        .buttonStyle(.wrld(chosen == option ? .primary : .plain))
                        .accessibilityLabel(option.spoken)
                        .accessibilityAddTraits(chosen == option ? .isSelected : [])
                }
            }
            Text(FirstRun.shortcutNote(model.shortcut, works: model.shortcutWorks))
                .font(.system(size: 11.5, weight: model.shortcutWorks ? .regular : .medium))
                .foregroundStyle(model.shortcutWorks ? model.palette.inkMuted : model.palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5)).foregroundStyle(model.palette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
