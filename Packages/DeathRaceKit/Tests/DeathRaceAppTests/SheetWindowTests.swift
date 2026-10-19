import AppKit
import ConfigKit
import Testing
import Vault

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
    @discardableResult
    private func expectFitsItsFields(_ panel: NSPanel, tallerThan least: CGFloat = 260) async throws -> NSSize {
        let size = await settledContentSize(of: panel)
        let fitting = try #require(panel.contentView).fittingSize
        // Nothing cut off, and no empty band under the fields.
        #expect(abs(size.height - fitting.height) < 1)
        #expect(size.width == 460)
        // The fields' height, not the title and buttons' alone (about 170 pt).
        #expect(size.height > least)
        #expect(panel.appearance?.name == .darkAqua)
        #expect(panel.backgroundColor == sheetChrome.colors.ground.nsColor)
        return size
    }

    @Test func theNewHostSheetFitsItsFieldsInTheThemesColors() async throws {
        let sheet = NewHostSheet(
            jumpHosts: [], parent: nil, chrome: sheetChrome, add: { _ in .failure(.draft(.noAddress)) },
            finished: { _ in })
        sheet.show()
        defer { sheet.panel.orderOut(nil) }
        try await expectFitsItsFields(sheet.panel)
    }

    /// Open in Maze's New Host says why it's there in a longer line, which wraps rather than
    /// being cut off.
    @Test func theNewHostSheetFromMazeFitsItsLongerSubtitle() async throws {
        let sheet = NewHostSheet(
            jumpHosts: [], subtitle: NewHostView.mazeSubtitle, parent: nil, chrome: sheetChrome,
            add: { _ in .failure(.draft(.noAddress)) }, finished: { _ in })
        sheet.show()
        defer { sheet.panel.orderOut(nil) }
        try await expectFitsItsFields(sheet.panel)
    }

    private func mazeHosts(_ count: Int) -> [MazeHostView.Choice] {
        (1...count).map {
            MazeHostView.Choice(id: HostID(rawValue: "h\($0)"), name: "host-\($0)", address: "10.0.0.\($0)")
        }
    }

    @Test func theMazeHostSheetFitsItsHosts() async throws {
        let sheet = ThemedSheet(title: "Open in Maze", parent: nil, chrome: sheetChrome)
        sheet.show(MazeHostView(choices: mazeHosts(3), done: { _ in }))
        defer { sheet.close() }
        // Three rows of about 34 pt under the title, not the title and Cancel alone.
        try await expectFitsItsFields(sheet.panel, tallerThan: 220)
    }

    /// A long list scrolls rather than taking the sheet off the bottom of the screen: twelve
    /// rows laid out in full would be over 550 pt.
    @Test func theMazeHostSheetScrollsALongList() async throws {
        let sheet = ThemedSheet(title: "Open in Maze", parent: nil, chrome: sheetChrome)
        sheet.show(MazeHostView(choices: mazeHosts(12), done: { _ in }))
        defer { sheet.close() }
        let size = try await expectFitsItsFields(sheet.panel)
        #expect(size.height < 480)
    }

    @Test func aWishingWellSheetFitsItsFieldsInTheThemesColors() async throws {
        let sheet = ThemedSheet(title: "Save to Wishing Well", parent: nil, chrome: sheetChrome)
        sheet.show(SaveSnippetView(name: "uptime", text: "uptime", save: { _ in true }, done: {}))
        defer { sheet.close() }
        try await expectFitsItsFields(sheet.panel)
    }
}
