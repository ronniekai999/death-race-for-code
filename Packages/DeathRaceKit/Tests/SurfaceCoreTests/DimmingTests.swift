import Testing
import VTCore

@testable import SurfaceCore

@Suite struct DimmingTests {
    @Test func theAmountRidesInTheAlphaByte() {
        let dimming = Dimming(color: RGB(0x10, 0x20, 0x30), amount: 0.14)
        #expect(dimming.packed == 0x2430_2010)
        #expect(Dimming(color: RGB(0, 0, 0), amount: 2).packed >> 24 == 0xFF)
        #expect(Dimming(color: RGB(0, 0, 0), amount: -1).packed == 0)
    }

    /// The cursor is faded on the CPU with the amount the shaders get, not the exact one.
    @Test func theCursorFadesAsTheShadersDo() {
        let dimming = Dimming(color: RGB(0, 0, 0), amount: 0.5)
        #expect(dimming.apply(to: RGB(200, 100, 0)) == RGB(100, 50, 0))
        #expect(Dimming(color: RGB(9, 9, 9), amount: 0).apply(to: RGB(200, 100, 0)) == RGB(200, 100, 0))
    }
}
