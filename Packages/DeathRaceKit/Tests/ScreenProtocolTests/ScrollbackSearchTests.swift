import Testing
import VTCore

@testable import ScreenProtocol

@Suite struct ScrollbackSearchTests {
    @Test func findsHistoryUnicodeAndSoftWrappedText() {
        let terminal = Terminal(.init(columns: 8, rows: 2))
        terminal.feed(Array("Hello界e\u{301} world\r\nlast\r\nnow".utf8))
        let page = terminal.search(SearchQuery("界e\u{301} world"))
        #expect(page.matches.count == 1)
        let match = page.matches.first!
        #expect(TextExtractor.text(in: match) { terminal.line($0) } == "界e\u{301} world")
        #expect(terminal.search(SearchQuery("hello")).matches.count == 1)
        #expect(terminal.search(SearchQuery("hello", caseSensitive: true)).matches.isEmpty)
        terminal.resize(columns: 20, rows: 3)
        let reflowed = terminal.search(SearchQuery("界e\u{301} world"))
        #expect(reflowed.generation != page.generation)
        #expect(reflowed.matches.count == 1)
    }

    @Test func emptyAndOversizedNeedlesAreRejectedAndPagesAreBounded() {
        let terminal = Terminal(.init(columns: 20, rows: 2))
        for _ in 0..<3000 { terminal.feed(Array("row\r\n".utf8)) }
        #expect(terminal.search(SearchQuery("")).matches.isEmpty)
        #expect(terminal.search(SearchQuery(String(repeating: "x", count: 1025))).matches.isEmpty)
        let page = terminal.search(SearchQuery("row"))
        #expect(page.matches.count == SearchPage.mostMatches)
        #expect(page.limited)
        #expect(page.nextLine != nil)
    }

    @Test func aWideCharacterNeedleCrossingAPageBoundaryIsNotSkipped() throws {
        let terminal = Terminal(.init(columns: 100, rows: 2))
        for _ in 0..<2038 { terminal.feed("x\r\n") }
        let needle = "begin" + String(repeating: "界", count: 512) + "end"
        terminal.feed(needle + "\r\nlast")
        let first = terminal.search(SearchQuery(needle))
        #expect(first.matches.isEmpty)
        let next = try #require(first.nextLine)
        let second = terminal.search(SearchQuery(needle, startLine: next))
        #expect(second.matches.count == 1)
        let match = try #require(second.matches.first)
        #expect(TextExtractor.text(in: match) { terminal.line($0) } == needle)
    }
}
