import Testing

@testable import AppCore

@Suite struct NotchPlacementTests {
    /// A notched laptop's usable area (below the menu bar), bottom-left origin.
    let visible = LayoutRect(x: 0, y: 0, width: 1512, height: 944)

    @Test func centresUnderTheNotch() {
        let frame = NotchPlacement.frame(inVisible: visible, notchCenterX: 756, width: 680, height: 320, topInset: 8)
        #expect(frame.width == 680)
        #expect(frame.height == 320)
        #expect(frame.x == 756 - 340)  // centred on the notch
        #expect(frame.maxY == visible.maxY - 8)  // hangs from the top of the usable area
    }

    @Test func centresOnScreenWithoutANotch() {
        let frame = NotchPlacement.frame(inVisible: visible, notchCenterX: nil, width: 680, height: 320)
        #expect(frame.x == (1512 - 680) / 2)
        #expect(frame.maxY == visible.maxY)
    }

    @Test func staysOnScreenWhenCentredNearAnEdge() {
        let frame = NotchPlacement.frame(inVisible: visible, notchCenterX: 1500, width: 680, height: 320)
        #expect(frame.maxX == visible.maxX)  // clamped against the right edge
        #expect(frame.minX >= visible.minX)
    }

    @Test func clampsAPanelBiggerThanTheScreen() {
        let small = LayoutRect(x: 10, y: 10, width: 400, height: 200)
        let frame = NotchPlacement.frame(inVisible: small, notchCenterX: nil, width: 680, height: 320)
        #expect(frame.width == 400)
        #expect(frame.height == 200)
        #expect(frame.minX == 10)
        #expect(frame.minY == 10)
    }

    @Test func respectsAnOffsetDisplay() {
        // A second display to the right: its usable area starts at x = 1512.
        let right = LayoutRect(x: 1512, y: 0, width: 1920, height: 1080)
        let frame = NotchPlacement.frame(inVisible: right, notchCenterX: nil, width: 680, height: 320)
        #expect(frame.x == 1512 + (1920 - 680) / 2)
        #expect(frame.maxY == right.maxY)
    }
}
