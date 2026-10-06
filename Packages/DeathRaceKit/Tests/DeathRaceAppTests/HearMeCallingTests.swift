import AppCore
import AppKit
import ConfigKit
import Foundation
import Testing

@testable import DeathRaceApp

// In the window tests' suite, so they run one at a time with the windows they share the
// screen with.
extension WindowTests {
    /// Types into Hear Me Calling, as the field reports typing.
    func type(_ text: String, into overlay: HearMeCallingOverlay) {
        overlay.field.stringValue = text
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: overlay.field))
    }

    /// A key the field editor turns into a command: ↵ is `insertNewline:`, esc
    /// `cancelOperation:`.
    @discardableResult
    func press(_ command: Selector, in overlay: HearMeCallingOverlay) -> Bool {
        overlay.control(overlay.field, textView: NSTextView(), doCommandBy: command)
    }

    @Test func hearMeCallingOpensOverTheWindowWithTheKeys() throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }

        controller.showHearMeCalling(nil)
        let overlay = try #require(controller.hearMeCalling)
        #expect(controller.root.subviews.last === overlay)
        // The field editor has the keys, on the field's behalf.
        #expect((controller.window?.firstResponder as? NSTextView)?.delegate === overlay.field)
        let items = overlay.model.state.items
        #expect(Set(items.map(\.kind)) == [.action, .place, .theme, .settings])
        // Only actions that would do something: with one tab there is no next one.
        #expect(items.contains { $0.id == "action.splitRight" })
        #expect(!items.contains { $0.id == "action.showNextTab" })
        #expect(!items.contains { $0.id == "action.hearMeCalling" })

        press(#selector(NSResponder.cancelOperation(_:)), in: overlay)
        #expect(controller.hearMeCalling == nil)
        #expect(overlay.superview == nil)
        #expect(controller.window?.firstResponder === controller.activePane?.surface)
    }

    @Test func hearMeCallingRunsTheActionChosen() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }

        controller.showHearMeCalling(nil)
        let overlay = try #require(controller.hearMeCalling)
        type("split right", into: overlay)
        #expect(overlay.model.state.selected?.title == "Split pane right")
        press(#selector(NSResponder.insertNewline(_:)), in: overlay)
        #expect(controller.hearMeCalling == nil)
        await eventually { controller.panes.count == 2 }
        #expect(controller.model.activeTab?.isSplit == true)
        #expect(host.recentPicks == ["action.splitRight"])
    }

    @Test func aHighlightedThemeShowsUntilEscOrIsChosen() throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }

        controller.showHearMeCalling(nil)
        var overlay = try #require(controller.hearMeCalling)
        type("righteous", into: overlay)
        #expect(controller.window?.appearance?.name == .aqua)
        // Down to something that is not a theme, the window's own theme is back.
        type("split right", into: overlay)
        #expect(controller.window?.appearance?.name == .darkAqua)
        type("righteous", into: overlay)
        press(#selector(NSResponder.cancelOperation(_:)), in: overlay)
        #expect(controller.window?.appearance?.name == .darkAqua)
        #expect(host.chosenThemes.isEmpty)

        controller.showHearMeCalling(nil)
        overlay = try #require(controller.hearMeCalling)
        type("lucid", into: overlay)
        press(#selector(NSResponder.insertNewline(_:)), in: overlay)
        #expect(host.chosenThemes == ["lucid-dreams"])
        #expect(controller.hearMeCalling == nil)
    }

    @Test func tabNarrowsToPanesAndChoosingOneShowsIt() async throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        controller.newTab(nil)
        await eventually { controller.model.tabs.count == 2 }
        let first = try #require(controller.model.tabs.first)
        #expect(controller.model.activeTabID != first.id)

        controller.showHearMeCalling(nil)
        let overlay = try #require(controller.hearMeCalling)
        press(#selector(NSResponder.insertTab(_:)), in: overlay)
        press(#selector(NSResponder.insertTab(_:)), in: overlay)
        #expect(overlay.model.state.kind == .place)
        #expect(overlay.model.state.results.map(\.item.detail) == ["Tab 1", "Tab 2"])
        #expect(overlay.model.state.results.first?.item.shortcut == "⌘1")
        press(#selector(NSResponder.insertNewline(_:)), in: overlay)
        #expect(controller.model.activeTabID == first.id)
        #expect(controller.window?.firstResponder === controller.activePane?.surface)
    }

    @Test func aClickOutsideHearMeCallingClosesIt() throws {
        let host = TestHost()
        let controller = makeWindow(host)
        defer { controller.window?.close() }
        let window = try #require(controller.window)

        controller.showHearMeCalling(nil)
        let overlay = try #require(controller.hearMeCalling)
        let click = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 4, y: 4), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        overlay.mouseDown(with: click)
        #expect(controller.hearMeCalling == nil)
        // ⇧⌘P again opens it, and once more closes it.
        controller.showHearMeCalling(nil)
        #expect(controller.hearMeCalling != nil)
        controller.showHearMeCalling(nil)
        #expect(controller.hearMeCalling == nil)
    }

    @Test func aThemeChosenInOneWindowIsSavedForAll() throws {
        let home = try makeFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let suite = "deathrace-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppDelegate(
            makeSession: { _, configuration, _, _ in FakeSession(configuration) },
            configStore: ConfigStore(environment: ["XDG_CONFIG_HOME": home.path]), defaults: defaults)
        app.newWindow(nil)
        app.newWindow(nil)
        let first = try #require(app.windows.first)
        let second = try #require(app.windows.last)
        defer {
            first.window?.close()
            second.window?.close()
        }

        first.showHearMeCalling(nil)
        let overlay = try #require(first.hearMeCalling)
        type("righteous", into: overlay)
        // Only the window it is open over shows the theme before it is chosen.
        #expect(first.window?.appearance?.name == .aqua)
        #expect(second.window?.appearance?.name == .darkAqua)
        press(#selector(NSResponder.insertNewline(_:)), in: overlay)
        #expect(app.configStore.config.themeID == "righteous")
        #expect(first.window?.appearance?.name == .aqua)
        #expect(second.window?.appearance?.name == .aqua)
        #expect(app.recentPicks == ["theme.righteous"])

        // Panes come from every window, this one's first; the last pick leads.
        first.showHearMeCalling(nil)
        let again = try #require(first.hearMeCalling)
        defer { first.closeHearMeCalling() }
        let places = again.model.state.items.filter { $0.kind == .place }
        #expect(places.map(\.detail) == ["Tab 1", "Tab 1 in another window"])
        #expect(again.model.state.selected?.id == "theme.righteous")
        #expect(first.window?.appearance?.name == .aqua)
    }
}
