import ConfigKit
import Testing

@testable import AppCore

@Suite struct SettingsCatalogTests {
    let all = SettingsCatalog.allSettings

    @Test func everySettingIsOnAPageOrLeftToTheFile() {
        let shown = all.map(\.key)
        #expect(Set(shown).count == shown.count, "a setting is on two pages")
        for key in ConfigSchema.keys.map(\.name) {
            #expect(shown.contains(key) != SettingsCatalog.fileOnly.contains(key), "\(key)")
        }
        for key in shown { #expect(ConfigSchema.key(named: key) != nil, "\(key) is not a setting") }
    }

    @Test func everyChoiceIsAValueTheFileTakes() {
        for setting in all {
            guard case .choice(let choices) = setting.control else { continue }
            for choice in choices {
                let (config, diagnostics) = Config.parse("\(setting.key) = \(choice.value)")
                #expect(diagnostics.isEmpty, "\(setting.key) = \(choice.value)")
                #expect(SettingsCatalog.value(of: setting, in: config) == .text(choice.value))
            }
        }
    }

    /// A value other than the default, for each kind of control.
    func otherValue(for setting: SettingsCatalog.Setting) -> SettingsCatalog.Value {
        switch setting.control {
        case .toggle:
            if case .bool(let on) = SettingsCatalog.value(of: setting, in: Config()) { return .bool(!on) }
            return .bool(true)
        case .choice(let choices): return .text(choices.last!.value)
        case .number(let range, _, _): return .number(range.lowerBound + 1)
        case .megabytes: return .number(100)
        case .text: return .text("/bin/zsh -l")
        case .fontFamily: return .text("Menlo")
        case .theme: return .text("lucid-dreams")
        case .gridSize: return .grid(columns: 120, rows: 40)
        }
    }

    /// Each control's value, written into the template, reads back the same.
    @Test func valuesRoundTripThroughTheFile() {
        for setting in all {
            let value = otherValue(for: setting)
            let file = SettingsCatalog.set(setting, to: value, in: ConfigSchema.template)
            let (config, diagnostics) = Config.parse(file)
            #expect(diagnostics.isEmpty, "\(setting.key): \(diagnostics)")
            #expect(SettingsCatalog.value(of: setting, in: config) == value, "\(setting.key)")
        }
    }

    @Test func emptyTextGoesBackToTheDefault() throws {
        let command = try #require(all.first { $0.key == "command" })
        let file = SettingsCatalog.set(command, to: .text("  "), in: "command = /bin/zsh\n")
        #expect(Config.parse(file).config.command == nil)
    }

    @Test func numbersAreHeldInRangeAndWrittenPlainly() throws {
        let size = try #require(all.first { $0.key == "font-size" })
        #expect(SettingsCatalog.text(for: .number(200), of: size) == "144")
        #expect(SettingsCatalog.text(for: .number(13.5), of: size) == "13.5")
        #expect(SettingsCatalog.text(for: .number(13), of: size) == "13")
        let history = try #require(all.first { $0.key == "scrollback-limit" })
        #expect(SettingsCatalog.text(for: .number(2000), of: history) == "1024MB")
        #expect(SettingsCatalog.value(of: history, in: Config()) == .number(50))
        let size2 = try #require(all.first { $0.key == "window-size" })
        #expect(SettingsCatalog.text(for: .grid(columns: 5, rows: 1), of: size2) == "20x4")
    }

    @Test func keysAndAdvancedHaveNoSettings() {
        #expect(SettingsCatalog.groups(on: .keys).isEmpty)
        #expect(SettingsCatalog.groups(on: .advanced).isEmpty)
        #expect(Set(SettingsCatalog.Page.allCases.map(\.symbol)).count == SettingsCatalog.Page.allCases.count)
    }
}
