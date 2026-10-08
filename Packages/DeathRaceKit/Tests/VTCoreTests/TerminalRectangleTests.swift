import Testing

@testable import VTCore

/// The rectangular-area operations. esctest covers their shapes against xterm; what it cannot
/// see — styles, links, graphemes, protected cells and the rows' own semantic marks — is here.
@Suite struct TerminalRectangleTests {
    static let data = [
        "abcdefgh", "ijklmnop", "qrstuvwx", "yz012345", "ABCDEFGH", "IJKLMNOP", "QRSTUVWX", "YZ6789!@",
    ]

    /// esctest's own rectangle fixture: eight rows of eight characters.
    func eightByEight() -> Terminal {
        let t = makeTerminal(columns: 8, rows: 8)
        for (row, line) in Self.data.enumerated() { t.feed("\u{1B}[\(row + 1);1H" + line) }
        return t
    }

    @Test func decfraFillsItsRectangleAndNothingElse() {
        let t = eightByEight()
        t.feed("\u{1B}[33;5;5;7;7$x")
        #expect(
            t.lines == [
                "abcdefgh", "ijklmnop", "qrstuvwx", "yz012345", "ABCD!!!H", "IJKL!!!P", "QRST!!!X", "YZ6789!@",
            ])
    }

    @Test func decfraFillsInThePenItIsGiven() {
        let t = eightByEight()
        t.feed("\u{1B}[1;31m\u{1B}[33;1;1;1;2$x")
        #expect(t.style(x: 0, y: 0) == Style(foreground: .indexed(1), attributes: .bold))
    }

    /// DEC allows the printable Latin-1 characters and nothing else, so anything else is not a
    /// fill request at all.
    @Test func decfraRefusesACharacterItCannotPrint() {
        for code in [7, 31, 127, 159, 256] {
            let t = eightByEight()
            t.feed("\u{1B}[\(code);1;1;2;2$x")
            #expect(t.lines[0] == "abcdefgh", "\(code) is not a fill character")
        }
    }

    @Test func deceraErasesItsRectangle() {
        let t = eightByEight()
        t.feed("\u{1B}[5;5;7;7$z")
        #expect(
            t.lines == [
                "abcdefgh", "ijklmnop", "qrstuvwx", "yz012345", "ABCD   H", "IJKL   P", "QRST   X", "YZ6789!@",
            ])
    }

    @Test func decseraLeavesWhatDecscaProtected() {
        let t = makeTerminal(columns: 6, rows: 1)
        t.feed("ab\u{1B}[1\"qcd\u{1B}[0\"qef")
        t.feed("\u{1B}[1;1;1;6${")
        #expect(t.lines[0] == "  cd")
        t.feed("\u{1B}[1;1;1;6$z")
        #expect(t.lines[0] == "", "and the unselective erase takes everything")
    }

    @Test func deccraCopiesItsRectangle() {
        let t = eightByEight()
        t.feed("\u{1B}[2;2;4;4;1;5;5;1$v")
        #expect(
            t.lines == [
                "abcdefgh", "ijklmnop", "qrstuvwx", "yz012345", "ABCDjklH", "IJKLrstP", "QRSTz01X", "YZ6789!@",
            ])
    }

    /// The copy reads what was on the screen before it started, which is the whole reason the
    /// rectangle is lifted out first.
    @Test func deccraWithAnOverlappingDestinationCopiesWhatWasThere() {
        let t = eightByEight()
        t.feed("\u{1B}[2;2;4;4;1;3;3;1$v")
        #expect(
            t.lines == [
                "abcdefgh", "ijklmnop", "qrjklvwx", "yzrst345", "ABz01FGH", "IJKLMNOP", "QRSTUVWX", "YZ6789!@",
            ])
    }

    @Test func aCopyIsTruncatedWhereTheScreenEnds() {
        let t = eightByEight()
        t.feed("\u{1B}[2;2;4;4;1;7;7;1$v")
        #expect(t.lines[6] == "QRSTUVjk")
        #expect(t.lines[7] == "YZ6789rs", "two rows and two columns of it fit, and the rest is dropped")
    }

    @Test func aRectangleThatIsInsideOutDoesNothing() {
        for sequence in ["\u{1B}[5;5;4;4$z", "\u{1B}[33;5;5;4;4$x", "\u{1B}[5;5;4;4${", "\u{1B}[5;5;4;4;1;1;1;1$v"] {
            let t = eightByEight()
            t.feed(sequence)
            #expect(t.lines == Self.data, "\(sequence.debugDescription) touched the screen")
        }
    }

    @Test func aRectangleIsClippedToTheScreen() {
        let t = eightByEight()
        t.feed("\u{1B}[33;7;7;99;99$x")
        #expect(t.lines[6] == "QRSTUV!!")
        #expect(t.lines[7] == "YZ6789!!")
    }

    @Test func aRectangleNeverMovesTheCursor() {
        let t = eightByEight()
        t.feed("\u{1B}[4;3H")
        for sequence in ["\u{1B}[2;2;4;4$z", "\u{1B}[33;2;2;4;4$x", "\u{1B}[2;2;4;4${", "\u{1B}[2;2;4;4;1;5;5;1$v"] {
            t.feed(sequence)
            #expect(t.cursorPosition == [2, 3], "\(sequence.debugDescription) moved the cursor")
        }
    }

    @Test func aRectangleIgnoresTheMargins() {
        let t = eightByEight()
        t.feed("\u{1B}[?69h\u{1B}[3;6s\u{1B}[3;6r\u{1B}[33;5;5;7;7$x")
        #expect(t.lines[4] == "ABCD!!!H", "a rectangle is the page's, not the scroll region's")
    }

    @Test func aRectangleCountsFromTheMarginsInOriginMode() {
        let t = eightByEight()
        t.feed("\u{1B}[?69h\u{1B}[2;7s\u{1B}[2;7r\u{1B}[?6h\u{1B}[33;1;1;3;3$x")
        #expect(t.lines[1] == "i!!!mnop")
        #expect(t.lines[2] == "q!!!uvwx")
        #expect(t.lines[3] == "y!!!2345")
        #expect(t.lines[0] == "abcdefgh", "the origin is the margins' own corner")
    }

    /// A cell's style and its link are indexes into the table of the row that holds it, so both
    /// have to be looked up again in the row the copy lands on. Nothing esctest reads can tell.
    @Test func aStyleAndALinkRideAlongWithACopiedRectangle() {
        let t = makeTerminal(columns: 8, rows: 4)
        let open = "\u{1B}]8;;https://wrld.example/999\u{1B}\\"
        t.feed("\u{1B}[1;32m" + open + "xy\u{1B}]8;;\u{1B}\\\u{1B}[0m")
        t.feed("\u{1B}[1;1;1;2;1;3;5;1$v")
        let row = t.row(2)
        #expect(row.text == "    xy")
        #expect(t.style(x: 4, y: 2) == Style(foreground: .indexed(2), attributes: .bold))
        #expect(row.link(at: 5)?.uri == "https://wrld.example/999")
        #expect(row.links.count == 1, "the link is registered once in the row it landed on")
    }

    @Test func aGraphemeRidesAlongWithACopiedRectangle() {
        let t = makeTerminal(columns: 8, rows: 4)
        t.feed("e\u{301}")
        t.feed("\u{1B}[1;1;1;1;1;3;5;1$v")
        #expect(t.row(2).text == "    e\u{301}")
        #expect(t.row(2).graphemes[4] == [0x301])
    }

    @Test func aWideCharacterCutByARectangleLosesTheHalfInsideIt() {
        let t = makeTerminal(columns: 6, rows: 2)
        t.feed("\u{1B}[1;3H\u{4E16}")
        t.feed("\u{1B}[33;1;1;1;3$x")
        #expect(t.row(0).text == "!!!", "the half left outside draws nothing of its own")
        #expect(t.row(0).cells[3].width == .narrow)
    }

    /// A program drawing a rectangle has not replaced the screen, so the row's marks and its
    /// command record stay: Conversations draws a rail from them, and the command the row is
    /// about has not changed.
    @Test func erasingARectangleLeavesTheRowsOwnMarks() {
        let t = makeTerminal(columns: 6, rows: 2)
        t.feed("\u{1B}]133;A\u{7}\u{1B}]133;B\u{7}ls -l")
        t.feed("\u{1B}[1;1;1;6$z")
        #expect(t.row(0).text == "")
        #expect(!t.row(0).promptMarks.isEmpty)
    }
}
