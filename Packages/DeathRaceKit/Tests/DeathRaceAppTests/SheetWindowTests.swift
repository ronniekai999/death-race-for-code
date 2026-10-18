import AppKit
import Testing

@testable import DeathRaceApp

// In the window tests' suite, so they run one at a time with the windows they share the
// screen with.
extension WindowTests {
    /// The size of a sheet's content, once AppKit has had a pass in which to change it: a window
    /// sized to its view changes on a later pass, not when the view is set.
    private func settledContentSize(of panel: NSPanel) async -> NSSize {
        panel.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 50_000_000)
        panel.layoutIfNeeded()
        return panel.contentRect(forFrameRect: panel.frame).size
    }

    /// A grouped Form scrolls, so it asks for almost no height of its own. Sized to its view,
    /// the New Host sheet was only Cancel and Add Host, with no field to type a host into.
    @Test func theNewHostSheetHasRoomForItsFields() async {
        let sheet = NewHostSheet(
            jumpHosts: [], parent: nil, add: { _ in .failure(.draft(.noAddress)) }, finished: { _ in })
        sheet.show()
        defer { sheet.panel.orderOut(nil) }
        let size = await settledContentSize(of: sheet.panel)
        #expect(size.width == 460)
        #expect(size.height >= 420)
    }

    @Test func aWishingWellSheetHasRoomForItsFields() async {
        let sheet = WishingWellSheet(title: "Save to Wishing Well", parent: nil)
        sheet.show(SaveSnippetView(name: "uptime", text: "uptime", save: { _ in true }, done: {}))
        defer { sheet.close() }
        let size = await settledContentSize(of: sheet.panel)
        #expect(size.width == 480)
        #expect(size.height >= 320)
    }
}
