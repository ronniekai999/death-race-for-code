import Testing

@testable import VTCore

/// Answers to queries: device attributes, status reports, version, window size, termcap.
@Suite struct TerminalReportTests {
    private func reply(to query: String, _ setup: (Terminal) -> Void = { _ in }) -> String {
        let t = makeTerminal()
        setup(t)
        _ = t.takeReplies()
        t.feed(query)
        return t.takeReplyString()
    }

    @Test func deviceAttributes() {
        #expect(reply(to: "\u{1B}[c") == "\u{1B}[?62;22c")
        #expect(reply(to: "\u{1B}[0c") == "\u{1B}[?62;22c")
        #expect(reply(to: "\u{1B}[>c") == "\u{1B}[>1;10;0c")
        #expect(reply(to: "\u{1B}[=c") == "\u{1B}P!|00000000\u{1B}\\")
        #expect(reply(to: "\u{1B}[1c") == "")
    }

    @Test func deviceStatusReports() {
        #expect(reply(to: "\u{1B}[5n") == "\u{1B}[0n")
        #expect(reply(to: "\u{1B}[6n") { $0.feed("\u{1B}[3;4H") } == "\u{1B}[3;4R")
        #expect(reply(to: "\u{1B}[?6n") { $0.feed("\u{1B}[3;4H") } == "\u{1B}[?3;4;1R")
    }

    @Test func cursorReportAfterAFullLineIsInTheLastColumn() {
        #expect(reply(to: "\u{1B}[6n") { $0.feed("abcdefghij") } == "\u{1B}[1;10R")
    }

    @Test func version() {
        #expect(reply(to: "\u{1B}[>q") == "\u{1B}P>|DeathRace 0.1.0\u{1B}\\")
        #expect(reply(to: "\u{1B}[>0q") == "\u{1B}P>|DeathRace 0.1.0\u{1B}\\")
    }

    @Test func windowReports() {
        #expect(reply(to: "\u{1B}[18t") == "\u{1B}[8;5;10t")
        #expect(reply(to: "\u{1B}[19t") == "\u{1B}[9;5;10t")
        let t = makeTerminal {
            $0.cellPixelWidth = 8
            $0.cellPixelHeight = 16
        }
        t.feed("\u{1B}[14t\u{1B}[16t")
        #expect(t.takeReplyString() == "\u{1B}[4;80;80t\u{1B}[6;16;8t")
    }

    @Test func windowManipulationIsIgnored() {
        #expect(reply(to: "\u{1B}[3;0;0t\u{1B}[8;50;200t\u{1B}[9;1t") == "")
    }

    @Test func titleStack() {
        let t = makeTerminal()
        t.feed("\u{1B}]2;one\u{7}\u{1B}[22t\u{1B}]2;two\u{7}")
        #expect(t.title == "two")
        t.feed("\u{1B}[23t")
        #expect(t.title == "one")
        // Popping an empty stack changes nothing.
        t.feed("\u{1B}[23t")
        #expect(t.title == "one")
    }

    @Test func screenChecksumsOnlyWhenEnabled() {
        #expect(reply(to: "\u{1B}[1;1;1;1;1;1*y") == "")
        let t = makeTerminal { $0.answersChecksumRequests = true }
        t.feed("\u{1B}[7;1;1;1;1;1*y")
        let answer = t.takeReplyString()
        #expect(answer.hasPrefix("\u{1B}P7!~"))
        #expect(answer.hasSuffix("\u{1B}\\"))
        #expect(answer.count == 2 + 3 + 4 + 2)
    }

    @Test func termcapQueries() {
        // "RGB", "Tc" and an unknown "xyz", hex-encoded.
        #expect(reply(to: "\u{1B}P+q524742\u{1B}\\") == "\u{1B}P1+r524742=382F382F38\u{1B}\\")
        #expect(reply(to: "\u{1B}P+q5463\u{1B}\\") == "\u{1B}P1+r5463\u{1B}\\")
        #expect(reply(to: "\u{1B}P+q78797A\u{1B}\\") == "\u{1B}P0+r78797A\u{1B}\\")
        #expect(
            reply(to: "\u{1B}P+q544E;436F\u{1B}\\")
                == "\u{1B}P1+r544E=787465726D2D323536636F6C6F72\u{1B}\\\u{1B}P1+r436F=323536\u{1B}\\")
        #expect(reply(to: "\u{1B}P+qZZ\u{1B}\\") == "")
    }

    @Test func statusStrings() {
        #expect(reply(to: "\u{1B}P$qr\u{1B}\\") { $0.feed("\u{1B}[2;4r") } == "\u{1B}P1$r2;4r\u{1B}\\")
        #expect(reply(to: "\u{1B}P$q q\u{1B}\\") { $0.feed("\u{1B}[6 q") } == "\u{1B}P1$r6 q\u{1B}\\")
        #expect(reply(to: "\u{1B}P$q\"q\u{1B}\\") { $0.feed("\u{1B}[1\"q") } == "\u{1B}P1$r1\"q\u{1B}\\")
        #expect(reply(to: "\u{1B}P$q\"p\u{1B}\\") == "\u{1B}P1$r62;1\"p\u{1B}\\")
        #expect(reply(to: "\u{1B}P$qnope\u{1B}\\") == "\u{1B}P0$r\u{1B}\\")
    }
}
