import Testing

@testable import VTCore

/// Protected cells. One bit marks them; which erases leave them alone depends on who marked
/// them, and that table is xterm's.
@Suite struct TerminalProtectionTests {
    /// "ab" plain and "c" protected by `mark`, with the cursor back at the start.
    func row(markedBy mark: String, unmarkedBy unmark: String) -> Terminal {
        let t = makeTerminal(columns: 6, rows: 2)
        t.feed("ab" + mark + "c" + unmark + "\u{1B}[1;1H")
        return t
    }

    static let plainErases = ["\u{1B}[3X", "\u{1B}[0J", "\u{1B}[2K"]
    static let selectiveErases = ["\u{1B}[?0J", "\u{1B}[?2K"]

    @Test func isoProtectionSurvivesThePlainErases() {
        for erase in Self.plainErases {
            let t = row(markedBy: "\u{1B}V", unmarkedBy: "\u{1B}W")
            t.feed(erase)
            #expect(t.lines[0] == "  c", "\(erase.debugDescription) took a cell SPA protected")
        }
    }

    @Test func decscaProtectionDoesNotSurviveThem() {
        for erase in Self.plainErases {
            let t = row(markedBy: "\u{1B}[1\"q", unmarkedBy: "\u{1B}[0\"q")
            t.feed(erase)
            #expect(t.lines[0] == "", "\(erase.debugDescription) spared a cell only DECSCA marked")
        }
    }

    /// Here xterm spares either kind "for backward compatibility", which is the reason esctest
    /// gives for filing it as xterm's own difference from the specification. We follow xterm:
    /// a selective erase that takes what a program protected is the worse answer to be wrong
    /// with.
    @Test func theSelectiveErasesSpareEitherKind() {
        for mark in [("\u{1B}V", "\u{1B}W"), ("\u{1B}[1\"q", "\u{1B}[0\"q")] {
            for erase in Self.selectiveErases {
                let t = row(markedBy: mark.0, unmarkedBy: mark.1)
                t.feed(erase)
                #expect(t.lines[0] == "  c", "\(erase.debugDescription) took a protected cell")
            }
        }
    }

    /// DECSERA is the exception, in xterm as here: only what DECSCA protected survives it.
    @Test func decseraSparesOnlyWhatDecscaProtected() {
        let dec = row(markedBy: "\u{1B}[1\"q", unmarkedBy: "\u{1B}[0\"q")
        dec.feed("\u{1B}[1;1;1;6${")
        #expect(dec.lines[0] == "  c")
        let iso = row(markedBy: "\u{1B}V", unmarkedBy: "\u{1B}W")
        iso.feed("\u{1B}[1;1;1;6${")
        #expect(iso.lines[0] == "", "ISO protection is not DECSERA's business")
    }

    @Test func epaEndsTheAreaAndNotTheMode() {
        let t = makeTerminal(columns: 6, rows: 2)
        t.feed("ab\u{1B}Vc\u{1B}Wd\u{1B}[1;1H\u{1B}[2K")
        #expect(t.lines[0] == "  c", "the d after EPA is not protected, and the mode still holds")
    }

    @Test func decscaAfterSpaSaysTheBitIsDecscasAgain() {
        let t = makeTerminal(columns: 6, rows: 2)
        t.feed("\u{1B}Va\u{1B}W\u{1B}[0\"q\u{1B}[1;1H\u{1B}[2K")
        #expect(t.lines[0] == "", "so a plain erase takes it")
    }

    /// A soft reset forgets who protected what, so a cell that was spared stops being spared.
    /// (RIS clears the screen, so there is nothing left either way.)
    @Test func aSoftResetForgetsWhoProtectedWhat() {
        let t = row(markedBy: "\u{1B}V", unmarkedBy: "\u{1B}W")
        t.feed("\u{1B}[!p\u{1B}[1;1H\u{1B}[2K")
        #expect(t.lines[0] == "", "the cell is still marked and nothing is spared for it any more")
    }
}
