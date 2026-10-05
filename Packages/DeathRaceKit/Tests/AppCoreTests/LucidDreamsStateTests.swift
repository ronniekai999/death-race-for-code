import Testing

@testable import AppCore

@Suite struct LucidDreamsStateTests {
    @Test func toggleShowsThenHides() {
        var state = LucidDreamsState()
        #expect(state.phase == .hidden)
        #expect(!state.isOnScreen)

        #expect(state.toggle() == .show)
        #expect(state.phase == .showing)
        #expect(state.isOnScreen)
        state.didFinishShowing()
        #expect(state.phase == .shown)

        #expect(state.toggle() == .hide)
        #expect(state.phase == .hiding)
        #expect(state.isOnScreen)  // still on screen while it slides back up
        state.didFinishHiding()
        #expect(state.phase == .hidden)
        #expect(!state.isOnScreen)
    }

    @Test func aPressMidAnimationReverses() {
        var state = LucidDreamsState()
        #expect(state.toggle() == .show)  // showing
        #expect(state.toggle() == .hide)  // reversed before the show finished
        #expect(state.phase == .hiding)
        state.didFinishShowing()  // the show animation's late callback is ignored
        #expect(state.phase == .hiding)
        #expect(state.toggle() == .show)  // reverse again
        #expect(state.phase == .showing)
        state.didFinishHiding()  // the stale hide callback is ignored
        #expect(state.phase == .showing)
    }

    @Test func escHidesOnlyWhenOnScreen() {
        var state = LucidDreamsState()
        #expect(state.hide() == nil)  // already away
        _ = state.toggle()  // showing
        state.didFinishShowing()  // shown
        #expect(state.hide() == .hide)
        #expect(state.phase == .hiding)
        #expect(state.hide() == nil)  // already on its way out
    }
}
