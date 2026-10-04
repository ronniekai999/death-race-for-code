import AppCore
import AppKit
import ConfigKit
import Darwin
import LegendsUI
import Observation
import RenderKit
import SwiftUI
import VTCore

/// What the Settings window shows and changes. The settings are as the file was last read;
/// a change goes back to the app, which edits that one line of the file and reads it again,
/// so the window always shows what the file says.
@MainActor
@Observable
final class SettingsModel {
    var config: Config
    var page: SettingsCatalog.Page = .appearance
    var palette: LegendsPalette
    /// Why the last change could not be written.
    var problem: String?
    /// The Energy page's "Right now", while it is open.
    var energy: EnergyRates?

    let filePath: String
    @ObservationIgnored private var families: [String]?
    @ObservationIgnored var onSet: ((SettingsCatalog.Setting, SettingsCatalog.Value) -> Void)?
    @ObservationIgnored var onOpenFile: (() -> Void)?
    @ObservationIgnored var onRevealFile: (() -> Void)?
    @ObservationIgnored var onReload: (() -> Void)?
    @ObservationIgnored var sampleEnergy: (() -> EnergySample?)?
    @ObservationIgnored private var lastSample: EnergySample?

    init(config: Config, palette: LegendsPalette, filePath: String) {
        self.config = config
        self.palette = palette
        self.filePath = filePath
    }

    /// The font picker's list: SF Mono, the bundled families, then the installed monospaced
    /// ones. Found once, when first asked.
    var fontFamilies: [String] {
        if let families { return families }
        let found = Self.monospacedFamilies()
        families = found
        return found
    }

    func value(_ setting: SettingsCatalog.Setting) -> SettingsCatalog.Value {
        SettingsCatalog.value(of: setting, in: config)
    }

    func set(_ setting: SettingsCatalog.Setting, _ value: SettingsCatalog.Value) {
        guard value != self.value(setting) else { return }
        onSet?(setting, value)
    }

    func boolValue(_ setting: SettingsCatalog.Setting) -> Bool {
        if case .bool(let on) = value(setting) { return on }
        return false
    }

    func textValue(_ setting: SettingsCatalog.Setting) -> String {
        if case .text(let text) = value(setting) { return text }
        return ""
    }

    func numberValue(_ setting: SettingsCatalog.Setting) -> Double {
        if case .number(let number) = value(setting) { return number }
        return 0
    }

    // SwiftUI calls a Binding's closures on the main thread; `assumeIsolated` says so, which
    // holds whether or not the SDK marks them Sendable.

    /// A Binding for a switch.
    func bool(_ setting: SettingsCatalog.Setting) -> Binding<Bool> {
        Binding(
            get: { MainActor.assumeIsolated { self.boolValue(setting) } },
            set: { on in MainActor.assumeIsolated { self.set(setting, .bool(on)) } })
    }

    /// A Binding for a choice, a font or a theme: the text the file holds.
    func text(_ setting: SettingsCatalog.Setting) -> Binding<String> {
        Binding(
            get: { MainActor.assumeIsolated { self.textValue(setting) } },
            set: { text in MainActor.assumeIsolated { self.set(setting, .text(text)) } })
    }

    /// A Binding for a number.
    func number(_ setting: SettingsCatalog.Setting) -> Binding<Double> {
        Binding(
            get: { MainActor.assumeIsolated { self.numberValue(setting) } },
            set: { number in MainActor.assumeIsolated { self.set(setting, .number(number)) } })
    }

    func gridValue(_ setting: SettingsCatalog.Setting) -> (columns: Int, rows: Int) {
        if case .grid(let columns, let rows) = value(setting) { return (columns, rows) }
        return (config.windowSize.columns, config.windowSize.rows)
    }

    /// A Binding for the window size's columns.
    func columns(_ setting: SettingsCatalog.Setting) -> Binding<Int> {
        Binding(
            get: { MainActor.assumeIsolated { self.gridValue(setting).columns } },
            set: { columns in
                MainActor.assumeIsolated {
                    self.set(setting, .grid(columns: columns, rows: self.gridValue(setting).rows))
                }
            })
    }

    /// A Binding for the window size's rows.
    func rows(_ setting: SettingsCatalog.Setting) -> Binding<Int> {
        Binding(
            get: { MainActor.assumeIsolated { self.gridValue(setting).rows } },
            set: { rows in
                MainActor.assumeIsolated {
                    self.set(setting, .grid(columns: self.gridValue(setting).columns, rows: rows))
                }
            })
    }

    /// The Energy page's reading, every `EnergyMeter.interval` seconds while it is open.
    func sample() {
        guard let current = sampleEnergy?() else { return }
        if let lastSample { energy = EnergyMeter.rates(from: lastSample, to: current) ?? energy }
        lastSample = current
    }

    func stopSampling() {
        lastSample = nil
        energy = nil
    }

    static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        let installed = manager.availableFontFamilies.filter { family in
            manager.font(withFamily: family, traits: [], weight: 5, size: 13)?.isFixedPitch == true
        }
        let first = ["SF Mono"] + FontRegistry.bundledFamilies
        return first + installed.filter { !first.contains($0) && !$0.hasPrefix(".") }.sorted()
    }

    /// What the app has used so far: CPU time, wakeups and frames.
    static func processSample(frames: Int) -> EnergySample? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        // The times are in Mach time units, which are not nanoseconds on Apple silicon.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = usage.ri_user_time + usage.ri_system_time
        let nanoseconds = ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
        return EnergySample(
            time: ProcessInfo.processInfo.systemUptime, cpuNanoseconds: nanoseconds,
            wakeups: usage.ri_interrupt_wkups + usage.ri_pkg_idle_wkups, frames: frames)
    }
}

extension LegendsPalette {
    /// The palette for a theme's chrome.
    @MainActor
    init(_ chrome: Chrome) {
        let colors = chrome.colors
        func color(_ rgb: RGB) -> Color {
            Color(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
        }
        self.init(
            ground: color(colors.ground), groundDeep: color(colors.groundDeep), surface: color(colors.surface),
            surfaceHover: color(colors.surfaceHover), line: color(colors.line), lineStrong: color(colors.lineStrong),
            ink: color(colors.ink), inkMuted: color(colors.inkMuted), inkFaint: color(colors.inkFaint),
            accent: color(colors.accent), onAccent: color(colors.onAccent), glow: color(colors.glow),
            warning: color(colors.warning), danger: color(colors.danger), gradient: colors.gradient.map(color),
            isLight: chrome.theme.isLight)
    }
}
