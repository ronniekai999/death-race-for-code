import Foundation
import ScreenProtocol
import Testing
import VTCore

@testable import SurfaceCore

@Suite struct AccessibleTerminalTextTests {
    @Test func unicodeMapsToUTF16WithoutDuplicatingWideCells() {
        let session = ReplaySession(.init(columns: 8, rows: 2))
        session.feed("a界e\u{301}😀")
        let surface = SurfaceModel(session: session)
        _ = surface.drain()
        let accessible = AccessibleTerminalText(mirror: surface.mirror)
        #expect(accessible.text.hasPrefix("a界e\u{301}😀"))
        let region = TextRegion(TextPoint(line: 0, column: 1), TextPoint(line: 0, column: 2))
        #expect(accessible.substring(accessible.range(for: region)) == "界")
        #expect(accessible.substring(NSRange(location: Int.max, length: 1)) == nil)
        #expect(accessible.points.count == accessible.text.utf16.count)
    }

    @Test func aSearchFromAnOldGenerationIsRefused() async {
        let session = ReplaySession(.init(columns: 8, rows: 2))
        session.feed("hello")
        let old = session.terminal.generation
        session.resize(columns: 12, rows: 2, cellPixelWidth: 0, cellPixelHeight: 0)
        #expect(await session.search(SearchQuery("hello"), generation: old) == nil)
    }
}
