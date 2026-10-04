import Testing

@testable import VTCore

@Suite struct TerminalLinkTests {
    static let uri = "https://wrld.example/999"
    static let open = "\u{1B}]8;;\(uri)\u{1B}\\"
    static let close = "\u{1B}]8;;\u{1B}\\"

    /// Each cell's link's URI, nil where there is none.
    func uris(_ row: Row, _ columns: Range<Int>) -> [String?] {
        columns.map { row.link(at: $0)?.uri }
    }

    @Test func charactersPrintIntoTheOpenLink() {
        let t = makeTerminal(columns: 10, rows: 2)
        t.feed("a" + Self.open + "link" + Self.close + "b")
        #expect(uris(t.row(0), 0..<6) == [nil, Self.uri, Self.uri, Self.uri, Self.uri, nil])
        #expect(t.row(0).links.count == 1)
        #expect(t.currentLink == nil)
        // The flag and the index agree, as the codec insists.
        #expect(t.row(0).cells[1].isLinked && t.row(0).cells[1].reserved == 1)
        #expect(!t.row(0).cells[0].isLinked && t.row(0).cells[0].reserved == 0)
    }

    @Test func eachLinkWithoutAnIdIsItsOwn() {
        let t = makeTerminal(columns: 20, rows: 2)
        t.feed(Self.open + "one" + Self.close + " " + Self.open + "two" + Self.close)
        let row = t.row(0)
        #expect(row.link(at: 0)?.uri == row.link(at: 4)?.uri)
        #expect(row.link(at: 0) != row.link(at: 4))
        #expect(row.links.count == 2)
    }

    @Test func anIdMakesOneLinkAcrossRows() {
        let t = makeTerminal(columns: 4, rows: 3)
        t.feed("\u{1B}]8;id=file1;file:///tmp/a\u{7}abcdef\u{1B}]8;;\u{7}")
        let link = Hyperlink(id: "file1", uri: "file:///tmp/a")
        #expect(uris(t.row(0), 0..<4) == Array(repeating: link.uri, count: 4))
        #expect(t.row(1).link(at: 1) == link)
        #expect(t.row(1).link(at: 2) == nil)
        // Other parameters are allowed and ignored.
        t.feed("\u{1B}]8;foo=bar:id=x;https://a\u{7}z")
        #expect(t.currentLink == Hyperlink(id: "x", uri: "https://a"))
    }

    @Test func wideCharactersRepeatsAndCombiningMarksKeepTheLink() {
        let t = makeTerminal(columns: 12, rows: 2)
        t.feed(Self.open + "中x\u{1B}[3be\u{301}" + Self.close + "!")
        let row = t.row(0)
        // 中 in 0–1, x in 2, three more x in 3–5, é in 6.
        #expect(uris(row, 0..<8) == Array(repeating: Self.uri, count: 7) + [nil])
    }

    @Test func overwritingAndErasingDropTheLink() {
        let t = makeTerminal(columns: 10, rows: 2)
        t.feed(Self.open + "abcdef" + Self.close + "\rXY")
        #expect(uris(t.row(0), 0..<3) == [nil, nil, Self.uri])
        t.feed("\u{1B}[K")
        #expect(uris(t.row(0), 0..<10).allSatisfy { $0 == nil })
    }

    @Test func insertingAndDeletingMoveLinkedCells() {
        let t = makeTerminal(columns: 10, rows: 2)
        t.feed(Self.open + "ab" + Self.close + "cd\r\u{1B}[2@")
        #expect(uris(t.row(0), 0..<5) == [nil, nil, Self.uri, Self.uri, nil])
        t.feed("\u{1B}[3P")
        #expect(uris(t.row(0), 0..<3) == [Self.uri, nil, nil])
    }

    @Test func linksGoIntoHistoryAndReflowWithTheirText() {
        let t = makeTerminal(columns: 6, rows: 2)
        t.feed(Self.open + "abcdefgh" + Self.close + "\r\nnext\r\nmore")
        #expect(t.scrollbackLines == ["abcdef", "gh"])
        #expect(t.scrollbackRow(1).link(at: 1)?.uri == Self.uri)

        t.resize(columns: 12, rows: 2)
        #expect(t.scrollbackLines == ["abcdefgh"])
        let joined = t.scrollbackRow(0)
        #expect(uris(joined, 0..<9) == Array(repeating: Self.uri, count: 8) + [nil])
        #expect(joined.links.count == 1)

        t.resize(columns: 3, rows: 2)
        let rows = (0..<t.scrollbackCount).map { t.scrollbackRow($0) }
        #expect(rows.prefix(3).map { $0.link(at: 0)?.uri } == [Self.uri, Self.uri, Self.uri])
        #expect(rows[2].link(at: 2) == nil)
    }

    @Test func linksPastTheLimitsAreNotKept() {
        let t = makeTerminal(columns: 10, rows: 2)
        let long = "https://a/" + String(repeating: "x", count: Hyperlink.maxURILength - 9)
        t.feed("\u{1B}]8;;\(long)\u{7}a")
        #expect(t.currentLink == nil)
        #expect(t.row(0).link(at: 0) == nil)
        let longest = String(long.dropLast())
        t.feed("\u{1B}]8;;\(longest)\u{7}b")
        #expect(t.currentLink?.uri == longest)
        t.feed("\u{1B}]8;id=\(String(repeating: "i", count: Hyperlink.maxIDLength + 1));https://a\u{7}c")
        #expect(t.currentLink == nil)
        // A malformed sequence, with no separator, closes the link.
        t.feed(Self.open + "\u{1B}]8\u{7}d")
        #expect(t.currentLink == nil)
    }

    @Test func aRowKeepsAtMostItsLimitAndMakesRoomWhenLinksGo() {
        let count = Row.linkLimit + 20
        let t = makeTerminal(columns: count + 10, rows: 1)
        for index in 0..<count { t.feed("\u{1B}]8;id=\(index);https://a/\(index)\u{7}x") }
        t.feed(Self.close)
        let row = t.row(0)
        #expect(row.links.count == Row.linkLimit)
        #expect(row.link(at: Row.linkLimit - 1)?.id == "\(Row.linkLimit - 1)")
        #expect(row.link(at: Row.linkLimit) == nil)

        // Overwrite the first hundred: their links go when a new one needs the room.
        t.feed("\r" + String(repeating: "y", count: 100))
        t.feed("\u{1B}[1;\(count + 2)H" + Self.open + "z" + Self.close)
        #expect(row.link(at: count + 1)?.uri == Self.uri)
        #expect(row.links.count == Row.linkLimit - 100 + 1)
        #expect(row.link(at: 100)?.id == "100")
    }

    @Test func aFullResetClosesTheLink() {
        let t = makeTerminal()
        t.feed(Self.open + "a")
        #expect(t.currentLink != nil)
        t.feed("\u{1B}c")
        #expect(t.currentLink == nil)
    }
}
