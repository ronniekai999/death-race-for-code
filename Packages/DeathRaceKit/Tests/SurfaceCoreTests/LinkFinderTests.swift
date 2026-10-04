import ScreenProtocol
import Testing
import VTCore

@testable import SurfaceCore

@Suite struct LinkFinderTests {
    /// The screen after `output`, as the app's mirror holds it.
    func mirror(_ output: String, columns: Int = 20, rows: Int = 4) throws -> MirrorGrid {
        let terminal = Terminal(Terminal.Configuration(columns: columns, rows: rows))
        terminal.feed(Array(output.utf8))
        var builder = DeltaBuilder()
        var mirror = MirrorGrid()
        try mirror.apply(builder.makeDelta(from: terminal, events: []))
        return mirror
    }

    @Test func aProgramsLinkCoversEveryCellOfItOnScreen() throws {
        // `ls --hyperlink` style: one id for a file's name, wrapped over two rows.
        let screen = try mirror(
            "see \u{1B}]8;id=f1;file:///tmp/notes.md\u{1B}\\notes.md\u{1B}]8;;\u{1B}\\ ok", columns: 8)
        let hit = try #require(LinkFinder.link(atColumn: 1, row: 1, in: screen))
        #expect(hit.uri == "file:///tmp/notes.md")
        #expect(hit.isExplicit)
        #expect(hit.text == "notes.md")
        #expect(hit.spans == [LinkHit.Span(row: 0, columns: 4..<8), LinkHit.Span(row: 1, columns: 0..<4)])
        #expect(hit.contains(column: 7, row: 0) && !hit.contains(column: 3, row: 0))
        #expect(LinkFinder.link(atColumn: 0, row: 0, in: screen) == nil)
    }

    @Test func aURLInTheTextIsFoundAcrossASoftWrap() throws {
        let screen = try mirror("go https://wrld.example/999. now", columns: 12)
        // "go https://w" | "rld.example/" | "999. now"
        let hit = try #require(LinkFinder.link(atColumn: 2, row: 1, in: screen))
        #expect(hit.uri == "https://wrld.example/999")
        #expect(!hit.isExplicit)
        #expect(
            hit.spans == [
                LinkHit.Span(row: 0, columns: 3..<12), LinkHit.Span(row: 1, columns: 0..<12),
                LinkHit.Span(row: 2, columns: 0..<3),
            ])
        // The full stop ends the sentence, not the URL.
        #expect(LinkFinder.link(atColumn: 3, row: 2, in: screen) == nil)
        #expect(LinkFinder.link(atColumn: 0, row: 0, in: screen) == nil)
    }

    @Test func wideCharactersAndOddCellsDoNotTripIt() throws {
        // A letter with a zero-width space attached is two characters in one cell.
        let screen = try mirror("中 a\u{200B} https://a.example/中", columns: 30)
        let hit = try #require(LinkFinder.link(atColumn: 6, row: 0, in: screen))
        #expect(hit.uri == "https://a.example/中")
        #expect(hit.spans == [LinkHit.Span(row: 0, columns: 5..<25)])
        #expect(LinkFinder.link(atColumn: 99, row: 0, in: screen) == nil)
        #expect(LinkFinder.link(atColumn: 0, row: 9, in: screen) == nil)
    }
}
