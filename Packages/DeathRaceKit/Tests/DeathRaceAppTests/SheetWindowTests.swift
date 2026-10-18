import AppKit
import ConfigKit
import Testing

@testable import DeathRaceApp

// In the window tests' suite, so they run one at a time with the windows they share the
// screen with.
extension WindowTests {
    private var sheetChrome: Chrome { Chrome(Config().namedTheme) }

    /// The size of a sheet's content, once AppKit has had a pass in which to change it: a window
    /// sized to its view changes on a later pass, not when the view is set.
    private func settledContentSize(of panel: NSPanel) async -> NSSize {
        panel.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: 50_000_000)
        panel.layoutIfNeeded()
        return panel.contentRect(forFrameRect: panel.frame).size
    }

    /// A sheet that fits its fields, in the theme's colors. A grouped Form scrolls, so it asks
    /// for no height of its own: a sheet that fitted one was only Cancel and Add Host, and in
    /// the system's grey rather than the theme's ground.
    private func expectFitsItsFields(_ panel: NSPanel) async throws {
        let size = await settledContentSize(of: panel)
        let fitting = try #require(panel.contentView).fittingSize
        // Nothing cut off, and no empty band under the fields.
        #expect(abs(size.height - fitting.height) < 1)
        #expect(size.width == 460)
        // The fields' height, not the title and buttons' alone (about 170 pt).
        #expect(size.height > 260)
        #expect(panel.appearance?.name == .darkAqua)
        #expect(panel.backgroundColor == sheetChrome.colors.ground.nsColor)
    }

    @Test func theNewHostSheetFitsItsFieldsInTheThemesColors() async throws {
        let sheet = NewHostSheet(
            jumpHosts: [], parent: nil, chrome: sheetChrome, add: { _ in .failure(.draft(.noAddress)) },
            finished: { _ in })
        sheet.show()
        defer { sheet.panel.orderOut(nil) }
        try await expectFitsItsFields(sheet.panel)
    }

    @Test func aWishingWellSheetFitsItsFieldsInTheThemesColors() async throws {
        let sheet = WishingWellSheet(title: "Save to Wishing Well", parent: nil, chrome: sheetChrome)
        sheet.show(SaveSnippetView(name: "uptime", text: "uptime", save: { _ in true }, done: {}))
        defer { sheet.close() }
        try await expectFitsItsFields(sheet.panel)
    }
}
