import AppCore
import AppKit
import ConfigKit
import Testing

@testable import DeathRaceApp

/// Records what it was asked to register, and lets a test fire the hotkey, so the controller's
/// read-the-setting / register / re-register logic is tested without Carbon.
@MainActor
final class FakeHotKeyRegistrar: HotKeyRegistrar {
    private(set) var registered: (keyCode: UInt32, modifiers: UInt32)?
    private(set) var unregisters = 0
    private var onPress: (@MainActor () -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32, onPress: @escaping @MainActor () -> Void) -> Bool {
        registered = (keyCode, modifiers)
        self.onPress = onPress
        return true
    }

    func unregister() {
        registered = nil
        onPress = nil
        unregisters += 1
    }

    func fire() { onPress?() }
}

private final class Fired { var count = 0 }

extension WindowTests {
    @Test func theLucidDreamsHotKeyFollowsTheSetting() {
        let fired = Fired()
        let registrar = FakeHotKeyRegistrar()
        let hotKey = HotKeyController(registrar: registrar, onTrigger: { fired.count += 1 })

        #expect(hotKey.apply("⌥Space"))
        #expect(hotKey.active == KeyShortcut(.character(" "), [.option]))
        #expect(registrar.registered?.modifiers == HotKeyController.carbonModifiers([.option]))
        registrar.fire()
        #expect(fired.count == 1)

        // "none" and anything unparseable turn the hotkey off.
        #expect(!hotKey.apply("none"))
        #expect(hotKey.active == nil)
        #expect(registrar.registered == nil)
        #expect(!hotKey.apply("not a key"))
        #expect(hotKey.active == nil)
    }

    @Test func theQuickTerminalKeepsItsSessionAcrossHideAndShow() async throws {
        let controller = LucidDreamsController(
            config: { Config() }, makeSession: { _, configuration, _ in FakeSession(configuration) }, ids: IDSource())
        defer { controller.shutDown() }

        #expect(!controller.isOnScreen)
        controller.toggle()  // show
        #expect(controller.isOnScreen)
        let pane = try #require(controller.pane)
        await eventually { pane.session != nil }
        #expect(pane.session != nil)

        controller.toggle()  // hide
        // Hiding stops drawing but never closes the session, and keeps the one pane.
        #expect(controller.pane === pane)
        #expect(pane.session != nil)

        controller.toggle()  // show again
        #expect(controller.pane === pane)  // reused, not rebuilt
        #expect(controller.isOnScreen)
    }
}
